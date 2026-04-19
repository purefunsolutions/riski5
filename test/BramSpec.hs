-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : BramSpec
Description : Direct tests for the async-read BRAM wrapper.

The SoC-level test that wires core + BRAM together to run a real
SW/LW program lives in 'BramCoreSpec'; this suite exercises
'Riski5.Bram.bram' in isolation so divergences get localised to
the memory itself rather than the bus shim.
-}
module BramSpec (
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
  repeat,
  resetGen,
  sampleN,
  withClockResetEnable,
 )
import Clash.Prelude qualified as CP
import Riski5.Bram (bram)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, testCase)
import Prelude (Int, ($))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Bram"
    [ testCase "word write commits on next cycle and reads back" case_writeRead
    , testCase "byte-enable writes leave other lanes intact" case_byteEn
    , testCase "two consecutive writes observed on their commit cycles" case_sequential
    ]

{- |
Simulate a 64-word BRAM for @n@ cycles. Returns the observed
read-data trace.
-}
simBram ::
  Int ->
  [BitVector 32] ->
  [BitVector 32] ->
  [BitVector 4] ->
  [BitVector 32]
simBram n addrs wdatas bes =
  let pad xs = xs P.++ P.repeat (P.last xs)
      addrSig = fromList (pad addrs)
      wdataSig = fromList (pad wdatas)
      beSig = fromList (pad bes)
      go ::
        (HiddenClockResetEnable System) =>
        Signal System (BitVector 32)
      go =
        bram
          (CP.repeat 0 :: Vec 64 (BitVector 32))
          addrSig
          wdataSig
          beSig
   in sampleN @System n $
        withClockResetEnable @System clockGen resetGen enableGen go

-- * Cases ----------------------------------------------------------

case_writeRead :: Assertion
case_writeRead = do
  -- Cycle 0: reset. Writes dropped.
  -- Cycle 1: write 0xDEADBEEF to word 3 (addr 12), BE = 0b1111.
  -- Cycle 2: memory has it; read word 3.
  let rdata =
        simBram
          4
          [0, 12, 12, 12]
          [0, 0xDEADBEEF, 0, 0]
          [0, 0b1111, 0, 0]
  -- Cycle 1: same-cycle read of word 3 still shows pre-write value.
  assertEqual "cycle 1: pre-write read" 0 (rdata P.!! 1)
  assertEqual "cycle 2: post-write read" 0xDEADBEEF (rdata P.!! 2)
  assertEqual "cycle 3: still there" 0xDEADBEEF (rdata P.!! 3)

case_byteEn :: Assertion
case_byteEn = do
  -- Start with word 0 full of 0x11223344 (via a wide write), then
  -- over-write byte lane 1 (BE = 0b0010) with 0xFF in that lane.
  let wholeWord :: BitVector 32
      wholeWord = 0x11223344
      partialLane :: BitVector 32
      partialLane = 0x0000_FF00
      rdata =
        simBram
          6
          [0, 0, 0, 0, 0, 0]
          [0, wholeWord, 0, partialLane, 0, 0]
          [0, 0b1111, 0, 0b0010, 0, 0]
  assertEqual "cycle 2: word written" 0x11223344 (rdata P.!! 2)
  assertEqual "cycle 3: second write still in flight" 0x11223344 (rdata P.!! 3)
  assertEqual "cycle 4: lane 1 updated, others intact" 0x1122FF44 (rdata P.!! 4)

case_sequential :: Assertion
case_sequential = do
  -- Writes at cycles 1 and 2 to different addresses; both visible
  -- at cycles 3 onwards via reads of their respective addresses.
  let trace =
        simBram
          6
          [0, 0, 4, 0, 4, 0] -- addresses over time
          [0, 0x1111, 0x2222, 0, 0, 0] -- wdata
          [0, 0b1111, 0b1111, 0, 0, 0] -- be
          -- Cycle 3: read addr 0 (should be 0x1111); cycle 4: read addr 4 (0x2222).
  assertEqual "cycle 3: addr 0 = 0x1111" 0x1111 (trace P.!! 3)
  assertEqual "cycle 4: addr 4 = 0x2222" 0x2222 (trace P.!! 4)
