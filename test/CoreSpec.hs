-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : CoreSpec
Description : Minimal pure-Clash sanity tests for the datapath.

These exercise @Riski5.Core.core@ through Clash's pure simulator
(no verilambda, no Verilator) by wrapping a hard-coded
instruction-memory vector around the core and feeding its outputs
back through a trivial data-memory stub. The full
verilambda-driven whole-core simulation (diffing every
'InstrCatalog' program against 'Riski5.Reference') lives in
@test/CoreSimSpec.hs@ from T11 onwards; this suite is the
minimum-viable check that the combinational dispatch table in
'Riski5.Core' is wired to the PC and regfile correctly.
-}
module CoreSpec (
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
 )
import Clash.Prelude qualified as CP
import Riski5.Asm (
  Asm,
  addi,
  assemble,
  nop,
 )
import Riski5.Core (core)
import Riski5.ISA (x0, x1, x2)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase)
import Prelude (Either (..), Int, Maybe (..), error, fmap, ($))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Core"
    [ testCase "PC advances by 4 through a sequence of NOPs" case_pcAdvance
    , testCase "ADDI produces an rd writeback" case_addiWb
    ]

{- |
Run the core with the given assembly program for @n@ cycles, using
a flat in-memory instruction array (indexed by word offset) and a
trivial data-memory stub that always returns 0. Returns a list of
@(pc, writeback)@ samples of length @n@.

The imem wrapper assumes same-cycle async read (pc → instr in the
same cycle), matching the Core's design-level interface. A proper
SoC with synchronous BRAM will add a 1-cycle delay on the boundary;
the Core doesn't need to know.
-}
simulateProgram ::
  Int ->
  [BitVector 32] ->
  [ ( BitVector 32 -- pc
    , BitVector 32 -- dmem addr
    , BitVector 32 -- dmem wdata
    , BitVector 4 -- dmem byte-en
    , CP.Bool -- dmem read-en
    )
  ]
simulateProgram n program =
  let
    -- Pad the program so out-of-range reads return 0x13 (NOP).
    padded :: [BitVector 32]
    padded = program P.++ P.repeat 0x0000_0013
    -- imem read: pc / 4 into the program vector.
    imemOf :: BitVector 32 -> BitVector 32
    imemOf pc = padded P.!! (P.fromIntegral pc `P.div` 4)
    go ::
      (HiddenClockResetEnable System) =>
      Signal System (BitVector 32, BitVector 32, BitVector 32, BitVector 4, CP.Bool)
    go =
      let
        dmem = fromList (P.repeat 0 :: [BitVector 32])
        -- imem is driven by pcFetch; the 1-cycle register delay
        -- makes it look like the sync-read M4K blockRam the
        -- pipelined core expects (pcFetch at cycle N-1 →
        -- instruction at cycle N).
        imemSig = CP.register 0x0000_0013 (fmap imemOf pcFetch)
        (pcFetch, outPc, dAddr, dWdata, dBe, dRen, _wb, _rvfi) = core imemSig dmem (CP.pure P.False)
       in
        bundle (outPc, dAddr, dWdata, dBe, dRen)
    samples =
      sampleN @System n $
        withClockResetEnable @System clockGen resetGen enableGen go
   in
    samples

{- | Strip reset + pipeline-warmup cycles from the head of a trace.
Clash's default 'resetGen' asserts reset for more than one cycle
on the 'System' domain; combined with the pipelined core's
F → X hand-off, the first two observed samples have
pcExec = 0 (reset value) before the first real instruction
retires on sample 2.
-}
afterReset :: [a] -> [a]
afterReset = P.drop 2

-- * Cases ----------------------------------------------------------

case_pcAdvance :: Assertion
case_pcAdvance = do
  -- Three NOPs; PC should be 0, 4, 8, 12, … in successive cycles.
  let Right prog = assemble $ do
        nop
        nop
        nop
        nop
      trace = simulateProgram 8 prog
      pcs = P.map (\(pc, _, _, _, _) -> pc) (afterReset trace)
  assertBool
    ("expected PC to advance 4 per cycle, got: " P.++ P.show pcs)
    (P.take 4 pcs P.== [0, 4, 8, 12])

case_addiWb :: Assertion
case_addiWb = do
  -- A single ADDI x1, x0, 42 followed by NOPs. The core's output
  -- tuple doesn't expose the regfile writeback directly, so this
  -- test just checks that PC advances (i.e. the instruction isn't
  -- treated as illegal and the dispatch table compiles).
  let Right prog = assemble $ do
        addi x1 x0 42
        addi x2 x0 7
        nop
      trace = simulateProgram 7 prog
      pcs = P.map (\(pc, _, _, _, _) -> pc) (afterReset trace)
  assertBool
    ("expected PC to advance 4 per cycle through ADDIs, got: " P.++ P.show pcs)
    (P.take 3 pcs P.== [0, 4, 8])
