-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause

{- |
Module      : RegfileSpec
Description : Regression tests for the register file.

Drive 'Riski5.Regfile.regfile' from Clash's pure simulator, sampling
a handful of cycles per test. Exercises the load-after-store round
trip, the @x0@ hard-wired-zero behaviour (both read and write), and
simultaneous independent reads from both ports.
-}
module RegfileSpec (
  tests,
) where

import Clash.Prelude (BitVector, HiddenClockResetEnable, Signal, System, clockGen, enableGen, fromList, resetGen, sampleN, withClockResetEnable)
import Riski5.Regfile (regfile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, testCase)
import Prelude (Bool (..), Int, Maybe (..), (++))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Regfile"
    [ testCase "write then read x5 round-trips the value" case_writeReadX5
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
      (r1, r2) =
        withClockResetEnable @System clockGen resetGen enableGen go
   in (sampleN n r1, sampleN n r2)

-- * Cases ----------------------------------------------------------

case_writeReadX5 :: Assertion
case_writeReadX5 = do
  -- Cycle 0: write 42 → x5, address rs1 = 5.
  -- Cycle 1: idle, rs1 still = 5.
  -- Cycle 2: idle, rs1 still = 5.
  -- We expect the write to become visible a cycle or two later.
  let (r1, _) =
        simulateRegfile
          6
          (P.replicate 6 5)
          (P.replicate 6 0)
          (Just (5, 42) : P.replicate 5 Nothing)
  -- Somewhere in the first six samples the value 42 must appear.
  assertEqual
    "x5 read contains 42"
    True
    (42 `P.elem` r1)

case_writeX0Ignored :: Assertion
case_writeX0Ignored = do
  -- Attempt to write 0xDEADBEEF to x0. Read x0 afterwards; must be 0.
  let (r1, _) =
        simulateRegfile
          6
          (P.replicate 6 0)
          (P.replicate 6 0)
          (Just (0, 0xDEADBEEF) : P.replicate 5 Nothing)
  assertEqual
    "x0 always reads zero despite the write"
    (P.replicate 6 0)
    r1

case_readX0Zero :: Assertion
case_readX0Zero = do
  -- Write 42 to x5, but read x0 every cycle; must always be 0.
  let (r1, _) =
        simulateRegfile
          6
          (P.replicate 6 0)
          (P.replicate 6 0)
          (Just (5, 42) : P.replicate 5 Nothing)
  assertEqual
    "x0 reads zero regardless of other writes"
    (P.replicate 6 0)
    r1

case_twoReadPorts :: Assertion
case_twoReadPorts = do
  -- Write 11 to x1, 22 to x2 on separate cycles; then read both.
  let addrs1 = [0, 0, 0, 1, 1, 1] -- rs1 eventually points at x1
      addrs2 = [0, 0, 0, 2, 2, 2] -- rs2 eventually points at x2
      writes =
        [ Just (1, 11) -- cycle 0
        , Just (2, 22) -- cycle 1
        , Nothing
        , Nothing
        , Nothing
        , Nothing
        ]
      (r1, r2) = simulateRegfile 8 addrs1 addrs2 writes
  assertEqual "x1 read contains 11" True (11 `P.elem` r1)
  assertEqual "x2 read contains 22" True (22 `P.elem` r2)
