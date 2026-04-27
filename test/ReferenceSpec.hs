-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : ReferenceSpec
Description : Sanity tests for the pure-Haskell RV32I reference executor.

Pin the reference executor's behaviour for a curated set of small
programs before we start diffing the real core against it. Each
program is built with the @Riski5.Asm@ eDSL, assembled, loaded into
the reference's memory, executed for a bounded number of steps, and
the final register / memory state is checked against hand-computed
expectations.
-}
module ReferenceSpec (
  tests,
) where

import Data.Foldable (foldl')
import Data.Map.Strict qualified as Map
import Data.Word (Word32, Word8)
import Riski5.Asm
import Riski5.ISA
import Riski5.Reference
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Riski5.Reference"
    [ testCase "ADDI x1, x0, 42 puts 42 in x1" case_addi
    , testCase "LUI + ADDI builds a 32-bit constant" case_luiAddi
    , testCase "ADD and SUB produce correct arithmetic" case_addSub
    , testCase "branch-taken BEQ skips an instruction" case_beqTaken
    , testCase "branch-not-taken BEQ falls through" case_beqNotTaken
    , testCase "SW followed by LW round-trips a word in memory" case_swLw
    , testCase "SRAI preserves sign on a negative input" case_srai
    , testCase "JAL stores return address and jumps" case_jal
    , testCase "ECALL raises EcallFromM trap" case_ecall
    , testCase "SLTI compares as signed" case_slti
    , testCase "LR.W after store latches the word and a reservation" case_lrW
    , testCase "SC.W with matching reservation succeeds and clears it" case_scWSuccess
    , testCase "SC.W without prior LR fails (rd = 1)" case_scWFailNoReservation
    , testCase "AMOSWAP.W swaps memory and rd atomically" case_amoSwap
    , testCase "AMOADD.W returns old value, memory becomes new sum" case_amoAdd
    , testCase "AMOXOR.W folds rs2 into memory with xor" case_amoXor
    , testCase "AMOAND/OR.W bitwise on memory" case_amoAndOr
    , testCase "AMOMIN.W is signed-min, AMOMINU is unsigned-min" case_amoMinMinu
    , testCase "AMOMAX.W is signed-max, AMOMAXU is unsigned-max" case_amoMaxMaxu
    , testCase "AMO* clears any live reservation" case_amoClearsReservation
    ]

-- * Helpers ---------------------------------------------------------

-- | Load an assembler program at address 0 into a fresh machine state.
loadAt0 :: Asm () -> MachineState
loadAt0 prog = case assemble prog of
  Left err -> error ("assemble failed in test setup: " <> show err)
  Right ws -> foldl' loadOne initial (zip [0, 4 ..] ws)
 where
  loadOne s (addr, w) = storeWord (fromIntegral addr) (fromIntegral w) s

  storeWord a v st =
    st
      { memory =
          Map.insert a (bytePart 0 v) $
            Map.insert (a + 1) (bytePart 1 v) $
              Map.insert (a + 2) (bytePart 2 v) $
                Map.insert (a + 3) (bytePart 3 v) (memory st)
      }

  bytePart :: Int -> Word32 -> Word8
  bytePart k v = fromIntegral ((v `div` (256 ^ k)) `mod` 256)

-- | Run up to @n@ steps; assert no trap; return final state.
assertRun :: Int -> MachineState -> IO MachineState
assertRun n s0 = case run n s0 of
  (s', Nothing) -> pure s'
  (_, Just cause) -> do
    assertFailure ("unexpected trap: " <> show cause)
    pure s0 -- unreachable, satisfies the typechecker

-- * Cases -----------------------------------------------------------

case_addi :: Assertion
case_addi = do
  s <- assertRun 1 (loadAt0 (addi x1 x0 42))
  assertEqual "x1" 42 (readReg x1 s)

case_luiAddi :: Assertion
case_luiAddi = do
  -- li x10 0x12345678  ⇒  LUI x10 0x12345 ; ADDI x10 x10 0x678
  s <- assertRun 2 (loadAt0 (li x10 0x1234_5678))
  assertEqual "x10" 0x1234_5678 (readReg x10 s)

case_addSub :: Assertion
case_addSub = do
  s <-
    assertRun
      4
      ( loadAt0 $ do
          addi x1 x0 100
          addi x2 x0 25
          add x3 x1 x2 -- x3 = 125
          sub x4 x1 x2 -- x4 = 75
      )
  assertEqual "x3" 125 (readReg x3 s)
  assertEqual "x4" 75 (readReg x4 s)

case_beqTaken :: Assertion
case_beqTaken = do
  -- beq x0,x0,+8 (taken); addi x1,x0,1 (skipped); addi x2,x0,7
  -- Two real instructions are executed (BEQ then ADDI x2); stepping
  -- a third time would run off the end of the program.
  s <-
    assertRun
      2
      ( loadAt0 $ do
          skipL <- labelUnplaced
          beq x0 x0 skipL
          addi x1 x0 1
          placeAt skipL
          addi x2 x0 7
      )
  assertEqual "x1 unchanged" 0 (readReg x1 s)
  assertEqual "x2 set" 7 (readReg x2 s)

case_beqNotTaken :: Assertion
case_beqNotTaken = do
  -- addi x5,1 ; addi x6,2 ; beq x5,x6,+8 (not taken) ; addi x7,3
  s <-
    assertRun
      4
      ( loadAt0 $ do
          skipL <- labelUnplaced
          addi x5 x0 1
          addi x6 x0 2
          beq x5 x6 skipL
          addi x7 x0 3
          placeAt skipL
      )
  assertEqual "x7 set (fall-through)" 3 (readReg x7 s)

case_swLw :: Assertion
case_swLw = do
  -- Program text at 0x0..; we write a word at 0x100 and load it back.
  -- x1 = 0xDEADBEEF (2 instrs via LUI+ADDI), base = 0x100, sw, lw.
  -- Total 5 real instructions.
  s <-
    assertRun
      5
      ( loadAt0 $ do
          li x1 0xDEAD_BEEF
          addi x2 x0 0x100
          sw x2 x1 0
          lw x3 x2 0
      )
  assertEqual "x3 matches stored word" 0xDEAD_BEEF (readReg x3 s)

case_srai :: Assertion
case_srai = do
  -- addi x1, x0, -8 ; srai x1, x1, 1 ; expect x1 = -4 (0xFFFFFFFC)
  s <-
    assertRun
      2
      ( loadAt0 $ do
          addi x1 x0 (-8)
          srai x1 x1 1
      )
  assertEqual "x1 = -4 (signed shift-right)" 0xFFFF_FFFC (readReg x1 s)

case_jal :: Assertion
case_jal = do
  -- JAL x1, +8 ; addi x2,7 (skipped) ; addi x3,9
  s <-
    assertRun
      2
      ( loadAt0 $ do
          skipL <- labelUnplaced
          jal x1 skipL
          addi x2 x0 7
          placeAt skipL
          addi x3 x0 9
      )
  assertEqual "x1 holds pc+4 of JAL (which lived at pc=0)" 4 (readReg x1 s)
  assertEqual "x2 unchanged" 0 (readReg x2 s)
  assertEqual "x3 set" 9 (readReg x3 s)

case_ecall :: Assertion
case_ecall = do
  let s0 = loadAt0 ecall
  case run 1 s0 of
    (_, Just EcallFromM) -> pure ()
    (_, Just other) -> assertFailure ("wrong trap cause: " <> show other)
    (_, Nothing) -> assertFailure "ECALL did not raise a trap"

case_slti :: Assertion
case_slti = do
  -- addi x1,x0,-5 ; slti x2,x1,0  => x2 = 1 (signed: -5 < 0)
  -- addi x3,x0,5  ; slti x4,x3,0  => x4 = 0
  s <-
    assertRun
      4
      ( loadAt0 $ do
          addi x1 x0 (-5)
          slti x2 x1 0
          addi x3 x0 5
          slti x4 x3 0
      )
  assertEqual "x2 = 1" 1 (readReg x2 s)
  assertEqual "x4 = 0" 0 (readReg x4 s)

-- * A-extension cases ------------------------------------------------
--
-- All these reuse a small staging block: load a word into address
-- 0x100 first via SW, then exercise the A-ext op against that
-- address. Word 0x100 is comfortably above the program text at
-- 0x000 so there's no overlap.

-- LR.W reads the word and registers the reservation.
case_lrW :: Assertion
case_lrW = do
  s <-
    assertRun
      5
      ( loadAt0 $ do
          li x1 0xCAFE_BABE
          addi x2 x0 0x100
          sw x2 x1 0
          lr_w x3 x2 0
      )
  -- Note: the 'li' macro expands to 2 insts when the immediate
  -- doesn't fit signed-12. 0xCAFEBABE doesn't fit, so li = 2 insts;
  -- total instructions = 2 + 1 + 1 + 1 = 5. ✓
  assertEqual "x3 latched the word" 0xCAFE_BABE (readReg x3 s)
  assertEqual "reservation set on the addr" (Just 0x100) (reservation s)

-- SC.W with a live matching reservation: write succeeds, rd = 0,
-- memory updated, reservation cleared. Instruction count: li(2) +
-- addi(1) + sw(1) + lr_w(1) + li(2) + sc_w(1) = 8.
case_scWSuccess :: Assertion
case_scWSuccess = do
  s <-
    assertRun
      8
      ( loadAt0 $ do
          li x1 0x1111_1111
          addi x2 x0 0x100
          sw x2 x1 0
          lr_w x3 x2 0
          li x4 0x2222_2222
          sc_w x5 x2 x4 0
      )
  assertEqual "rd reports success (0)" 0 (readReg x5 s)
  assertEqual "memory updated" 0x2222_2222 (readWord32 0x100 s)
  assertEqual "reservation cleared" Nothing (reservation s)

-- SC.W without a prior LR.W fails: writes nothing, rd = 1.
-- li(2) + addi(1) + sw(1) + li(2) + sc_w(1) = 7.
case_scWFailNoReservation :: Assertion
case_scWFailNoReservation = do
  s <-
    assertRun
      7
      ( loadAt0 $ do
          li x1 0x1111_1111
          addi x2 x0 0x100
          sw x2 x1 0
          li x4 0x2222_2222
          sc_w x5 x2 x4 0
      )
  assertEqual "rd reports failure (1)" 1 (readReg x5 s)
  assertEqual
    "memory unchanged"
    0x1111_1111
    (readWord32 0x100 s)

-- AMOSWAP exchanges rd and memory atomically.
-- li(2) + addi(1) + sw(1) + li(2) + amoswap_w(1) = 7.
case_amoSwap :: Assertion
case_amoSwap = do
  s <-
    assertRun
      7
      ( loadAt0 $ do
          li x1 0xAAAA_AAAA
          addi x2 x0 0x100
          sw x2 x1 0
          li x3 0xBBBB_BBBB
          amoswap_w x4 x2 x3 0
      )
  assertEqual "rd = original mem" 0xAAAA_AAAA (readReg x4 s)
  assertEqual "mem = rs2" 0xBBBB_BBBB (readWord32 0x100 s)

-- li 100 + addi 0x100 + sw + addi 25 + amoadd_w = 5 instrs (100 fits signed-12).
case_amoAdd :: Assertion
case_amoAdd = do
  s <-
    assertRun
      5
      ( loadAt0 $ do
          li x1 100
          addi x2 x0 0x100
          sw x2 x1 0
          addi x3 x0 25
          amoadd_w x4 x2 x3 0
      )
  assertEqual "rd = old value (100)" 100 (readReg x4 s)
  assertEqual "mem = 100 + 25" 125 (readWord32 0x100 s)

-- li(2) + addi(1) + sw(1) + li(2) + amoxor_w(1) = 7.
case_amoXor :: Assertion
case_amoXor = do
  s <-
    assertRun
      7
      ( loadAt0 $ do
          li x1 0xF0F0_F0F0
          addi x2 x0 0x100
          sw x2 x1 0
          li x3 0x0F0F_0F0F
          amoxor_w x4 x2 x3 0
      )
  assertEqual "rd = old" 0xF0F0_F0F0 (readReg x4 s)
  assertEqual "mem = xor" 0xFFFF_FFFF (readWord32 0x100 s)

case_amoAndOr :: Assertion
case_amoAndOr = do
  -- AND: 0xFFFF_FFFF (=-1, fits signed-12 as -1) & 0x00FF (fits) = 0xFF.
  -- li(1) + addi(1) + sw(1) + li(1) + amoand(1) = 5.
  sAnd <-
    assertRun
      5
      ( loadAt0 $ do
          li x1 0xFFFF_FFFF
          addi x2 x0 0x100
          sw x2 x1 0
          li x3 0x0000_00FF
          amoand_w x4 x2 x3 0
      )
  assertEqual "AND mem = 0xFF" 0x0000_00FF (readWord32 0x100 sAnd)
  assertEqual "AND rd = old" 0xFFFF_FFFF (readReg x4 sAnd)
  -- OR: 0x0F0 | 0x00F = 0x0FF. addi(1) + addi(1) + sw(1) + addi(1) + amoor(1) = 5.
  sOr <-
    assertRun
      5
      ( loadAt0 $ do
          addi x1 x0 0x0F0
          addi x2 x0 0x100
          sw x2 x1 0
          addi x3 x0 0x00F
          amoor_w x4 x2 x3 0
      )
  assertEqual "OR mem = 0x0FF" 0x0FF (readWord32 0x100 sOr)

case_amoMinMinu :: Assertion
case_amoMinMinu = do
  -- AMOMIN.W (signed): mem = min(-1, 5) = -1. addi(1)+addi(1)+sw(1)+addi(1)+amo(1) = 5.
  sMin <-
    assertRun
      5
      ( loadAt0 $ do
          addi x1 x0 (-1)
          addi x2 x0 0x100
          sw x2 x1 0
          addi x3 x0 5
          amomin_w x4 x2 x3 0
      )
  assertEqual "MIN mem signed-min" 0xFFFF_FFFF (readWord32 0x100 sMin)
  -- AMOMINU.W (unsigned): mem = minu(0xFFFFFFFF, 5) = 5. Same shape, 5 instrs.
  sMinu <-
    assertRun
      5
      ( loadAt0 $ do
          addi x1 x0 (-1)
          addi x2 x0 0x100
          sw x2 x1 0
          addi x3 x0 5
          amominu_w x4 x2 x3 0
      )
  assertEqual "MINU mem unsigned-min" 5 (readWord32 0x100 sMinu)

case_amoMaxMaxu :: Assertion
case_amoMaxMaxu = do
  -- AMOMAX.W (signed): mem = max(-1, 5) = 5. 5 instrs.
  sMax <-
    assertRun
      5
      ( loadAt0 $ do
          addi x1 x0 (-1)
          addi x2 x0 0x100
          sw x2 x1 0
          addi x3 x0 5
          amomax_w x4 x2 x3 0
      )
  assertEqual "MAX mem signed-max" 5 (readWord32 0x100 sMax)
  -- AMOMAXU.W (unsigned): max(0xFFFFFFFF, 5) = 0xFFFFFFFF unchanged. 5 instrs.
  sMaxu <-
    assertRun
      5
      ( loadAt0 $ do
          addi x1 x0 (-1)
          addi x2 x0 0x100
          sw x2 x1 0
          addi x3 x0 5
          amomaxu_w x4 x2 x3 0
      )
  assertEqual "MAXU mem unsigned-max" 0xFFFF_FFFF (readWord32 0x100 sMaxu)

-- li(1) + addi(1) + sw(1) + lr_w(1) + addi(1) + amoswap(1) + addi(1) + sc_w(1) = 8.
case_amoClearsReservation :: Assertion
case_amoClearsReservation = do
  s <-
    assertRun
      8
      ( loadAt0 $ do
          li x1 0
          addi x2 x0 0x100
          sw x2 x1 0
          lr_w x3 x2 0
          addi x5 x0 7
          amoswap_w x6 x2 x5 0
          addi x7 x0 9
          sc_w x8 x2 x7 0
      )
  assertEqual "SC.W after AMO fails" 1 (readReg x8 s)
  assertEqual "memory left as AMO set it" 7 (readWord32 0x100 s)

-- Helper: read a 32-bit word out of memory in little-endian.
readWord32 :: Word32 -> MachineState -> Word32
readWord32 a s =
  let b0 = fromIntegral (Map.findWithDefault 0 a (memory s))
      b1 = fromIntegral (Map.findWithDefault 0 (a + 1) (memory s))
      b2 = fromIntegral (Map.findWithDefault 0 (a + 2) (memory s))
      b3 = fromIntegral (Map.findWithDefault 0 (a + 3) (memory s))
   in b0 + 256 * (b1 + 256 * (b2 + 256 * b3))
