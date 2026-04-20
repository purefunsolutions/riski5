-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : BramCoreSpec
Description : Core + BRAM integration — SW/LW round-trip on real memory.

Wires 'Riski5.Core.core' up to a single 'Riski5.Bram.bram' used as
both instruction memory (low half) and data memory (high half), so
a program can store a value and load it back without a separate
dmem slave. The programs differentially agree with
'Riski5.Reference' on the final integer register file.

This is the first test that exercises Core.hs's byte-enable +
store-data-lane plumbing end-to-end; if byte/half store alignment
goes wrong, or Core and Reference disagree on sign-extension
during loads, the catalog here surfaces it.
-}
module BramCoreSpec (
  tests,
) where

import Clash.Prelude (
  BitVector,
  HiddenClockResetEnable,
  Index,
  Signal,
  System,
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
  addi,
  assemble,
  label,
  li,
  nop,
 )
import Riski5.Asm qualified as Asm
import Riski5.Bram (bram)
import Riski5.Core (core)
import Riski5.ISA
import Riski5.Reference qualified as Ref
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, assertFailure, testCase)
import Prelude (Either (..), Int, Maybe (..), String, error, fmap, ($), (.))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Core + Bram"
    (P.map mkCase catalog)
 where
  mkCase (name, prog, nSteps) = testCase name (diff prog nSteps)

-- * Catalog --------------------------------------------------------

{- |
@(name, program, nSteps)@. Data accesses target word offsets
@0x80..0xFF@ (the \"high half\" of the 64-word BRAM); programs
are short enough to fit in the first 32 words (128 bytes).
-}
catalog :: [(String, Asm (), Int)]
catalog =
  [ ("SW/LW round-trip on word-aligned address", progSwLw, 4)
  , ("Multi-word store + load sequence", progMultiSw, 7)
  , ("SB + LBU unsigned byte round-trip", progSbLbu, 4)
  , ("SH + LH signed half round-trip (negative)", progShLh, 4)
  ]

progSwLw :: Asm ()
progSwLw = do
  addi x1 x0 0x100 -- base = 0x100 (data area)
  li x2 0x12345678
  Asm.sw x1 x2 0 -- mem[0x100] = 0x12345678
  Asm.lw x3 x1 0 -- x3 ← mem[0x100]

progMultiSw :: Asm ()
progMultiSw = do
  addi x1 x0 0x100
  addi x2 x0 11
  addi x3 x0 22
  Asm.sw x1 x2 0 -- mem[0x100] = 11
  Asm.sw x1 x3 4 -- mem[0x104] = 22
  Asm.lw x4 x1 0 -- x4 = 11
  Asm.lw x5 x1 4 -- x5 = 22

progSbLbu :: Asm ()
progSbLbu = do
  addi x1 x0 0x100
  addi x2 x0 0xAB -- low byte = 0xAB
  emit (Sb x1 x2 0) -- mem[0x100] low byte = 0xAB
  emit (Lbu x3 x1 0) -- x3 = 0xAB (zero-extended)

progShLh :: Asm ()
progShLh = do
  addi x1 x0 0x100
  addi x2 x0 (-100) -- 0xFFFFFF9C; low half = 0xFF9C
  emit (Sh x1 x2 0) -- mem[0x100] low half = 0xFF9C
  emit (Lh x3 x1 0) -- x3 = sign-extend(0xFF9C) = -100

emit :: Instr -> Asm ()
emit = Asm.emit

-- * Differential driver -------------------------------------------

diff :: Asm () -> Int -> Assertion
diff prog nSteps = do
  words_ <- case assemble prog of
    Left err -> do
      assertFailure ("assemble failed: " P.++ P.show err)
      P.pure []
    Right ws -> P.pure ws
  let coreRegs = runCore words_ nSteps
      refRegs = runReference words_ nSteps
  assertEqual
    "final register file state"
    (Map.filter (P./= 0) refRegs)
    (Map.filter (P./= 0) coreRegs)

{- |
Simulate the core + BRAM for @nSteps@ retired instructions.
BRAM stores program bytes at word offsets 0..31; data memory
uses word offsets 64..127 (byte addresses 0x100..0x1FC).
-}
runCore :: [BitVector 32] -> Int -> Map.Map Word32 Word32
runCore program nSteps =
  let cycles = nSteps P.+ 2 -- reset cycles (Clash System resetGen lasts longer than 1)
      trace =
        sampleN @System cycles $
          withClockResetEnable @System clockGen resetGen enableGen $
            simHarness program
      wbs = P.drop 2 (P.map P.snd trace) -- skip reset cycles
      updates = [(rdOf r, w32 v) | Just (r, v) <- wbs]
   in foldl' (P.flip (P.uncurry Map.insert)) Map.empty updates
 where
  rdOf :: BitVector 5 -> Word32
  rdOf b = P.fromIntegral (unpack b :: CP.Unsigned 5)
  w32 :: BitVector 32 -> Word32
  w32 b = P.fromIntegral (unpack b :: CP.Unsigned 32)

runReference :: [BitVector 32] -> Int -> Map.Map Word32 Word32
runReference program nSteps =
  let s0 = loadProgramIntoReference program
      (s1, _trap) = Ref.run nSteps s0
   in Map.mapKeys bvToKey (Ref.regs s1)
 where
  bvToKey :: BitVector 5 -> Word32
  bvToKey b = P.fromIntegral (unpack b :: CP.Unsigned 5)

loadProgramIntoReference :: [BitVector 32] -> Ref.MachineState
loadProgramIntoReference ws =
  foldl' writeWord Ref.initial (P.zip [0, 4 ..] ws)
 where
  writeWord s (addr, w) =
    let word32 :: Word32
        word32 = P.fromIntegral (unpack w :: CP.Unsigned 32)
     in s
          { Ref.memory =
              Map.insert addr (byte 0 word32) $
                Map.insert (addr P.+ 1) (byte 1 word32) $
                  Map.insert (addr P.+ 2) (byte 2 word32) $
                    Map.insert (addr P.+ 3) (byte 3 word32) (Ref.memory s)
          }
  byte k w = P.fromIntegral ((w `P.div` (256 P.^ k)) `P.mod` 256)

-- * Clash sim harness ---------------------------------------------

-- | 128-word = 512-byte BRAM; addresses 0x000..0x1FF.
type MemSize = 128

{- |
Wire the core to a single BRAM serving both imem (word offsets
0..31) and dmem (all offsets). Because reads are async and writes
commit on the clock edge, SW-then-LW on consecutive cycles works
correctly: the LW at cycle N+1 observes the state produced by the
SW at cycle N.
-}
simHarness ::
  (HiddenClockResetEnable System) =>
  [BitVector 32] ->
  Signal System (BitVector 32, Maybe (BitVector 5, BitVector 32))
simHarness program =
  let
    -- Program padded with NOPs up to the first half of the BRAM.
    progVec :: Vec MemSize (BitVector 32)
    progVec = V.unsafeFromList (P.take 128 (program P.++ P.repeat 0x0000_0013))
    -- Byte-to-word index conversion for both imem and dmem.
    byteToIdx :: BitVector 32 -> Index MemSize
    byteToIdx a =
      let w :: CP.Unsigned 32
          w = unpack (a `shiftR` 2)
       in P.fromIntegral w
    -- Core consumes same-cycle imem and dmem; a single BRAM covers
    -- both ports. Reads are multiplexed based on the "read address"
    -- of the cycle. For imem we use pc, for dmem we use dmemAddr.
    -- Writes only come from dmem.
    -- pcFetchS drives imem; pcExecS would be used for writeback-
    -- PC assertions (none in this test, so we discard it).
    (pcFetchS, _pcExecS, dAddrS, dWdataS, dBeS, _dReS, wbS) =
      core imemDataS dmemDataS (CP.pure P.False)

    -- Instruction memory: BRAM read-only, address driven by
    -- pcFetchS. A 1-cycle register delay matches the pipelined
    -- core's sync-read imem expectation.
    imemDataS =
      CP.register
        0x0000_0013
        ( bram
            progVec
            pcFetchS
            (CP.pure 0)
            (CP.pure 0)
        )

    -- Data memory: separate BRAM instance (same initial contents
    -- — any program data that needs preloading sits above the code
    -- in the same vector), writes come from core, reads from
    -- dmemAddr.
    dmemDataS =
      bram
        progVec
        dAddrS
        dWdataS
        dBeS
   in
    bundle (pcFetchS, wbS)
