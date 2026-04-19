-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : AluSpec
Description : Diff the Clash ALU against a Haskell-native reference.

For each 'AluOp' and each 'BranchOp', Hedgehog generates random
32-bit operand pairs (with biased boundary values — zero, one,
signed/unsigned min/max, alternating patterns) and asserts that
'Riski5.ALU.alu' and 'Riski5.ALU.branchTaken' agree with a plain
Haskell reference that uses @Int32@ / @Word32@ arithmetic
directly.

Two levels of check are useful: these point-wise ALU properties
catch bugs in the combinational logic without building a whole
core, and the existing 'Riski5.Reference' executor already
exercises the same operations at a higher level as part of
running real instructions. Both layers keep passing means the
ALU unit and the reference executor agree on every op across
1000 random inputs per op.
-}
module AluSpec (
  tests,
) where

import Clash.Prelude (BitVector, Signed, Unsigned, pack, unpack)
import Data.Bits (
  shiftL,
  shiftR,
  xor,
  (.&.),
  (.|.),
 )
import Data.Int (Int32)
import Data.Word (Word32)
import Hedgehog (Gen, Property, forAll, property, withTests, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Riski5.ALU (
  AluOp (..),
  BranchOp (..),
  alu,
  branchTaken,
 )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

tests :: TestTree
tests =
  testGroup
    "Riski5.ALU"
    [ testProperty "alu AluAdd matches Word32 +" (prop_aluBinary AluAdd (+))
    , testProperty "alu AluSub matches Word32 -" (prop_aluBinary AluSub (-))
    , testProperty "alu AluXor matches Word32 xor" (prop_aluBinary AluXor xor)
    , testProperty "alu AluOr matches Word32 .|." (prop_aluBinary AluOr (.|.))
    , testProperty "alu AluAnd matches Word32 .&." (prop_aluBinary AluAnd (.&.))
    , testProperty "alu AluSll matches logical shift-left (5-bit shamt)" prop_sll
    , testProperty "alu AluSrl matches logical shift-right (5-bit shamt)" prop_srl
    , testProperty "alu AluSra matches arithmetic shift-right (5-bit shamt)" prop_sra
    , testProperty "alu AluSlt matches signed <" prop_slt
    , testProperty "alu AluSltu matches unsigned <" prop_sltu
    , testProperty "branchTaken BrEq matches ==" (prop_branch BrEq (==))
    , testProperty "branchTaken BrNe matches /=" (prop_branch BrNe (/=))
    , testProperty "branchTaken BrLt matches signed <" (prop_branchSigned BrLt (<))
    , testProperty "branchTaken BrGe matches signed >=" (prop_branchSigned BrGe (>=))
    , testProperty "branchTaken BrLtu matches unsigned <" (prop_branch BrLtu (<))
    , testProperty "branchTaken BrGeu matches unsigned >=" (prop_branch BrGeu (>=))
    ]

-- * Generators -------------------------------------------------------

{- | Uniform over all 32-bit values with extra weight on boundary
cases that historically catch bugs.
-}
genWord32 :: Gen Word32
genWord32 =
  Gen.frequency
    [ (1, pure 0)
    , (1, pure 1)
    , (1, pure 0xFFFFFFFF)
    , (1, pure 0x80000000) -- signed min
    , (1, pure 0x7FFFFFFF) -- signed max
    , (1, pure 0xAAAAAAAA)
    , (1, pure 0x55555555)
    , (4, Gen.integral (Range.linear 0 0xFFFFFFFF))
    ]

-- | 5-bit shift amount.
genShamt :: Gen Word32
genShamt = Gen.integral (Range.constant 0 31)

asBV :: Word32 -> BitVector 32
asBV = pack . (unpack :: BitVector 32 -> BitVector 32) . fromIntegral

-- * ALU properties --------------------------------------------------

prop_aluBinary :: AluOp -> (Word32 -> Word32 -> Word32) -> Property
prop_aluBinary op ref = withTests 1000 . property $ do
  a <- forAll genWord32
  b <- forAll genWord32
  let got :: Word32
      got = wordOf (alu op (asBV a) (asBV b))
  got === ref a b

-- | Logical shift-left: treats @a@ as unsigned, shifts by @b[4:0]@.
prop_sll :: Property
prop_sll = withTests 1000 . property $ do
  a <- forAll genWord32
  b <- forAll genShamt
  let got :: Word32
      got = wordOf (alu AluSll (asBV a) (asBV b))
  got === (a `shiftL` fromIntegral b)

prop_srl :: Property
prop_srl = withTests 1000 . property $ do
  a <- forAll genWord32
  b <- forAll genShamt
  let got :: Word32
      got = wordOf (alu AluSrl (asBV a) (asBV b))
  got === (a `shiftR` fromIntegral b)

-- | Arithmetic shift-right: preserves sign of @a@.
prop_sra :: Property
prop_sra = withTests 1000 . property $ do
  a <- forAll genWord32
  b <- forAll genShamt
  let got :: Word32
      got = wordOf (alu AluSra (asBV a) (asBV b))
      ref = fromIntegral @Int32 @Word32 (fromIntegral a `shiftR` fromIntegral b)
  got === ref

prop_slt :: Property
prop_slt = withTests 1000 . property $ do
  a <- forAll genWord32
  b <- forAll genWord32
  let got :: Word32
      got = wordOf (alu AluSlt (asBV a) (asBV b))
      ref = if (fromIntegral a :: Int32) < fromIntegral b then 1 else 0
  got === ref

prop_sltu :: Property
prop_sltu = withTests 1000 . property $ do
  a <- forAll genWord32
  b <- forAll genWord32
  let got :: Word32
      got = wordOf (alu AluSltu (asBV a) (asBV b))
      ref = if a < b then 1 else 0
  got === ref

-- * Branch properties ----------------------------------------------

prop_branch :: BranchOp -> (Word32 -> Word32 -> Bool) -> Property
prop_branch op ref = withTests 500 . property $ do
  a <- forAll genWord32
  b <- forAll genWord32
  branchTaken op (asBV a) (asBV b) === ref a b

prop_branchSigned :: BranchOp -> (Int32 -> Int32 -> Bool) -> Property
prop_branchSigned op ref = withTests 500 . property $ do
  a <- forAll genWord32
  b <- forAll genWord32
  branchTaken op (asBV a) (asBV b) === ref (fromIntegral a) (fromIntegral b)

-- * Helpers --------------------------------------------------------

{- | Treat a 32-bit BitVector as a Word32 (round-trip through the
Unsigned 32 representation).
-}
wordOf :: BitVector 32 -> Word32
wordOf bv = fromIntegral (unpack bv :: Unsigned 32)
