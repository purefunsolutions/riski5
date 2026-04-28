-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : IFetchSpec
Description : Unit tests for the IF realigner state machine.

The realigner is a pure function ('Riski5.Core.IFetch.realignerStep')
hoisted out of Core.hs so the FIFO + state-machine logic can be
exercised without spinning up a full SoC sim. This spec walks the
4 transition cases — uncompressed at offset 0, compressed at
offset 0, compressed at offset 2, uncompressed at offset 2 (=
stitch latch) — and the stitch-resolution case driven from
'holdHi'. Together they cover every (wordOffset, holdHi, halfword
type) cell of the realigner's transition table.
-}
module IFetchSpec (tests) where

import Clash.Prelude (BitVector, (*), (+))
import Data.Bool (Bool (..))
import Data.Maybe (Maybe (..))
import Riski5.Core.IFetch (IFetchOut (..), realignerStep)
import Riski5.Encode (encode)
import Riski5.ISA
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, testCase)
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Core.IFetch.realignerStep"
    [ testCase "uncompressed at offset 0 emits full word, pops, advances PC by 4" case_uncomp0
    , testCase "compressed at offset 0 expands, doesn't pop, advances PC by 2" case_comp0
    , testCase "compressed at offset 2 expands, pops, advances PC by 2" case_comp2
    , testCase "uncompressed at offset 2 latches hi, bubble emit, pops" case_uncomp2Latch
    , testCase "stitch resolution: lo of new word + held hi → 32-bit emit" case_stitch
    , testCase "wordOffset transitions correctly for compressed pair in one word" case_compressedPair
    ]

-- | An uncompressed NOP (`addi x0, x0, 0`).
nopWord :: BitVector 32
nopWord = encode (Addi x0 x0 0)

-- | A compressed C.NOP (`addi x0, x0, 0` in 16 bits) — 0x0001.
cnopHalf :: BitVector 16
cnopHalf = 0x0001

-- | A compressed C.LI x10, 5 — 0x4515. Just for variety so the
-- expansion is distinguishable from C.NOP.
cliX10_5Half :: BitVector 16
cliX10_5Half = 0x4515

-- | Build a 32-bit word with a C.NOP at offset 0 and another C.NOP
-- at offset 2 (two compressed instructions in one fetch).
twoCompWord :: BitVector 32
twoCompWord =
  -- Bits [31:16] = hi half (offset 2), [15:0] = lo half (offset 0).
  -- Combine as `cnopHalf` + `cliX10_5Half`.
  let hi :: BitVector 32 = P.fromIntegral cliX10_5Half
      lo :: BitVector 32 = P.fromIntegral cnopHalf
   in (hi `shiftLBy16`) P.+ lo
 where
  shiftLBy16 :: BitVector 32 -> BitVector 32
  shiftLBy16 x = x * 0x1_0000

-- | Build a 32-bit word with C.NOP at offset 0 and a HALF of an
-- uncompressed instruction at offset 2 (just so the [1:0] = 11
-- check fires).
mixedWord :: BitVector 32
mixedWord =
  -- Hi half = 0xFF_FF (any halfword with [1:0]=11), Lo half = cnopHalf.
  let hi :: BitVector 32 = 0xFFFF_0000
      lo :: BitVector 32 = P.fromIntegral cnopHalf
   in hi P.+ lo

-- * Cases ---------------------------------------------------------

case_uncomp0 :: Assertion
case_uncomp0 = do
  let out = realignerStep False Nothing nopWord 0
  assertBool "valid" (ifoValid out)
  assertEqual "instr" nopWord (ifoInstr out)
  assertEqual "pc" 0 (ifoPc out)
  assertEqual "pcNext = pc + 4" 4 (ifoPcNext out)
  assertEqual "pop = True" True (ifoPop out)
  assertEqual "wordOffsetNext = False" False (ifoWordOffsetNext out)
  assertEqual "holdHiNext = Nothing" Nothing (ifoHoldHiNext out)

case_comp0 :: Assertion
case_comp0 = do
  -- C.NOP at offset 0: lo half = cnopHalf, [1:0] = 01 (not 11).
  let word = (0 :: BitVector 32) + P.fromIntegral cnopHalf
      out = realignerStep False Nothing word 0
  assertBool "valid" (ifoValid out)
  assertEqual "pc" 0 (ifoPc out)
  assertEqual "pcNext = pc + 2" 2 (ifoPcNext out)
  assertEqual "pop = False (don't advance to next word)" False (ifoPop out)
  assertEqual "wordOffsetNext = True" True (ifoWordOffsetNext out)

case_comp2 :: Assertion
case_comp2 = do
  -- Two compressed in one word; consume hi half. Word's hi half is
  -- compressed (its [1:0] /= 11).
  let out = realignerStep True Nothing twoCompWord 0
  assertBool "valid" (ifoValid out)
  assertEqual "pc = 2" 2 (ifoPc out)
  assertEqual "pcNext = 4" 4 (ifoPcNext out)
  assertEqual "pop = True (done with word)" True (ifoPop out)
  assertEqual "wordOffsetNext = False" False (ifoWordOffsetNext out)

case_uncomp2Latch :: Assertion
case_uncomp2Latch = do
  -- Word's hi half = 0xFFFF, [1:0] = 11 (uncompressed). So at offset
  -- 2 we latch + bubble.
  let out = realignerStep True Nothing mixedWord 0
  assertBool "valid = False (bubble)" (P.not (ifoValid out))
  assertEqual "pop = True (done with this word)" True (ifoPop out)
  assertEqual "holdHiNext set" (Just (0xFFFF, 2)) (ifoHoldHiNext out)
  assertEqual "wordOffsetNext = False" False (ifoWordOffsetNext out)

case_stitch :: Assertion
case_stitch = do
  -- Held hi = 0xFFFF (high half of the misaligned uncompressed),
  -- held PC = 2. New word has lo half = 0xAAAA (low half of the
  -- uncompressed). Stitch: 32-bit instr = 0xAAAA_FFFF.
  let newWord = 0x0000_AAAA :: BitVector 32
      out = realignerStep True (Just (0xFFFF, 2)) newWord 4
  assertBool "valid" (ifoValid out)
  assertEqual "stitched 32-bit instr" 0xAAAA_FFFF (ifoInstr out)
  assertEqual "pc = held start" 2 (ifoPc out)
  assertEqual "pcNext = held start + 4" 6 (ifoPcNext out)
  assertEqual "pop = False (still using new word at offset 2)" False (ifoPop out)
  assertEqual "wordOffsetNext = True" True (ifoWordOffsetNext out)
  assertEqual "holdHiNext cleared" Nothing (ifoHoldHiNext out)

case_compressedPair :: Assertion
case_compressedPair = do
  -- Walk through two compressed in one word: emit lo, then hi.
  let out0 = realignerStep False Nothing twoCompWord 0
  assertBool "lo emit valid" (ifoValid out0)
  assertEqual "lo pc = 0" 0 (ifoPc out0)
  assertEqual "lo pop = False" False (ifoPop out0)
  assertEqual "wordOffsetNext = True after lo" True (ifoWordOffsetNext out0)

  -- Step 2: state advances per out0; same FIFO head.
  let out1 =
        realignerStep
          (ifoWordOffsetNext out0)
          (ifoHoldHiNext out0)
          twoCompWord
          0
  assertBool "hi emit valid" (ifoValid out1)
  assertEqual "hi pc = 2" 2 (ifoPc out1)
  assertEqual "hi pop = True" True (ifoPop out1)
  assertEqual "wordOffsetNext = False after hi" False (ifoWordOffsetNext out1)
