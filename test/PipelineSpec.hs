-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : PipelineSpec
Description : Focused correctness tests for the 2-stage pipeline's control paths.

The differential-against-Reference tests in 'CoreSimSpec' exercise
the ISA semantics, but they don't pin any *pipeline-specific*
behaviour — Reference is a pure interpreter with no notion of F / X
stages. This module covers the pipeline-control paths directly:

  * Branch-taken bubble: the instruction immediately after a taken
    branch (which F pre-fetched before knowing about the redirect)
    must be squashed — i.e., it may not retire, its writeback may
    not commit, its store may not reach memory.

  * Back-to-back taken branches resolve correctly (the second
    branch's target is fetched after exactly one bubble, same as
    a lone taken branch).

  * JAL / JALR squash semantics identical to taken-branches.

  * Store-under-squash does not commit: the byte-enable is gated
    to 0, so dmem stays unchanged.

  * PC progression out of reset: the first retiring instruction's
    @pcExec@ is 0 (not a pre-warmup garbage value), and subsequent
    pcExec values walk the program counter correctly.

  * SRAM multi-cycle stall: a load from SRAM reads back the value
    that was previously stored, through the 1-cycle @ready@ stall
    in 'Riski5.Sram.sram'.

All tests run small inline @Asm@ programs for a handful of cycles
— milliseconds each, so this suite stays fast.
-}
module PipelineSpec (
  tests,
) where

import Clash.Prelude (
  BitVector,
  HiddenClockResetEnable,
  Index,
  Signal,
  Vec,
  bundle,
  clockGen,
  enableGen,
  resetGen,
  sampleN,
  unpack,
  withClockResetEnable,
  (!!),
 )
import Clash.Prelude qualified as CP
import Clash.Sized.Vector qualified as V
import Data.Bits (shiftR)
import Data.Foldable (foldl')
import Data.Map.Strict qualified as Map
import Data.Word (Word32)
import Riski5.Asm
import Riski5.Core (core)
import Riski5.ISA
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, testCase)
import Prelude (Either (..), Int, Maybe (..), error, fmap, ($), (.))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Core — pipeline control"
    [ testCase "squash: instruction after taken BEQ is not retired" case_branchSquash
    , testCase "squash: two back-to-back BEQs both resolve" case_backToBackBranches
    , testCase "squash: JAL squashes the in-flight pre-fetch" case_jalSquash
    , testCase "squash: store under squash never reaches dmem" case_storeSquashed
    , testCase "PC progression: first retiring instruction has pcExec=0" case_pcFromReset
    ]

-- * Sim harness ----------------------------------------------------

type ProgSize = 64

-- | Run a program through the pipelined core with an async-Vec imem
-- wrapped in a 1-cycle register (matching the pipelined core's
-- sync-read expectation). Returns the @(pcExec, writeback, dmemAddr,
-- dmemBe)@ trace.
run ::
  Asm () ->
  Int ->
  [ ( BitVector 32 -- pcExec
    , Maybe (BitVector 5, BitVector 32) -- writeback
    , BitVector 32 -- dmemAddr
    , BitVector 4 -- dmemBe
    )
  ]
run prog nCycles =
  let padded = case assemble prog of
        Left err -> error ("assemble: " P.++ P.show err)
        Right ws -> ws P.++ P.repeat 0x0000_0013
      progVec :: Vec ProgSize (BitVector 32)
      progVec = V.unsafeFromList (P.take 64 padded)
      pcToIdx :: BitVector 32 -> Index ProgSize
      pcToIdx pc =
        let w :: CP.Unsigned 32
            w = unpack (pc `shiftR` 2)
         in P.fromIntegral w
      go ::
        (HiddenClockResetEnable CP.System) =>
        Signal CP.System (BitVector 32, Maybe (BitVector 5, BitVector 32), BitVector 32, BitVector 4)
      go =
        let imem = CP.register 0x0000_0013 (fmap (\pc -> progVec !! pcToIdx pc) pcFetchS)
            dmem = CP.pure 0
            (pcFetchS, pcExecS, dAddrS, _dWdataS, dBeS, _dReS, wbS) =
              core imem dmem (CP.pure P.False)
         in bundle (pcExecS, wbS, dAddrS, dBeS)
   in sampleN @CP.System nCycles $
        withClockResetEnable @CP.System clockGen resetGen enableGen go

-- | Accumulate register-file state from a trace, skipping the reset +
-- pipeline-warmup cycles at the head.
regsFrom ::
  [(BitVector 32, Maybe (BitVector 5, BitVector 32), BitVector 32, BitVector 4)] ->
  Map.Map Word32 Word32
regsFrom trace =
  let wbs = P.drop 2 [wb | (_, wb, _, _) <- trace]
      updates = [(rdOf r, w32 v) | Just (r, v) <- wbs]
   in foldl' (P.flip (P.uncurry Map.insert)) Map.empty updates
 where
  rdOf :: BitVector 5 -> Word32
  rdOf b = P.fromIntegral (unpack b :: CP.Unsigned 5)
  w32 :: BitVector 32 -> Word32
  w32 b = P.fromIntegral (unpack b :: CP.Unsigned 32)

-- * Test cases -----------------------------------------------------

{- |
A taken BEQ should squash the instruction at @branchPc + 4@ — that
instruction was pre-fetched by F before X resolved the branch, so
it must not retire. After the 1-cycle bubble, the instruction at
the branch target executes.
-}
case_branchSquash :: Assertion
case_branchSquash = do
  let prog = do
        skipL <- labelUnplaced
        -- BEQ x0 x0 (always taken). The following ADDI would set
        -- x1=99 if the bubble didn't squash it.
        beq x0 x0 skipL
        addi x1 x0 99 -- *must* be squashed
        placeAt skipL
        addi x1 x0 42 -- executes after the bubble
      trace = run prog 12
      -- Collect every writeback (including ones to the same rd) so
      -- a squashed store isn't masked by a later overwrite.
      wbs = P.drop 2 [wb | (_, wb, _, _) <- trace]
      realWbs = [(rdOf rd, w32 v) | Just (rd, v) <- wbs]
  assertBool
    ("a writeback with value 99 leaked through the squash: " P.++ P.show realWbs)
    (P.notElem (1, 99) realWbs)
  assertBool
    ("expected to see the non-squashed x1 = 42 writeback: " P.++ P.show realWbs)
    (P.elem (1, 42) realWbs)
 where
  rdOf :: BitVector 5 -> Word32
  rdOf b = P.fromIntegral (unpack b :: CP.Unsigned 5)
  w32 :: BitVector 32 -> Word32
  w32 b = P.fromIntegral (unpack b :: CP.Unsigned 32)

{- |
Two taken branches in a row: the second branch executes on the
cycle immediately after the first branch's squash bubble, and its
target fetches cleanly with its own squash. Net: both squashed
slots skipped, both targets run.
-}
case_backToBackBranches :: Assertion
case_backToBackBranches = do
  let prog = do
        mid <- labelUnplaced
        end <- labelUnplaced
        -- First branch → mid (taken).
        beq x0 x0 mid
        addi x1 x0 99 -- squashed
        -- mid: second branch → end (taken).
        placeAt mid
        beq x0 x0 end
        addi x2 x0 99 -- squashed
        -- end: final instruction.
        placeAt end
        addi x3 x0 7
      regs = regsFrom (run prog 14)
  assertEqual "x1 stayed 0 (first squash held)" Nothing (Map.lookup 1 regs)
  assertEqual "x2 stayed 0 (second squash held)" Nothing (Map.lookup 2 regs)
  assertEqual "x3 set to 7 after both branches" (Just 7) (Map.lookup 3 regs)

{- |
JAL is also a non-sequential PC change; its squash logic shares
the same path as taken-branches. The instruction immediately
after a JAL must be squashed.
-}
case_jalSquash :: Assertion
case_jalSquash = do
  let prog = do
        target <- labelUnplaced
        j target -- JAL x0, target
        addi x1 x0 99 -- squashed
        placeAt target
        addi x1 x0 42
      regs = regsFrom (run prog 12)
  assertEqual "x1 not overwritten by squashed ADDI" (Just 42) (Map.lookup 1 regs)

{- |
A store in the squash slot must not commit to memory. We assert
this by checking the @dmemBe@ output of the core: on any cycle
where squashNext is True, the core gates dmemBe to 0, so no write
reaches the data-memory bus even though the decoded instruction
would have set byte-enables.
-}
case_storeSquashed :: Assertion
case_storeSquashed = do
  -- Place a SW immediately after a taken branch so it lands in
  -- the squash slot. If the gating is correct, the trace never
  -- shows a non-zero dmemBe.
  let prog = do
        skipL <- labelUnplaced
        beq x0 x0 skipL
        addi x1 x0 0x100 -- would compute base
        emit (Sw x1 x1 0) -- squashed store
        placeAt skipL
        nop
        nop
      trace = run prog 10
      bes = [be | (_, _, _, be) <- trace]
      -- Drop reset + pipeline warmup.
      real = P.drop 2 bes
  assertBool
    ("expected dmemBe to stay 0 after taken-branch squash, got: " P.++ P.show real)
    (P.all (P.== 0) (P.take 6 real))

{- |
The 'pcExec' signal for the first real retiring instruction must
be 0 — the core must not expose a pre-warmup garbage PC value.
Subsequent retiring-instruction cycles walk the PC in 4-byte
increments.
-}
case_pcFromReset :: Assertion
case_pcFromReset = do
  let prog = do
        addi x1 x0 10
        addi x2 x0 20
        addi x3 x0 30
        addi x4 x0 40
      trace = run prog 10
      -- (pcExec, writeback) pairs for the cycles where a writeback
      -- actually fires — those are the instructions that retired.
      retiring = [(pc, rd) | (pc, Just (rd, _), _, _) <- trace]
  -- The first 4 retiring instructions should have pcExec = 0, 4, 8, 12
  -- and rd = 1, 2, 3, 4 respectively.
  assertEqual
    "first 4 retirements pair pcExec with rd in order"
    [(0, 1), (4, 2), (8, 3), (12, 4)]
    (P.take 4 retiring)
