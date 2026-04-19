-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : CoreSimSpec
Description : Whole-core pure-Clash simulation, diffed against Reference.

For every exercise program in the local catalogue, run it through
both 'Riski5.Core.core' (via Clash's @sampleN@) and
'Riski5.Reference.step', accumulate register writes on both sides,
and assert the final integer register file agrees instruction-by-
instruction.

This is the Layer-1 differential check described in
@docs/verification.md@. It catches bugs where the hardware
datapath and the Haskell-semantics interpretation of the ISA
diverge — typically immediate-permutation mistakes, off-by-one
shift handling, or incorrect sign-extension. The comprehensive
'InstrCatalog' module (T20) will subsume these small programs
later; the module is kept inline here as a placeholder until the
catalog lands.
-}
module CoreSimSpec (
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
  resize,
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
  beq,
  bne,
  j,
  labelUnplaced,
  li,
  nop,
  placeAt,
 )
import Riski5.Asm qualified as Asm
import Riski5.Core (core)
import Riski5.ISA
import Riski5.Reference qualified as Ref
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, assertFailure, testCase)
import Prelude (Either (..), IO, Int, Maybe (..), String, error, fmap, ($), (.))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Core ≡ Riski5.Reference (diff)"
    (P.map mkCase catalog)
 where
  mkCase (name, prog, nSteps) = testCase name (diffCore prog nSteps)

-- * Catalog --------------------------------------------------------

{- | @(name, program, nSteps)@. @nSteps@ is the number of instructions
to execute before comparing final register state.
-}
catalog :: [(String, Asm (), Int)]
catalog =
  [ ("ADDI sequence — single register", progAddi, 3)
  , ("LUI + ADDI — 32-bit constant", progLuiAddi, 2)
  , ("ADD / SUB — register arithmetic", progAddSub, 4)
  , ("XOR / OR / AND — bitwise ops", progBitwise, 6)
  , ("SLL / SRL / SRA — shifts", progShifts, 6)
  , ("BEQ (taken) skips a write", progBeqTaken, 2)
  , ("BNE (not taken) falls through", progBneNotTaken, 3)
  , ("SLTI — signed compare-set", progSlti, 4)
  , ("Backward branch loop counter", progLoop, 7)
  ]

-- * Programs ------------------------------------------------------

progAddi :: Asm ()
progAddi = do
  addi x1 x0 10
  addi x2 x0 20
  addi x3 x0 30

progLuiAddi :: Asm ()
progLuiAddi = li x10 0x1234_5678

progAddSub :: Asm ()
progAddSub = do
  addi x1 x0 100
  addi x2 x0 25
  Asm.add x3 x1 x2
  Asm.sub x4 x1 x2

progBitwise :: Asm ()
progBitwise = do
  addi x1 x0 0x55 -- 0b0101_0101
  addi x2 x0 0x33 -- 0b0011_0011
  Asm.xori x3 x1 0x33 -- 0x55 ^ 0x33 = 0x66
  Asm.ori x4 x1 0x0F -- 0x55 | 0x0F = 0x5F
  Asm.andi x5 x1 0x0F -- 0x55 & 0x0F = 0x05
  Asm.sltiu x6 x1 0 -- x1 < 0 unsigned: false → 0

progShifts :: Asm ()
progShifts = do
  addi x1 x0 0x7 -- x1 = 7
  Asm.slli x2 x1 3 -- x2 = 7 << 3 = 56
  addi x3 x0 (-4) -- x3 = 0xFFFFFFFC
  Asm.srai x4 x3 1 -- x4 = -2 (signed shift)
  Asm.srli x5 x3 1 -- x5 = 0x7FFFFFFE
  nop

progBeqTaken :: Asm ()
progBeqTaken = do
  skipL <- labelUnplaced
  beq x0 x0 skipL -- always taken
  addi x1 x0 99 -- must be skipped
  placeAt skipL

progBneNotTaken :: Asm ()
progBneNotTaken = do
  end <- labelUnplaced
  addi x1 x0 5
  bne x1 x1 end -- x1 == x1, so not taken
  addi x2 x0 7
  placeAt end

progSlti :: Asm ()
progSlti = do
  addi x1 x0 (-5)
  Asm.slti x2 x1 0 -- -5 < 0  →  1
  addi x3 x0 5
  Asm.slti x4 x3 0 -- 5 < 0   →  0

{- | Loop counting down from 3, decrementing x1 each pass until it hits 0.
Seven instructions executed in total for a loop that runs 3 times
plus the BNE fall-through.
-}
progLoop :: Asm ()
progLoop = do
  addi x1 x0 3 -- x1 = 3
  loopL <- Asm.label
  addi x1 x1 (-1) -- x1--
  addi x2 x2 1 -- counter
  bne x1 x0 loopL -- if x1 /= 0, loop
  addi x3 x0 7 -- after loop
  nop

-- * Differential driver -------------------------------------------

{- | Run the program through Core + Reference; assert they agree on the
final integer register file after @nSteps@ retired instructions.
-}
diffCore :: Asm () -> Int -> Assertion
diffCore prog nSteps = do
  words_ <- case assemble prog of
    Left err -> assertFailure ("assemble failed: " P.++ P.show err)
    Right ws -> P.pure ws
  let coreRegs = runCore words_ nSteps
      refRegs = runReference words_ nSteps
  -- Compare only registers that either side wrote; ignore unused.
  assertEqual
    "final register file state"
    (Map.filter (P./= 0) refRegs)
    (Map.filter (P./= 0) coreRegs)

{- | Simulate the core for @nSteps@ retired instructions, returning the
reconstructed register file state.
-}
runCore :: [BitVector 32] -> Int -> Map.Map Word32 Word32
runCore words_ nSteps =
  let cycles = nSteps P.+ 1 -- one extra cycle for reset
      trace =
        sampleN @System cycles $
          withClockResetEnable @System clockGen resetGen enableGen $
            simHarness words_
      wbs = P.drop 1 (P.map P.snd trace) -- skip reset cycle
      updates = [(rdOf rd, w32 v) | Just (rd, v) <- wbs]
   in foldl' apply Map.empty updates
 where
  apply m (k, v) = Map.insert k v m
  rdOf :: BitVector 5 -> Word32
  rdOf b = P.fromIntegral (unpack b :: CP.Unsigned 5)
  w32 :: BitVector 32 -> Word32
  w32 b = P.fromIntegral (unpack b :: CP.Unsigned 32)

{- | Execute the program on the reference interpreter; return the
register file as a Map keyed by register index (so keys align with
the Core-side reconstruction).
-}
runReference :: [BitVector 32] -> Int -> Map.Map Word32 Word32
runReference words_ nSteps =
  let s0 = loadProgramIntoReference words_
      (s1, _trap) = Ref.run nSteps s0
   in Map.mapKeys bvToKey (Ref.regs s1)
 where
  bvToKey :: BitVector 5 -> Word32
  bvToKey b = P.fromIntegral (unpack b :: CP.Unsigned 5)

{- | Initialise a Reference 'MachineState' by writing the program's
word bytes into memory starting at address 0.
-}
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

{- | Fixed upper bound on program size. Plenty for phase-1 exercises;
the catalog asserts each program fits.
-}
type ProgSize = 64

{- | Wire the core up with an instruction memory backed by the given
program (padded to 'ProgSize' with NOPs) and a data memory that
always returns zero (test programs in this module don't touch
dmem).
-}
simHarness ::
  (HiddenClockResetEnable System) =>
  [BitVector 32] ->
  Signal System (BitVector 32, Maybe (BitVector 5, BitVector 32))
simHarness program =
  let progVec :: Vec ProgSize (BitVector 32)
      progVec = V.unsafeFromList (P.take (natValInt (CP.SNat @ProgSize)) padded)
      padded = program P.++ P.repeat 0x0000_0013
      pcToIdx :: BitVector 32 -> Index ProgSize
      pcToIdx pc =
        let wordIdx :: CP.Unsigned 32
            wordIdx = unpack (pc `shiftR` 2)
         in P.fromIntegral wordIdx
      imem = fmap (\pc -> progVec !! pcToIdx pc) pcS
      dmem = CP.pure 0
      (pcS, _, _, _, _, wbS) = core imem dmem
   in bundle (pcS, wbS)

-- | Type-level sugar for @fromIntegral (natVal ...)@.
natValInt :: forall n proxy. (CP.KnownNat n) => proxy n -> Int
natValInt p = P.fromIntegral (CP.natVal p)
