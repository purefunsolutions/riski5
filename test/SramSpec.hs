-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : SramSpec
Description : Tests for the IS61LV25616-class async SRAM controller.

Drives 'Riski5.Sram.sramSim' through a few firmware-style MMIO
transactions and checks that:

  * a half-word write pulse + recovery commits on the WE rising
    edge and reads back;
  * byte writes (UB / LB selectivity) leave the other lane intact;
  * the 'Riski5.MemMap.sramBase' offset is honoured;
  * __T31a__ — back-to-back half-word writes to the same address
    both land (regression for the pre-T31a latent WE-held-low bug);
  * __T31a__ — 32-bit LW / SW round-trip preserves the full 32-bit
    pattern;
  * __T31a__ — read-after-write on the same word returns the newly
    written value.

Cycle expectations are pinned against the new FSM timings:

@
  LB / LBU / LH / LHU / LW    3 cycles  (100.00 ns @ 30 MHz)
  SB / SH                     2 cycles   (66.67 ns)
  SW                          4 cycles  (133.33 ns)
@

Each test holds its bus signals for the full duration of each
transaction (matching how a stalled core holds its signals while
@readyS == False@). The assertions pick out the commit cycle via
direct indexing — comments in each case walk through which cycle
each phase lands on.
-}
module SramSpec (
  tests,
) where

import Clash.Prelude (
  BitVector,
  HiddenClockResetEnable,
  Signal,
  System,
  Vec,
  clockGen,
  enableGen,
  fromList,
  resetGen,
  sampleN,
  withClockResetEnable,
 )
import Clash.Prelude qualified as CP
import Riski5.MemMap (sramBase)
import Riski5.Sram (sramSim)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, testCase)
import Prelude (Bool (..), Int, ($), (+))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Sram"
    [ testCase "halfword write commits and reads back" case_halfWord
    , testCase "byte writes via UB/LB leave the other lane intact" case_byteSelectivity
    , testCase "addresses route through sramBase offset" case_baseOffset
    , testCase "T31a: 32-bit LW/SW round-trip preserves the full pattern" case_wordRoundTrip
    , testCase "T31a: back-to-back SH writes to same address both land" case_backToBackWrites
    , testCase "T31a: SW then LW returns the newly written word (RAW)" case_rawSameAddr
    ]

-- * Harness --------------------------------------------------------

-- | Drive 'sramSim' for @n@ cycles and return the @rdata@ trace.
runSram ::
  Int ->
  [Bool] ->
  [BitVector 32] ->
  [BitVector 32] ->
  [BitVector 4] ->
  [BitVector 32]
runSram n sels addrs wdatas bes =
  let pad xs = xs P.++ P.repeat (P.last xs)
      selS = fromList (pad sels)
      addrS = fromList (pad addrs)
      wdataS = fromList (pad wdatas)
      beS = fromList (pad bes)
      renS = fromList (P.repeat True)
      initial :: Vec 16 (BitVector 16)
      initial = CP.repeat 0
      go :: (HiddenClockResetEnable System) => Signal System (BitVector 32)
      go =
        let (rdata, _pins, _store, _ready) = sramSim initial selS addrS wdataS beS renS
         in rdata
   in sampleN @System n $
        withClockResetEnable @System clockGen resetGen enableGen go

-- | Sequence-building helper: @holdFor n bus@ replicates a bus tuple
-- @(sel, addr, wdata, be)@ for @n@ cycles. Used to model a core that
-- holds its bus signals while stalled.
holdFor ::
  Int ->
  (Bool, BitVector 32, BitVector 32, BitVector 4) ->
  [(Bool, BitVector 32, BitVector 32, BitVector 4)]
holdFor n b = P.replicate n b

-- | Split a list of per-cycle bus tuples into four parallel signal
-- lists matching @runSram@'s argument shape.
splitBus ::
  [(Bool, BitVector 32, BitVector 32, BitVector 4)] ->
  ([Bool], [BitVector 32], [BitVector 32], [BitVector 4])
splitBus bs =
  ( P.map (\(s, _, _, _) -> s) bs
  , P.map (\(_, a, _, _) -> a) bs
  , P.map (\(_, _, w, _) -> w) bs
  , P.map (\(_, _, _, b) -> b) bs
  )

-- * Cases ----------------------------------------------------------

case_halfWord :: Assertion
case_halfWord = do
  -- Cycle 0: reset (sel=False).
  -- Cycles 1-2: SH 0xBEEF to sramBase. Cycle 1 = pulse (WE low,
  --             ready=False), cycle 2 = recover (WE rising →
  --             latches, ready=True).
  -- Cycles 3-5: LHU sramBase. Cycle 3 = lo-pulse, cycle 4 = hi-stall
  --             (wordLoReg latches), cycle 5 = commit with rdata
  --             assembled.
  -- T31a reads are uniform 3-cycle word reads; rdata[15:0] carries
  -- the half-word, rdata[31:16] carries SRAM[hi] (== 0 here).
  let reset_ = (False, 0, 0, 0)
      write_ = (True, sramBase, 0x0000_BEEF, 0b0011)
      read_ = (True, sramBase, 0, 0)
      seq_ =
        [reset_]
          P.++ holdFor 2 write_
          P.++ holdFor 3 read_
      (sels, addrs, wdatas, bes) = splitBus seq_
      trace = runSram 8 sels addrs wdatas bes
  assertEqual
    "rdata[5] after SH+LHU round-trip"
    0x0000_BEEF
    (trace P.!! 5)

case_byteSelectivity :: Assertion
case_byteSelectivity = do
  -- Write two full half-words at adjacent half-word indices, then
  -- rewrite only the low byte of the first with SB. Expect the
  -- high byte of the first half-word to survive.
  --   Cycles 1-2:  SH  0xAABB → addr0   (be=0b0011)
  --   Cycles 3-4:  SH  0xCCDD → addr1   (be=0b0011)
  --   Cycles 5-6:  SB  0x99   → addr0, byte 0 (be=0b0001)
  --   Cycles 7-9:  LHU addr0                (read, 3 cycles)
  --   → rdata[9][15:0] = 0xAA99
  let reset_ = (False, 0, 0, 0)
      addr0 = sramBase
      addr1 = sramBase + 4
      sh1 = (True, addr0, 0x0000_AABB, 0b0011)
      sh2 = (True, addr1, 0x0000_CCDD, 0b0011)
      sb3 = (True, addr0, 0x0000_0099, 0b0001)
      rd = (True, addr0, 0, 0)
      seq_ =
        [reset_]
          P.++ holdFor 2 sh1
          P.++ holdFor 2 sh2
          P.++ holdFor 2 sb3
          P.++ holdFor 3 rd
      (sels, addrs, wdatas, bes) = splitBus seq_
      trace = runSram 12 sels addrs wdatas bes
  assertEqual
    "high byte preserved after byte-selective SB"
    0x0000_AA99
    (trace P.!! 9)

case_baseOffset :: Assertion
case_baseOffset = do
  -- Two writes at addr0 = sramBase and addr2 = sramBase+4 must land
  -- in independent SRAM half-word slots — the controller drops bit 0
  -- of the CPU byte address to form the chip half-word index, so
  -- sramBase and sramBase+4 map to indices 0 and 2 (not 0 and 1).
  --   Cycles 1-2:   SH 0x1111 → addr0
  --   Cycles 3-4:   SH 0x2222 → addr2
  --   Cycles 5-7:   LHU addr0 → expect 0x0000_1111 at cycle 7
  --   Cycles 8-10:  LHU addr2 → expect 0x0000_2222 at cycle 10
  let reset_ = (False, 0, 0, 0)
      addr0 = sramBase
      addr2 = sramBase + 4
      sh1 = (True, addr0, 0x0000_1111, 0b0011)
      sh2 = (True, addr2, 0x0000_2222, 0b0011)
      rd0 = (True, addr0, 0, 0)
      rd2 = (True, addr2, 0, 0)
      seq_ =
        [reset_]
          P.++ holdFor 2 sh1
          P.++ holdFor 2 sh2
          P.++ holdFor 3 rd0
          P.++ holdFor 3 rd2
      (sels, addrs, wdatas, bes) = splitBus seq_
      trace = runSram 14 sels addrs wdatas bes
  assertEqual "addr0 reads 0x1111" 0x0000_1111 (trace P.!! 7)
  assertEqual "addr2 reads 0x2222" 0x0000_2222 (trace P.!! 10)

case_wordRoundTrip :: Assertion
case_wordRoundTrip = do
  -- T31a: 32-bit SW then LW at the same address. SW takes 4 cycles
  -- (lo-pulse / lo-recover / hi-pulse / hi-recover). LW takes 3
  -- cycles (lo-pulse / hi-stall / commit).
  --   Cycles 1-4:  SW 0xDEAD_BEEF → sramBase
  --   Cycles 5-7:  LW sramBase → expect 0xDEAD_BEEF at cycle 7
  -- Verifies: (a) SW writes both SRAM halves; (b) LW assembles
  -- them back into a single 32-bit value with the correct endianness
  -- (bytes 0-1 at SRAM[lo], bytes 2-3 at SRAM[hi]).
  let reset_ = (False, 0, 0, 0)
      sw_ = (True, sramBase, 0xDEAD_BEEF, 0b1111)
      lw_ = (True, sramBase, 0, 0)
      seq_ =
        [reset_]
          P.++ holdFor 4 sw_
          P.++ holdFor 3 lw_
      (sels, addrs, wdatas, bes) = splitBus seq_
      trace = runSram 10 sels addrs wdatas bes
  assertEqual "LW returns the 32-bit pattern written by SW" 0xDEAD_BEEF (trace P.!! 7)

case_backToBackWrites :: Assertion
case_backToBackWrites = do
  -- Regression for the pre-T31a latent bug: consecutive SH writes
  -- to the same address kept WE_N low across cycles with address
  -- unchanged but data mid-flight. The new FSM inserts a recovery
  -- cycle (WE high) between every pulse, so each write latches
  -- cleanly on its own rising edge.
  --   Cycles 1-2:  SH 0x1111 → addr
  --   Cycles 3-4:  SH 0x2222 → addr   (second write overwrites)
  --   Cycles 5-7:  LHU addr         → expect 0x2222 at cycle 7
  let reset_ = (False, 0, 0, 0)
      addr = sramBase
      sh1 = (True, addr, 0x0000_1111, 0b0011)
      sh2 = (True, addr, 0x0000_2222, 0b0011)
      rd_ = (True, addr, 0, 0)
      seq_ =
        [reset_]
          P.++ holdFor 2 sh1
          P.++ holdFor 2 sh2
          P.++ holdFor 3 rd_
      (sels, addrs, wdatas, bes) = splitBus seq_
      trace = runSram 12 sels addrs wdatas bes
  assertEqual "second SH overwrites first" 0x0000_2222 (trace P.!! 7)

case_rawSameAddr :: Assertion
case_rawSameAddr = do
  -- T31a read-after-write on the same word address. The FSM's WE
  -- recovery cycle ensures the written value is fully latched in
  -- the SRAM cell before the subsequent read's OE_N transitions
  -- low, so the read returns the newly written value.
  --   Cycles 1-4:  SW 0xCAFE_BABE → sramBase
  --   Cycles 5-7:  LW sramBase → expect 0xCAFE_BABE at cycle 7
  let reset_ = (False, 0, 0, 0)
      sw_ = (True, sramBase, 0xCAFE_BABE, 0b1111)
      lw_ = (True, sramBase, 0, 0)
      seq_ =
        [reset_]
          P.++ holdFor 4 sw_
          P.++ holdFor 3 lw_
      (sels, addrs, wdatas, bes) = splitBus seq_
      trace = runSram 10 sels addrs wdatas bes
  assertEqual "LW after SW returns the freshly-written word" 0xCAFE_BABE (trace P.!! 7)
