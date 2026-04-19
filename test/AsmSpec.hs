-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : AsmSpec
Description : Unit tests for the assembler eDSL.

For every pseudo-instruction and every label-dependent combinator,
we assemble a tiny program and check that the resulting machine
words decode back to the expected 'Instr' sequence. This gives us
end-to-end coverage of 'Riski5.Asm' → 'Riski5.Encode' → 'Riski5.Decode',
without baking in brittle hexadecimal golden values.
-}
module AsmSpec (
  tests,
) where

import Riski5.Asm
import Riski5.Decode (decode)
import Riski5.ISA
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Riski5.Asm"
    [ testCase "nop expands to ADDI x0 x0 0" case_nop
    , testCase "mv rd, rs expands to ADDI rd, rs, 0" case_mv
    , testCase "li with small immediate uses ADDI only" case_liSmall
    , testCase "li with large positive immediate uses LUI + ADDI" case_liLargePos
    , testCase "li with negative-fits-signed-12 immediate uses ADDI only" case_liNegSmall
    , testCase "li -4096 uses LUI 0xFFFFF + ADDI" case_liNegLarge
    , testCase "ret = JALR x0 ra 0" case_ret
    , testCase "j back-label emits JAL x0 with correct negative offset" case_jBackward
    , testCase "j forward-label emits JAL x0 with correct positive offset" case_jForward
    , testCase "beqz forward = BEQ rs x0 offset" case_beqzForward
    , testCase "two forward jumps + back-reference assemble together" case_combo
    , testCase "undefined label fails cleanly" case_undefined
    ]

-- * Helpers ----------------------------------------------------------

{- | Assemble a program; decode each resulting word and compare the
instruction sequence against what we expect.
-}
expect :: Asm () -> [Instr] -> Assertion
expect prog expected = case assemble prog of
  Left err -> assertFailure ("assemble failed: " <> show err)
  Right ws -> case traverse decode ws of
    Nothing -> assertFailure ("decoder rejected some word in: " <> show ws)
    Just got -> assertEqual "instruction sequence" expected got

expectFails :: Asm () -> Assertion
expectFails prog = case assemble prog of
  Left _ -> pure ()
  Right _ -> assertFailure "expected assembly error, got success"

-- * Cases ------------------------------------------------------------

case_nop :: Assertion
case_nop = expect nop [Addi x0 x0 0]

case_mv :: Assertion
case_mv = expect (mv x5 x10) [Addi x5 x10 0]

case_liSmall :: Assertion
case_liSmall = expect (li x10 42) [Addi x10 x0 42]

case_liLargePos :: Assertion
case_liLargePos =
  -- imm = 0x12345678. lower12 = sext(0x678) = 0x678 (positive, no sign
  -- extension flip). upper20 = (0x12345678 - 0x678) >> 12 = 0x12345.
  expect
    (li x10 0x1234_5678)
    [ Lui x10 0x12345
    , Addi x10 x10 0x678
    ]

case_liNegSmall :: Assertion
case_liNegSmall =
  -- -1 fits signed-12 (range [-2048,2047]), just ADDI.
  expect (li x10 (-1)) [Addi x10 x0 (-1)]

case_liNegLarge :: Assertion
case_liNegLarge =
  -- imm = -4096. lower12 = sext(0x000) = 0. upper20 = (-4096 - 0) / 4096 = -1.
  -- -1 as 20-bit unsigned = 0xFFFFF.
  expect
    (li x10 (-4096))
    [ Lui x10 0xFFFFF
    , Addi x10 x10 0
    ]

case_ret :: Assertion
case_ret = expect ret [Jalr x0 ra 0]

-- @lbl: addi; addi; j lbl@ — j at word 2 jumps back to word 0.
-- byteDelta = (0 - 2) * 4 = -8.
case_jBackward :: Assertion
case_jBackward =
  expect
    ( do
        lbl <- label
        addi x1 x0 1
        addi x1 x1 1
        j lbl
    )
    [ Addi x1 x0 1
    , Addi x1 x1 1
    , Jal x0 (-8)
    ]

-- @j end; addi; addi; end:@ — j at word 0 jumps forward to word 3.
-- byteDelta = (3 - 0) * 4 = 12.
case_jForward :: Assertion
case_jForward =
  expect
    ( do
        end <- labelUnplaced
        j end
        addi x1 x0 1
        addi x1 x1 1
        placeAt end
    )
    [ Jal x0 12
    , Addi x1 x0 1
    , Addi x1 x1 1
    ]

-- @beqz x1 end; addi; end:@ — beqz at word 0, end at word 2.
-- byteDelta = (2 - 0) * 4 = 8.
case_beqzForward :: Assertion
case_beqzForward =
  expect
    ( do
        end <- labelUnplaced
        beqz x1 end
        addi x2 x0 1
        placeAt end
    )
    [ Beq x1 x0 8
    , Addi x2 x0 1
    ]

-- Combines a forward and a backward label in the same program.
case_combo :: Assertion
case_combo =
  expect
    ( do
        start <- label -- word 0
        end <- labelUnplaced
        beqz x5 end -- word 0: BEQ x5 x0 +12
        addi x6 x0 7 -- word 1
        j start -- word 2: JAL x0 -8
        placeAt end -- binds `end` to word 3
        addi x7 x0 99 -- word 3: actual instr
    )
    [ Beq x5 x0 12
    , Addi x6 x0 7
    , Jal x0 (-8)
    , Addi x7 x0 99
    ]

case_undefined :: Assertion
case_undefined =
  expectFails $ do
    end <- labelUnplaced
    j end

-- end is never placed; placeAt not called.
