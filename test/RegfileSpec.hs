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
Description : Regression tests for both regfile backings.

Two parallel test groups:

  * __async backing__ ('Riski5.Regfile.regfileAsync') — the
    register-array with combinational reads. The phase-1 /
    pipelineless-style core uses this.

  * __sync backing__ ('Riski5.Regfile.regfileSync') — the
    blockRam-backed variant with 1-cycle read latency, targeted at
    Cyclone II M4K. The 5-stage pipelined core uses this.

Both share the same black-box contract (x0 reads zero, writes to
x0 are dropped, two independent read ports); they differ in when
a read is observable:

  * Async: @rs1@ presented at cycle N → @rs1Data@ valid at cycle
    N. A write at cycle N commits at edge N→N+1, so a read at
    cycle N+1 of the written rd returns the new value.

  * Sync: @rs1@ presented at cycle N → @rs1Data@ valid at cycle
    N+1. A write at cycle N commits at edge N→N+1, so a read
    addr presented at cycle N+1 (output at cycle N+2) returns
    the new value. The @same-cycle read-write@ window falls in
    the forwarding logic's lap at the pipeline above.
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
import Riski5.Regfile (regfileAsync, regfileSync)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, testCase)
import Prelude (Int, Maybe (..))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Regfile"
    [ testGroup
        "regfileAsync (LE, combinational reads)"
        [ testCase "write cycle N, read cycle N+1 returns the value" case_asyncWriteReadX5
        , testCase "writes to x0 are ignored" case_asyncWriteX0Ignored
        , testCase "reads of x0 always return zero" case_asyncReadX0Zero
        , testCase "two read ports return independent values" case_asyncTwoReadPorts
        ]
    , testGroup
        "regfileSync (BRAM, 1-cycle read latency)"
        [ testCase "write cycle N, read at cycle N+2 sees the value" case_syncWriteReadX5
        , testCase "writes to x0 are ignored" case_syncWriteX0Ignored
        , testCase "reads of x0 always return zero" case_syncReadX0Zero
        , testCase "two read ports return independent values" case_syncTwoReadPorts
        ]
    ]

-- * Async harness --------------------------------------------------

{- | Clash-simulate the async register file for @n@ cycles and return
the @(rs1, rs2)@ output streams.
-}
simulateAsync ::
  Int ->
  [BitVector 5] ->
  [BitVector 5] ->
  [Maybe (BitVector 5, BitVector 32)] ->
  ([BitVector 32], [BitVector 32])
simulateAsync n rs1Stream rs2Stream wrStream =
  let pad xs = xs P.++ P.repeat (P.last xs)
      rs1Sig = fromList (pad rs1Stream)
      rs2Sig = fromList (pad rs2Stream)
      wrSig = fromList (pad wrStream)
      go ::
        (HiddenClockResetEnable System) =>
        (Signal System (BitVector 32), Signal System (BitVector 32))
      go = regfileAsync rs1Sig rs2Sig wrSig
      (r1, r2) = withClockResetEnable @System clockGen resetGen enableGen go
   in (sampleN n r1, sampleN n r2)

-- * Sync harness ---------------------------------------------------

{- | Clash-simulate the sync register file for @n@ cycles. Same
argument shape as 'simulateAsync'; the cycle at which an output
corresponds to a given rs1 / rs2 input shifts by one relative to
the async variant because of the extra read-latch cycle.
-}
simulateSync ::
  Int ->
  [BitVector 5] ->
  [BitVector 5] ->
  [Maybe (BitVector 5, BitVector 32)] ->
  ([BitVector 32], [BitVector 32])
simulateSync n rs1Stream rs2Stream wrStream =
  let pad xs = xs P.++ P.repeat (P.last xs)
      rs1Sig = fromList (pad rs1Stream)
      rs2Sig = fromList (pad rs2Stream)
      wrSig = fromList (pad wrStream)
      go ::
        (HiddenClockResetEnable System) =>
        (Signal System (BitVector 32), Signal System (BitVector 32))
      go = regfileSync rs1Sig rs2Sig wrSig
      (r1, r2) = withClockResetEnable @System clockGen resetGen enableGen go
   in (sampleN n r1, sampleN n r2)

-- * Async cases ----------------------------------------------------

case_asyncWriteReadX5 :: Assertion
case_asyncWriteReadX5 = do
  -- Cycle 0 is under reset (Clash's `resetGen` holds reset high for
  -- one cycle), so the first write has to come on cycle 1 onwards.
  --
  -- Cycle 0: reset. Writes dropped.
  -- Cycle 1: write 42 → x5. Read rs1 = 5 returns 0 (pre-commit).
  -- Cycle 2: regs[5] = 42. Read rs1 = 5 returns 42.
  let (r1, _) =
        simulateAsync
          4
          [5, 5, 5, 5]
          [0, 0, 0, 0]
          [Nothing, Just (5, 42), Nothing, Nothing]
  assertEqual "cycle 1: pre-commit read of x5" 0 (r1 P.!! 1)
  assertEqual "cycle 2: post-commit read of x5" 42 (r1 P.!! 2)
  assertEqual "cycle 3: value still there" 42 (r1 P.!! 3)

case_asyncWriteX0Ignored :: Assertion
case_asyncWriteX0Ignored = do
  let (r1, _) =
        simulateAsync
          4
          [0, 0, 0, 0]
          [0, 0, 0, 0]
          [Just (0, 0xDEADBEEF), Nothing, Nothing, Nothing]
  assertEqual "x0 stays 0 despite the write" [0, 0, 0, 0] r1

case_asyncReadX0Zero :: Assertion
case_asyncReadX0Zero = do
  -- Write 42 to x5 but always read x0; every cycle must be 0.
  let (r1, _) =
        simulateAsync
          4
          [0, 0, 0, 0]
          [0, 0, 0, 0]
          [Just (5, 42), Nothing, Nothing, Nothing]
  assertEqual "x0 reads zero regardless of other writes" [0, 0, 0, 0] r1

case_asyncTwoReadPorts :: Assertion
case_asyncTwoReadPorts = do
  -- Cycle 0: reset.
  -- Cycle 1: write x1 = 11. rs1 = 1 reads 0 (pre-commit); rs2 = 2 reads 0.
  -- Cycle 2: regs[1] = 11. Write x2 = 22. rs1 reads 11; rs2 reads 0.
  -- Cycle 3: regs[2] = 22. rs1 reads 11; rs2 reads 22.
  let (r1, r2) =
        simulateAsync
          5
          [1, 1, 1, 1, 1]
          [2, 2, 2, 2, 2]
          [Nothing, Just (1, 11), Just (2, 22), Nothing, Nothing]
  assertEqual "cycle 3: rs1 (x1) = 11" 11 (r1 P.!! 3)
  assertEqual "cycle 3: rs2 (x2) = 22" 22 (r2 P.!! 3)

-- * Sync cases -----------------------------------------------------

case_syncWriteReadX5 :: Assertion
case_syncWriteReadX5 = do
  -- Cycle 0: reset.
  -- Cycle 1: wr = Just (5, 42); rs1 = 5. blockRam latches read
  --          addr 5 at edge 1→2, and commits memory[5] := 42.
  -- Cycle 2: output reflects memory[5] prior to cycle-1's write
  --          (blockRamPow2 is read-first for same-cycle
  --          read+write) → 0.
  -- Cycle 3: output = memory[5] = 42. rs1 addr captured at edge
  --          2→3 was still 5 (we hold it), and cycle-2's memory
  --          state already includes the write.
  -- Cycle 4: still 42 — no further writes.
  --
  -- The 1-cycle-latency contract therefore expects the first
  -- cycle on which the write is visible to be __cycle 3__, i.e.
  -- write+2. Pipelines above 'regfileSync' handle the 0 at cycle
  -- 2 via forwarding.
  let (r1, _) =
        simulateSync
          5
          [5, 5, 5, 5, 5]
          [0, 0, 0, 0, 0]
          [Nothing, Just (5, 42), Nothing, Nothing, Nothing]
  assertEqual "cycle 2: raw blockRam hasn't applied write yet" 0 (r1 P.!! 2)
  assertEqual "cycle 3: write is visible" 42 (r1 P.!! 3)
  assertEqual "cycle 4: value still there" 42 (r1 P.!! 4)

case_syncWriteX0Ignored :: Assertion
case_syncWriteX0Ignored = do
  -- Write to x0 at cycle 1 should be dropped by the input filter;
  -- read of x0 stays 0 for every post-warmup cycle.
  -- 'blockRamPow2' during reset leaves its internal read-address
  -- register undefined, so cycles 0/1 produce X bits; we check
  -- from cycle 2 onwards where the read path has caught up.
  let (r1, _) =
        simulateSync
          5
          [0, 0, 0, 0, 0]
          [0, 0, 0, 0, 0]
          [Just (0, 0xDEADBEEF), Nothing, Nothing, Nothing, Nothing]
  assertEqual "x0 stays 0 despite the write" [0, 0, 0] (P.drop 2 r1)

case_syncReadX0Zero :: Assertion
case_syncReadX0Zero = do
  -- Write 42 to x5, always read x0. x0's slot is never written
  -- (filter drops it), so blockRam slot 0 stays at its init value
  -- (0). Every post-warmup cycle of the read stream is 0.
  let (r1, _) =
        simulateSync
          5
          [0, 0, 0, 0, 0]
          [0, 0, 0, 0, 0]
          [Just (5, 42), Nothing, Nothing, Nothing, Nothing]
  assertEqual "x0 reads zero regardless of other writes" [0, 0, 0] (P.drop 2 r1)

case_syncTwoReadPorts :: Assertion
case_syncTwoReadPorts = do
  -- Two writes back-to-back, then reads of both registers should
  -- show the committed values with the 1-cycle read-latch delay.
  --
  -- Cycle 0: reset.
  -- Cycle 1: write x1 = 11. rs1 = 1, rs2 = 2 latched at edge 1→2.
  -- Cycle 2: write x2 = 22. memory[1] = 11 committed. addrs
  --          latched at edge 2→3.
  -- Cycle 3: no write. memory[2] = 22 committed. addrs latched
  --          at edge 3→4.
  -- Cycle 4: output = memory[addr @ cycle 3] = (memory[1],
  --          memory[2]) = (11, 22). Memory fully reflects both
  --          writes because both committed at earlier edges.
  let (r1, r2) =
        simulateSync
          5
          [1, 1, 1, 1, 1]
          [2, 2, 2, 2, 2]
          [Nothing, Just (1, 11), Just (2, 22), Nothing, Nothing]
  assertEqual "cycle 4: rs1 (x1) = 11" 11 (r1 P.!! 4)
  assertEqual "cycle 4: rs2 (x2) = 22" 22 (r2 P.!! 4)
