-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : RegfileSpec
Description : Regression tests for the async-read register file.

The regfile is a register-array with combinational reads (see
'Riski5.Regfile'). These tests drive it through Clash's pure
@sampleN@ simulator and confirm:

 * A write at cycle N is visible at the read port on cycle N+1
   (the write takes effect on the clock edge; the read is
   combinational over the latched-vector state).
 * Writes to @x0@ are silently dropped.
 * Reads of @x0@ always return zero, regardless of history.
 * The two read ports return independent values.
-}
module RegfileSpec (
  tests,
) where

import Clash.Prelude (
  BitVector,
  HiddenClockResetEnable,
  Signal,
  System,
  clockGen,
  enableGen,
  fromList,
  resetGen,
  sampleN,
  withClockResetEnable,
 )
import Riski5.Regfile (regfile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, testCase)
import Prelude (Int, Maybe (..))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Regfile"
    [ testCase "write cycle N, read cycle N+1 returns the value" case_writeReadX5
    , testCase "writes to x0 are ignored" case_writeX0Ignored
    , testCase "reads of x0 always return zero" case_readX0Zero
    , testCase "two read ports return independent values" case_twoReadPorts
    ]

{- | Clash-simulate the register file for @n@ cycles and return the
@(rs1, rs2)@ output streams.
-}
simulateRegfile ::
  Int ->
  [BitVector 5] ->
  [BitVector 5] ->
  [Maybe (BitVector 5, BitVector 32)] ->
  ([BitVector 32], [BitVector 32])
simulateRegfile n rs1Stream rs2Stream wrStream =
  let pad xs = xs P.++ P.repeat (P.last xs)
      rs1Sig = fromList (pad rs1Stream)
      rs2Sig = fromList (pad rs2Stream)
      wrSig = fromList (pad wrStream)
      go ::
        (HiddenClockResetEnable System) =>
        (Signal System (BitVector 32), Signal System (BitVector 32))
      go = regfile rs1Sig rs2Sig wrSig
      (r1, r2) = withClockResetEnable @System clockGen resetGen enableGen go
   in (sampleN n r1, sampleN n r2)

-- * Cases ----------------------------------------------------------

case_writeReadX5 :: Assertion
case_writeReadX5 = do
  -- Cycle 0 is under reset (Clash's `resetGen` holds reset high for
  -- one cycle), so the first write has to come on cycle 1 onwards.
  --
  -- Cycle 0: reset. Writes dropped.
  -- Cycle 1: write 42 → x5. Read rs1 = 5 returns 0 (pre-commit).
  -- Cycle 2: regs[5] = 42. Read rs1 = 5 returns 42.
  let (r1, _) =
        simulateRegfile
          4
          [5, 5, 5, 5]
          [0, 0, 0, 0]
          [Nothing, Just (5, 42), Nothing, Nothing]
  assertEqual "cycle 1: pre-commit read of x5" 0 (r1 P.!! 1)
  assertEqual "cycle 2: post-commit read of x5" 42 (r1 P.!! 2)
  assertEqual "cycle 3: value still there" 42 (r1 P.!! 3)

case_writeX0Ignored :: Assertion
case_writeX0Ignored = do
  let (r1, _) =
        simulateRegfile
          4
          [0, 0, 0, 0]
          [0, 0, 0, 0]
          [Just (0, 0xDEADBEEF), Nothing, Nothing, Nothing]
  assertEqual "x0 stays 0 despite the write" [0, 0, 0, 0] r1

case_readX0Zero :: Assertion
case_readX0Zero = do
  -- Write 42 to x5 but always read x0; every cycle must be 0.
  let (r1, _) =
        simulateRegfile
          4
          [0, 0, 0, 0]
          [0, 0, 0, 0]
          [Just (5, 42), Nothing, Nothing, Nothing]
  assertEqual "x0 reads zero regardless of other writes" [0, 0, 0, 0] r1

case_twoReadPorts :: Assertion
case_twoReadPorts = do
  -- Cycle 0: reset.
  -- Cycle 1: write x1 = 11. rs1 = 1 reads 0 (pre-commit); rs2 = 2 reads 0.
  -- Cycle 2: regs[1] = 11. Write x2 = 22. rs1 reads 11; rs2 reads 0.
  -- Cycle 3: regs[2] = 22. rs1 reads 11; rs2 reads 22.
  let (r1, r2) =
        simulateRegfile
          5
          [1, 1, 1, 1, 1]
          [2, 2, 2, 2, 2]
          [Nothing, Just (1, 11), Just (2, 22), Nothing, Nothing]
  assertEqual "cycle 3: rs1 (x1) = 11" 11 (r1 P.!! 3)
  assertEqual "cycle 3: rs2 (x2) = 22" 22 (r2 P.!! 3)
