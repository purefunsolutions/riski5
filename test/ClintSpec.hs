-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : ClintSpec
Description : Sim tests for the CLINT memory-mapped timer block.

Three things to pin down:

  1. @mtime@ free-runs at the core clock — every cycle it
     increments by 1.

  2. @mtimecmp@ is writable; on reset its lower 32 bits read as
     @0xFFFFFFFF@ (the @maxBound :: BitVector 64@ initial value
     puts the comparator out of reach until firmware sets a real
     deadline).

  3. @mtipS@ is exactly @mtime >= mtimecmp@. The simplest test
     drives @mtimecmp@ low (= 5) and checks that @mtipS@ rises
     within a few cycles.
-}
module ClintSpec (
  tests,
) where

import Clash.Prelude (
  BitVector,
  HiddenClockResetEnable,
  Signal,
  System,
  bundle,
  clockGen,
  enableGen,
  fromList,
  resetGen,
  sampleN,
  withClockResetEnable,
  (+),
 )
import Clash.Prelude qualified as CP
import Riski5.Clint (clint)
import Riski5.MemMap (clintBase)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, testCase)
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Clint"
    [ testCase "mtime increments every cycle" case_mtimeIncrement
    , testCase "writing mtimecmp low half settles" case_writeMtimecmp
    , testCase "mtipS rises once mtime >= mtimecmp" case_mtipRises
    ]

-- * Helpers ---------------------------------------------------------

{- | Drive the CLINT for @n@ cycles with the given (sel, addr, wdata, be)
streams; return the trace of @(rdata, mtip)@ samples.
-}
runClint ::
  P.Int ->
  [P.Bool] ->
  [BitVector 32] ->
  [BitVector 32] ->
  [BitVector 4] ->
  [(BitVector 32, P.Bool)]
runClint n sels addrs wdatas bes =
  let go ::
        (HiddenClockResetEnable System) =>
        Signal System (BitVector 32, P.Bool)
      go =
        let selS = fromList (sels P.++ P.repeat P.False)
            addrS = fromList (addrs P.++ P.repeat 0)
            wdataS = fromList (wdatas P.++ P.repeat 0)
            beS = fromList (bes P.++ P.repeat 0)
            renS = CP.pure P.False
            (rdata, mtip) = clint selS addrS wdataS beS renS
         in bundle (rdata, mtip)
   in sampleN @System n P.$
        withClockResetEnable @System clockGen resetGen enableGen go

-- * Cases -----------------------------------------------------------

-- Clash's System domain reset is asserted during cycle 0, so register
-- updates only start from cycle 1. After @k@ cycles past reset (i.e.
-- on sample index @k+1@), mtime should equal @k@.
case_mtimeIncrement :: Assertion
case_mtimeIncrement = do
  -- Read mtime low on cycle 5 (sample index 5). By then the register
  -- has been updating for 4 cycles past reset (cycles 1..4 each
  -- producing one increment). Expected mtime = 4.
  let n = 8
      idleSels = P.replicate 5 P.False
      readSels = [P.True] P.++ P.repeat P.False
      sels = idleSels P.++ readSels
      addrs = P.replicate 5 0 P.++ [clintBase + 0x00] P.++ P.repeat 0
      wdatas = P.repeat 0
      bes = P.repeat 0
      trace = runClint n sels addrs wdatas bes
      (rd, _mtip) = trace P.!! 5
  assertEqual "mtime low after 4 increments past reset" 4 rd

-- After writing mtimecmp low = 100, reading it back should give 100.
-- Skip cycle 0 (reset) — writes have to land on cycle 1 or later.
case_writeMtimecmp :: Assertion
case_writeMtimecmp = do
  -- Cycle 0: idle (reset window).
  -- Cycle 1: write 100 to mtimecmp low.
  -- Cycle 2: idle.
  -- Cycle 3: read mtimecmp low — should see the written 100.
  let sels = [P.False, P.True, P.False, P.True] P.++ P.repeat P.False
      addrs = [0, clintBase + 0x08, 0, clintBase + 0x08] P.++ P.repeat 0
      wdatas = [0, 100, 0, 0] P.++ P.repeat 0
      bes = [0, 0xF, 0, 0] P.++ P.repeat 0
      trace = runClint 6 sels addrs wdatas bes
      (rd, _) = trace P.!! 3
  assertEqual "mtimecmp low after write" 100 rd

-- mtimecmp starts at maxBound, so mtipS = False initially. After we
-- write small values to both halves, mtipS rises within a few more
-- cycles as mtime counts past mtimecmp.
case_mtipRises :: Assertion
case_mtipRises = do
  -- Cycle 0: idle (reset window).
  -- Cycle 1: write 5 to mtimecmp low.
  -- Cycle 2: write 0 to mtimecmp high (clear the high half so the
  --          comparison can actually trip).
  -- Cycles 3..: idle. mtime is incrementing; once it crosses 5,
  --          mtipS goes True.
  let sels = [P.False, P.True, P.True] P.++ P.repeat P.False
      addrs = [0, clintBase + 0x08, clintBase + 0x0C] P.++ P.repeat 0
      wdatas = [0, 5, 0] P.++ P.repeat 0
      bes = [0, 0xF, 0xF] P.++ P.repeat 0
      trace = runClint 20 sels addrs wdatas bes
      mtips = P.map P.snd trace
  assertBool
    ("expected mtipS to rise within 20 cycles, got: " P.++ P.show mtips)
    (P.or mtips)
