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

  * a half-word write commits on the next cycle and reads back;
  * byte writes (UB / LB selectivity) leave the other lane intact;
  * the 'Riski5.MemMap.sramBase' offset is honoured (CPU address
    @0x2000_0000 + n@ maps to half-word index @n / 2@).

Phase-1C contract is half-word-only — full 32-bit access is T31a
(deferred to phase 2 with the pipeline).
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
import Prelude (Bool (..), Int, ($), (+), (.))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Sram"
    [ testCase "halfword write commits on next cycle and reads back" case_halfWord
    , testCase "byte writes via UB/LB leave the other lane intact" case_byteSelectivity
    , testCase "addresses route through sramBase offset" case_baseOffset
    ]

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
        let (rdata, _pins, _store) = sramSim initial selS addrS wdataS beS renS
         in rdata
   in sampleN @System n $
        withClockResetEnable @System clockGen resetGen enableGen go

-- * Cases ----------------------------------------------------------

case_halfWord :: Assertion
case_halfWord = do
  -- Cycle 0: reset. Cycle 1: SH 0xBEEF to address sramBase.
  -- Cycle 2: read back from same address.
  let writeAddr = sramBase
      readAddr = sramBase
      -- sequence: idle, write, read, read, ...
      sels = [False, True, True] P.++ P.repeat True
      addrs = [0, writeAddr, readAddr] P.++ P.repeat readAddr
      wdatas = [0, 0xDEAD_BEEF, 0] P.++ P.repeat 0
      bes = [0, 0b0011, 0] P.++ P.repeat 0 -- LH = both bytes of low half
      trace = runSram 6 sels addrs wdatas bes
  -- Cycle 3 sees the committed value (write request lands on cycle
  -- 1→2 edge; read on cycle 2 uses the *new* store from the cycle
  -- 2→3 edge).
  assertEqual "rdata after write" 0x0000_BEEF (trace P.!! 3)

case_byteSelectivity :: Assertion
case_byteSelectivity = do
  -- Pre-populate by issuing two SH writes (one full half-word each),
  -- then rewrite only the low byte of the first half-word and read
  -- the result back. The high byte should survive.
  let addr0 = sramBase
      addr1 = sramBase + 4 -- next half-word index up
      sels = [False, True, True, True, True] P.++ P.repeat True
      addrs = [0, addr0, addr1, addr0, addr0] P.++ P.repeat addr0
      wdatas =
        [ 0
        , 0x0000_AABB -- SH 0xAABB → addr0 (both bytes)
        , 0x0000_CCDD -- SH 0xCCDD → addr1
        , 0x0000_0099 -- SB 0x99 → addr0 low byte only
        , 0
        ]
          P.++ P.repeat 0
      bes =
        [0, 0b0011, 0b0011, 0b0001, 0]
          P.++ P.repeat 0
      trace = runSram 8 sels addrs wdatas bes
  -- After three writes (cycles 1..3) the read on cycle 4 sees the
  -- committed state from the cycle 3→4 edge: low byte = 0x99,
  -- high byte preserved at 0xAA.
  assertEqual "high byte preserved after byte write" 0x0000_AA99 (trace P.!! 5)

case_baseOffset :: Assertion
case_baseOffset = do
  -- Two writes 4 bytes apart should land in adjacent half-words —
  -- because the controller drops bit 0, addresses sramBase and
  -- sramBase+4 map to half-word indices 0 and 2 (independent).
  -- The model commits a write request at cycle N as part of the
  -- N→N+1 register edge, so the cycle-1 write is visible from
  -- cycle 2 onwards and the cycle-2 write is visible from cycle 3.
  let addr0 = sramBase
      addr2 = sramBase + 4
      sels = [False, True, True, True, True] P.++ P.repeat True
      addrs = [0, addr0, addr2, addr0, addr2] P.++ P.repeat addr2
      wdatas = [0, 0x0000_1111, 0x0000_2222, 0, 0] P.++ P.repeat 0
      bes = [0, 0b0011, 0b0011, 0, 0] P.++ P.repeat 0
      trace = runSram 8 sels addrs wdatas bes
  -- Cycle 3: read at addr0; both writes have committed by now.
  assertEqual "addr0 reads 0x1111" 0x0000_1111 (trace P.!! 3)
  -- Cycle 4: read at addr2.
  assertEqual "addr2 reads 0x2222" 0x0000_2222 (trace P.!! 4)
