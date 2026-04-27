-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : TrapSpec
Description : Core-only tests for CSR + M-mode trap behaviour.

These tests drive the Clash core (via the same pure-Clash harness
that @CoreSimSpec@ uses) and inspect the write-back stream to
verify CSR read / write semantics and the trap path: illegal
instruction, @ECALL@, @EBREAK@, misaligned load / store, and
@MRET@. The Reference interpreter stops on trap (returning 'Left'
from 'Ref.run'), so trap tests live outside the differential
suite and assert concrete Core-side post-conditions directly.
-}
module TrapSpec (
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
import Riski5.Asm (
  Asm,
  assemble,
  csrrs,
  ecall,
  emit,
  mret,
  nop,
 )
import Riski5.Asm qualified as Asm
import Riski5.Core (core)
import Riski5.ISA
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, assertFailure, testCase)
import Prelude (Either (..), Int, Maybe (..), error, fmap, ($), (.))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Core — traps + CSRs"
    [ testCase "CSRRWI writes mtvec; ECALL jumps there; CSRRS reads mcause=11" case_ecallToMtvec
    , testCase "mepc captures the pc of the faulting ECALL" case_ecallMepc
    , testCase "EBREAK sets mcause=3" case_ebreak
    , testCase "illegal instruction sets mcause=2 and mtval=instr bits" case_illegal
    , testCase "MRET returns control to mepc" case_mretReturns
    , testCase "CSRRS sets bits; CSRRC clears bits" case_csrrsCsrrc
    , testCase "load from misaligned address sets mcause=4" case_loadMisaligned
    , testCase "store to misaligned address sets mcause=6" case_storeMisaligned
    ]

-- * Sim harness ----------------------------------------------------

type ProgSize = 64

{- | Same harness as @CoreSimSpec@: run a program for @n@ cycles, return
the observed @(pc, writeback)@ trace.
-}
runProgram ::
  [BitVector 32] ->
  Int ->
  [(BitVector 32, Maybe (BitVector 5, BitVector 32))]
runProgram program nCycles =
  let padded = program P.++ P.repeat 0x0000_0013
      progVec :: Vec ProgSize (BitVector 32)
      progVec = V.unsafeFromList (P.take 64 padded)
      pcToIdx :: BitVector 32 -> Index ProgSize
      pcToIdx pc =
        let w :: CP.Unsigned 32
            w = unpack (pc `shiftR` 2)
         in P.fromIntegral w
      go :: (HiddenClockResetEnable CP.System) => Signal CP.System (BitVector 32, Maybe (BitVector 5, BitVector 32))
      go =
        let
          -- imem driven by pcFetch; 1-cycle register delay matches
          -- the pipelined core's sync-read expectation. Writeback
          -- trace paired with pcExec.
          imem = CP.register 0x0000_0013 (fmap (\pc -> progVec !! pcToIdx pc) pcFetchS)
          dmem = CP.pure 0
          (pcFetchS, pcExecS, _, _, _, _, wbS, _) =
            core imem (CP.pure P.True) dmem (CP.pure P.False) (CP.pure P.False)
         in
          bundle (pcExecS, wbS)
   in sampleN @CP.System (2 P.* nCycles P.+ 20) $
        -- Generous budget for 5-stage pipeline: reset + 5-stage
        -- fill (6 cycles) + 2-cycle bubbles per trap / branch +
        -- enough headroom for trap handlers to retire.
        withClockResetEnable @CP.System clockGen resetGen enableGen go

-- | Accumulate writebacks into a register-file state map.
regsFrom :: [(BitVector 32, Maybe (BitVector 5, BitVector 32))] -> Map.Map Word32 Word32
regsFrom trace =
  -- Drop reset + 5-stage pipe-fill (6 cycles) before inspecting
  -- retirements.
  let wbs = P.drop 6 (P.map P.snd trace)
      updates = [(rdOf r, w32 v) | Just (r, v) <- wbs]
   in foldl' (P.flip (P.uncurry Map.insert)) Map.empty updates
 where
  rdOf :: BitVector 5 -> Word32
  rdOf b = P.fromIntegral (unpack b :: CP.Unsigned 5)
  w32 :: BitVector 32 -> Word32
  w32 b = P.fromIntegral (unpack b :: CP.Unsigned 32)

assemble' :: Asm () -> [BitVector 32]
assemble' prog = case assemble prog of
  Left err -> error ("assemble failed: " P.++ P.show err)
  Right ws -> ws

-- * Cases ----------------------------------------------------------

case_ecallToMtvec :: Assertion
case_ecallToMtvec = do
  -- Set mtvec = 16 via CSRRWI (uimm5 fits), ECALL, then in the
  -- handler read mcause into x1 and mepc into x2.
  let prog =
        assemble' $ do
          -- word 0: csrrwi x0, mtvec, uimm=16 → mtvec ← 16
          emit (Csrrwi x0 16 csrMtvec)
          -- word 1: ECALL → trap to mtvec.base = 16
          ecall
          -- words 2..3: padding (never executed)
          nop
          nop
          -- word 4 (addr 16): trap handler reads mcause then mepc.
          csrrs x1 x0 csrMcause -- x1 ← mcause
          csrrs x2 x0 csrMepc -- x2 ← mepc
  let trace = runProgram prog 6
      regs = regsFrom trace
  assertEqual "mcause == 11 (EcallFromM)" (Just 11) (Map.lookup 1 regs)
  assertEqual "mepc == 4 (pc of the ECALL)" (Just 4) (Map.lookup 2 regs)

case_ecallMepc :: Assertion
case_ecallMepc = do
  -- mtvec set to 24 so the handler lives at word 6.
  let prog =
        assemble' $ do
          emit (Csrrwi x0 24 csrMtvec)
          nop
          ecall -- at pc = 8
          nop -- filler
          nop -- filler
          nop -- filler (word 5 = addr 20)
          csrrs x3 x0 csrMepc
  let trace = runProgram prog 6
      regs = regsFrom trace
  assertEqual "mepc = 8 (pc of ECALL at word 2)" (Just 8) (Map.lookup 3 regs)

case_ebreak :: Assertion
case_ebreak = do
  let prog =
        assemble' $ do
          emit (Csrrwi x0 16 csrMtvec)
          emit Ebreak
          nop
          nop
          csrrs x4 x0 csrMcause
  let trace = runProgram prog 5
      regs = regsFrom trace
  assertEqual "mcause = 3 (Breakpoint)" (Just 3) (Map.lookup 4 regs)

case_illegal :: Assertion
case_illegal = do
  -- Word 0: CSRRWI sets mtvec = 16. Word 1: bytes 0xFFFFFFFF which
  -- decode returns Nothing for. Expect trap → mcause = 2,
  -- mtval = 0xFFFFFFFF.
  let illegalWord :: BitVector 32
      illegalWord = 0xFFFF_FFFF
      prog =
        [ 0x30505073 -- csrrwi x0, mtvec, uimm=16 (hand-encoded)
        , illegalWord
        , 0x00000013 -- NOP
        , 0x00000013 -- NOP
        , -- addr 16: trap handler
          0x342_02FF3 -- csrrs x31, x0, mcause (choose x31 just to use
        ]
      _ = prog -- kept as a reference; programmatic assembly below is cleaner
      -- Build the trap-handler program through the eDSL for resilience.
  let progAsm =
        assemble' $ do
          emit (Csrrwi x0 16 csrMtvec)
          emit (Addi x0 x0 0) -- placeholder; will be replaced below via index
          nop
          nop
          csrrs x5 x0 csrMcause
          csrrs x6 x0 csrMtval
      progFixed = P.take 1 progAsm P.++ [illegalWord] P.++ P.drop 2 progAsm
  let trace = runProgram progFixed 7
      regs = regsFrom trace
  assertEqual "mcause = 2 (IllegalInstr)" (Just 2) (Map.lookup 5 regs)
  assertEqual "mtval = the illegal word" (Just 0xFFFFFFFF) (Map.lookup 6 regs)

case_mretReturns :: Assertion
case_mretReturns = do
  -- 0: csrrwi mtvec = 20 (handler at word 5)
  -- 4: ecall
  -- 8: ADDI x7, x0, 99  ← the "after-return" instruction we want to hit
  -- 12..16: filler
  -- 20 (word 5): csrrs x8, x0, mepc; addi x8, x8, 4; csrrw x0, x8, mepc; mret
  let prog =
        assemble' $ do
          emit (Csrrwi x0 20 csrMtvec) -- word 0
          ecall -- word 1, pc = 4
          Asm.addi x7 x0 99 -- word 2 (pc=8) — must run after MRET
          nop -- word 3
          nop -- word 4 (pc=16, unreached)
          -- word 5 (pc=20): handler
          csrrs x8 x0 csrMepc -- x8 ← mepc = 4
          Asm.addi x8 x8 4 -- x8 = 8
          Asm.csrrw x0 x8 csrMepc -- mepc ← 8
          mret -- pc ← mepc = 8 → executes ADDI x7
  let trace = runProgram prog 10
      regs = regsFrom trace
  assertEqual "x7 set after MRET returns" (Just 99) (Map.lookup 7 regs)

case_csrrsCsrrc :: Assertion
case_csrrsCsrrc = do
  -- Use mscratch as a generic 32-bit scratchpad:
  -- 0: csrrwi mscratch = 0x1F   (writes 0x1F into mscratch)
  -- 4: addi x10, x0, 0x3        (x10 = 0b11)
  -- 8: csrrs x11, x10, mscratch (x11 ← old 0x1F; mscratch ← 0x1F | 0x3 = 0x1F)
  -- 12: csrrc x12, x10, mscratch (x12 ← 0x1F; mscratch ← 0x1F & ~0x3 = 0x1C)
  -- 16: csrrs x13, x0, mscratch (x13 ← 0x1C)
  let prog =
        assemble' $ do
          emit (Csrrwi x0 0x1F csrMscratch)
          Asm.addi x10 x0 0x3
          Asm.csrrs x11 x10 csrMscratch
          emit (Csrrc x12 x10 csrMscratch)
          csrrs x13 x0 csrMscratch
  let trace = runProgram prog 6
      regs = regsFrom trace
  assertEqual "x11 = original mscratch value" (Just 0x1F) (Map.lookup 11 regs)
  assertEqual "x12 = post-CSRRS mscratch" (Just 0x1F) (Map.lookup 12 regs)
  assertEqual "x13 = post-CSRRC mscratch (cleared low bits)" (Just 0x1C) (Map.lookup 13 regs)

case_loadMisaligned :: Assertion
case_loadMisaligned = do
  -- Attempt LW from odd address. Expected: cause 4, mtval = faulting addr.
  let prog =
        assemble' $ do
          emit (Csrrwi x0 20 csrMtvec)
          Asm.addi x20 x0 3 -- x20 = 3 (misaligned word addr)
          emit (Lw x21 x20 0) -- LW x21, 0(x20) → misalign
          nop
          nop
          csrrs x14 x0 csrMcause
          csrrs x15 x0 csrMtval
  let trace = runProgram prog 8
      regs = regsFrom trace
  assertEqual "mcause = 4 (LoadAddrMisaligned)" (Just 4) (Map.lookup 14 regs)
  assertEqual "mtval = faulting address 3" (Just 3) (Map.lookup 15 regs)

case_storeMisaligned :: Assertion
case_storeMisaligned = do
  let prog =
        assemble' $ do
          emit (Csrrwi x0 20 csrMtvec)
          Asm.addi x22 x0 5 -- x22 = 5 (odd → half-misalign)
          emit (Sh x22 x0 0) -- SH misaligned
          nop
          nop
          csrrs x16 x0 csrMcause
          csrrs x17 x0 csrMtval
  let trace = runProgram prog 8
      regs = regsFrom trace
  assertEqual "mcause = 6 (StoreAddrMisaligned)" (Just 6) (Map.lookup 16 regs)
  assertEqual "mtval = faulting address 5" (Just 5) (Map.lookup 17 regs)
