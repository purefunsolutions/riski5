-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause

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
