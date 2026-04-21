-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : SdramSpec
Description : Tests for the SDRAM-Controller-IP + 32 ↔ 16 adapter path.

Drives 'Riski5.Sdram.sdram' chained with 'Riski5.Sdram.sdramIpSim'
through firmware-style MMIO transactions, and checks that:

  * SW / LW round-trips preserve the full 32-bit pattern through
    two back-to-back Avalon half-word transactions;
  * SH at lo or hi half writes the correct half-word and leaves
    the other half intact (byte-selectivity at the half-word level);
  * the 'Riski5.MemMap.sdramBase' offset is honoured — a CPU byte
    address like @sdramBase + 4@ routes to chip-word index 2
    (not 4, because each chip-word is 2 bytes);
  * read-after-write on the same address returns the newly written
    value;
  * back-to-back SH writes to the same chip-word both commit
    (regression cover for any "WE held low across boundary"-style
    adapter bug like the one T31a patched in SRAM).

The test harness mirrors 'SramSpec' — a single @runSdram@ helper
drives the adapter for @n@ cycles, holding each transaction's bus
signals long enough to model a stalled core. Cycle-count
expectations come from the adapter's FSM:

@
  SH / SB                  3 cycles (SIdle → SWrite*Req → SIdle)
  SW                       4 cycles (SIdle → SWriteLoReq → SWriteHiReq → SIdle)
  LB / LBU / LH / LHU / LW 5 cycles (SIdle → SReadLoReq →
                                      SReadLoWait → SReadHiReq →
                                      SReadHiWait)
@

Plus 1 sim-model cycle for each read's @valid@ pulse — the
@sdramIpSim@'s @blockRam@ read latency. The test reads peek at the
commit cycle by direct indexing and note in a comment which cycle
each phase lands on.
-}
module SdramSpec (
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
import Riski5.MemMap (sdramBase)
import Riski5.Sdram (sdram, sdramIpSim)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, testCase)
import Prelude (Bool (..), Int, ($), (+))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Sdram"
    [ testCase "SW then LW round-trips the full 32-bit pattern" case_wordRoundTrip
    , testCase "SH at lo half + LW preserves the hi half" case_halfWriteLoSurvives
    , testCase "SH at hi half + LW preserves the lo half" case_halfWriteHiSurvives
    , testCase "addresses route through sdramBase offset correctly" case_baseOffset
    , testCase "back-to-back SH writes to same word both land" case_backToBackWrites
    , testCase "ready pulses at the expected cycle counts" case_readyCycleCounts
    ]

-- * Harness --------------------------------------------------------

{- | Drive 'sdram' with a matching 'sdramIpSim' behind it for @n@
cycles. Returns @(rdata, ready)@ traces.
-}
runSdram ::
  Int ->
  [Bool] ->
  [BitVector 32] ->
  [BitVector 32] ->
  [BitVector 4] ->
  ([BitVector 32], [Bool])
runSdram n sels addrs wdatas bes =
  let pad xs = xs P.++ P.repeat (P.last xs)
      selS = fromList (pad sels)
      addrS = fromList (pad addrs)
      wdataS = fromList (pad wdatas)
      beS = fromList (pad bes)
      renS = fromList (P.repeat True)
      -- 16 Ki half-words = 32 KB. Plenty for any phase-1 test access
      -- pattern; the adapter's address wraps modulo this size when the
      -- test addresses memory beyond it.
      initial :: Vec 16384 (BitVector 16)
      initial = CP.repeat 0
      go ::
        (HiddenClockResetEnable System) =>
        (Signal System (BitVector 32), Signal System Bool)
      go =
        let (rdata, busS, ready) = sdram selS addrS wdataS beS renS replyS
            replyS = sdramIpSim initial busS
         in (rdata, ready)
      rdataS' = P.fst go'
      readyS' = P.snd go'
      go' =
        withClockResetEnable @System clockGen resetGen enableGen go
   in ( sampleN @System n rdataS'
      , sampleN @System n readyS'
      )

-- | Sequence helper: hold a bus tuple for @n@ cycles.
holdFor ::
  Int ->
  (Bool, BitVector 32, BitVector 32, BitVector 4) ->
  [(Bool, BitVector 32, BitVector 32, BitVector 4)]
holdFor n b = P.replicate n b

-- | Split per-cycle bus tuples into four parallel signal lists.
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

-- | 32-bit store + 32-bit load round-trip. The FSM issues two
-- back-to-back 16-bit Avalon writes, then two back-to-back 16-bit
-- Avalon reads, and the adapter re-assembles the 32-bit word from
-- @(hi << 16) | lo@.
case_wordRoundTrip :: Assertion
case_wordRoundTrip = do
  -- Cycle 0:   reset (sel=False)
  -- Cycles 1-3: SW 0xDEADBEEF → sdramBase (SIdle → SWriteLoReq →
  --             SWriteHiReq, ready rises on cycle 3)
  -- Cycles 4-8: LW sdramBase (SIdle → SReadLoReq → SReadLoWait →
  --             SReadHiReq → SReadHiWait, ready rises on cycle 8
  --             with rdata fully assembled)
  --
  -- Hold-counts match the FSM's exact cycle budget for each op; a
  -- real core deasserts sel the cycle after ready rises, which the
  -- test sequence mirrors by moving to the next entry. Holding any
  -- longer would spuriously re-issue the same op.
  let reset_ = (False, 0, 0, 0)
      store = (True, sdramBase, 0xDEAD_BEEF, 0b1111)
      load = (True, sdramBase, 0, 0)
      seq_ =
        [reset_]
          P.++ holdFor 3 store
          P.++ holdFor 5 load
      (sels, addrs, wdatas, bes) = splitBus seq_
      (rdata, readyT) = runSdram 12 sels addrs wdatas bes
  assertEqual "ready on cycle 8" True (readyT P.!! 8)
  assertEqual
    "rdata at ready-high carries the full stored pattern"
    0xDEAD_BEEF
    (rdata P.!! 8)

-- | Half-word store to lo half + full-word load. Expect the hi
-- half of the resulting word to be zero (never written).
case_halfWriteLoSurvives :: Assertion
case_halfWriteLoSurvives = do
  -- Cycle 0: reset.
  -- Cycles 1-2: SH (lo half). SIdle → SWriteLoReq, ready on cycle 2.
  -- Cycles 3-7: LW. SIdle → SReadLoReq → SReadLoWait → SReadHiReq →
  --             SReadHiWait. ready on cycle 7.
  let reset_ = (False, 0, 0, 0)
      sh = (True, sdramBase, 0x0000_A5A5, 0b0011)
      load = (True, sdramBase, 0, 0)
      seq_ =
        [reset_]
          P.++ holdFor 2 sh
          P.++ holdFor 5 load
      (sels, addrs, wdatas, bes) = splitBus seq_
      (rdata, readyT) = runSdram 12 sels addrs wdatas bes
  assertEqual "ready on cycle 7" True (readyT P.!! 7)
  assertEqual
    "LW after SH lo half returns lo bytes only"
    0x0000_A5A5
    (rdata P.!! 7)

-- | Half-word store to hi half of the 32-bit word at @sdramBase@.
-- We first SW a 0xDEADBEEF pattern, then SH the hi half to 0x1234,
-- then LW — expect 0x1234_BEEF (hi replaced, lo intact).
case_halfWriteHiSurvives :: Assertion
case_halfWriteHiSurvives = do
  -- Cycle 0:    reset
  -- Cycles 1-3: SW 0xDEADBEEF → sdramBase (ready on cycle 3)
  -- Cycles 4-5: SH → sdramBase+2 (be=0b1100 = hi half; SIdle
  --             skips straight to SWriteHiReq, ready on cycle 5)
  -- Cycles 6-10: LW sdramBase (ready on cycle 10)
  let reset_ = (False, 0, 0, 0)
      sw = (True, sdramBase, 0xDEAD_BEEF, 0b1111)
      shHi = (True, sdramBase + 2, 0x1234_0000, 0b1100)
      load = (True, sdramBase, 0, 0)
      seq_ =
        [reset_]
          P.++ holdFor 3 sw
          P.++ holdFor 2 shHi
          P.++ holdFor 5 load
      (sels, addrs, wdatas, bes) = splitBus seq_
      (rdata, readyT) = runSdram 14 sels addrs wdatas bes
  assertEqual "ready on cycle 10" True (readyT P.!! 10)
  assertEqual
    "SH to hi half replaces only the top 16 bits"
    0x1234_BEEF
    (rdata P.!! 10)

-- | 'sdramBase + 4' must route to chip-word index 2 (the 32-bit
-- word above index 0). Two SWs at addr=0 and addr=4 must land in
-- independent words.
case_baseOffset :: Assertion
case_baseOffset = do
  -- Cycle 0: reset.
  -- Cycles 1-3: SW 0x1111_1111 → sdramBase   (ready on cycle 3)
  -- Cycles 4-6: SW 0x2222_2222 → sdramBase+4 (ready on cycle 6)
  -- Cycles 7-11: LW sdramBase                (ready on cycle 11)
  -- Cycles 12-16: LW sdramBase+4             (ready on cycle 16)
  let reset_ = (False, 0, 0, 0)
      sw0 = (True, sdramBase, 0x1111_1111, 0b1111)
      sw1 = (True, sdramBase + 4, 0x2222_2222, 0b1111)
      ld0 = (True, sdramBase, 0, 0)
      ld1 = (True, sdramBase + 4, 0, 0)
      seq_ =
        [reset_]
          P.++ holdFor 3 sw0
          P.++ holdFor 3 sw1
          P.++ holdFor 5 ld0
          P.++ holdFor 5 ld1
      (sels, addrs, wdatas, bes) = splitBus seq_
      (rdata, readyT) = runSdram 22 sels addrs wdatas bes
  assertEqual "ld0 ready on cycle 11" True (readyT P.!! 11)
  assertEqual "ld1 ready on cycle 16" True (readyT P.!! 16)
  assertEqual "LW addr=0 reads 0x1111_1111" 0x1111_1111 (rdata P.!! 11)
  assertEqual "LW addr=4 reads 0x2222_2222" 0x2222_2222 (rdata P.!! 16)

-- | Two SH writes to the same address. The second must overwrite
-- the first cleanly — no "in-flight transaction" interference.
case_backToBackWrites :: Assertion
case_backToBackWrites = do
  -- Cycle 0:    reset
  -- Cycles 1-2: SH 0x1111 → sdramBase (ready on cycle 2)
  -- Cycles 3-4: SH 0x2222 → sdramBase (ready on cycle 4; overwrite)
  -- Cycles 5-9: LW sdramBase          (ready on cycle 9)
  let reset_ = (False, 0, 0, 0)
      sh1 = (True, sdramBase, 0x0000_1111, 0b0011)
      sh2 = (True, sdramBase, 0x0000_2222, 0b0011)
      ld = (True, sdramBase, 0, 0)
      seq_ =
        [reset_]
          P.++ holdFor 2 sh1
          P.++ holdFor 2 sh2
          P.++ holdFor 5 ld
      (sels, addrs, wdatas, bes) = splitBus seq_
      (rdata, readyT) = runSdram 12 sels addrs wdatas bes
  assertEqual "ready on cycle 9" True (readyT P.!! 9)
  assertEqual
    "second SH overwrites first"
    0x0000_2222
    (rdata P.!! 9)

-- | Pin the exact ready-high cycles for SW and LW so a regression
-- (e.g. adding an accidental wait state) is caught immediately
-- rather than quietly slowing the whole data-path down.
case_readyCycleCounts :: Assertion
case_readyCycleCounts = do
  -- Pin the ready-high cycles so a regression adding an accidental
  -- wait state (or an off-by-one in the state machine) is caught
  -- here rather than slowing the whole data path silently. Holds
  -- are sized to the exact op cycle counts so sel deasserts
  -- immediately on the cycle after ready rises.
  let reset_ = (False, 0, 0, 0)
      sw = (True, sdramBase, 0x1234_5678, 0b1111)
      ld = (True, sdramBase, 0, 0)
      seq_ =
        [reset_]
          P.++ holdFor 3 sw
          P.++ holdFor 5 ld
      (sels, addrs, wdatas, bes) = splitBus seq_
      (_rdata, readyT) = runSdram 12 sels addrs wdatas bes
  -- SW:
  --   cycle 0: reset (sel=False). ready=True (idle, no sel).
  --   cycle 1: sel=1; state=SIdle (still). ready=False.
  --   cycle 2: state=SWriteLoReq. ready=False.
  --   cycle 3: state=SWriteHiReq, !waitrequest, so ready=True.
  assertEqual "SW ready-high cycle" True (readyT P.!! 3)
  -- LW:
  --   cycle 4: sel=1 load, state=SIdle.  ready=False
  --   cycle 5: SReadLoReq, !wait → accept. ready=False
  --   cycle 6: SReadLoWait, valid=True → lo captured. ready=False
  --   cycle 7: SReadHiReq, !wait → accept. ready=False
  --   cycle 8: SReadHiWait, valid=True → ready=True.
  assertEqual "LW ready-high cycle" True (readyT P.!! 8)
