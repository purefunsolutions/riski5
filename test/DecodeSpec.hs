-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : DecodeSpec
Description : @decode . encode = Just@ round-trip property tests.

Hedgehog drives every 'Instr' constructor through a randomly-generated
instance of its fields, encodes the result to a 32-bit word, decodes
back, and checks that the decoded instruction equals the original.
This is the tightest guarantee we can make that the core's hardware
decoder and the firmware assembler agree on bit layouts: they both
call 'Riski5.Decode.decode' and 'Riski5.Encode.encode' respectively
via this same type-level ISA.
-}
module DecodeSpec (
  tests,
) where

import Clash.Prelude (BitVector, Signed)
import Hedgehog (Gen, Property, forAll, property, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Riski5.Decode (decode)
import Riski5.Encode (encode)
import Riski5.ISA
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

tests :: TestTree
tests =
  testGroup
    "Riski5.Decode"
    [ testProperty "decode . encode = Just  (RV32I + Zicsr + M-mode)" prop_roundtrip
    , testProperty "decode rejects words with opcode[1:0] /= 11" prop_rejectsCompressed
    ]

-- | For every generated 'Instr', @decode (encode i) = Just i@.
prop_roundtrip :: Property
prop_roundtrip = property $ do
  i <- forAll genInstr
  decode (encode i) === Just i

{- | All valid uncompressed RV32I instructions have @opcode[1:0] = 11@.
The RVC (compressed) extension uses @00@, @01@, and @10@ — we do not
support it, so such words must decode to 'Nothing'.
-}
prop_rejectsCompressed :: Property
prop_rejectsCompressed = property $ do
  top <- forAll (Gen.integral (Range.constant 0 ((2 :: Integer) ^ (30 :: Int) - 1)))
  lo <- forAll (Gen.element [0 :: Integer, 1, 2])
  let w :: BitVector 32
      w = fromInteger (top * 4 + lo)
  decode w === Nothing

--------------------------------------------------------------------------
-- Generators
--------------------------------------------------------------------------

genReg :: Gen Reg
genReg = Reg <$> genBv5

genCsr :: Gen Csr
genCsr =
  Gen.element
    [ csrMstatus
    , csrMisa
    , csrMie
    , csrMtvec
    , csrMscratch
    , csrMepc
    , csrMcause
    , csrMtval
    , csrMip
    , csrMhartid
    , csrMcycle
    , csrMinstret
    , csrMcycleh
    , csrMinstreth
    ]

genBv5 :: Gen (BitVector 5)
genBv5 = fromInteger <$> Gen.integral (Range.constant 0 31)

genBv4 :: Gen (BitVector 4)
genBv4 = fromInteger <$> Gen.integral (Range.constant 0 15)

genBv20 :: Gen (BitVector 20)
genBv20 = fromInteger <$> Gen.integral (Range.constant 0 ((2 ^ (20 :: Int)) - 1))

genImm12 :: Gen (Signed 12)
genImm12 = fromInteger <$> Gen.integral (Range.constantFrom 0 (-2048) 2047)

{- | B-type offsets are always even (LSB implicit zero). Generate from
the 12-bit field then shift left by one to reconstruct the 13-bit
signed offset.
-}
genImm13Even :: Gen (Signed 13)
genImm13Even = do
  n <- Gen.integral (Range.constantFrom 0 (-2048) 2047)
  pure (fromInteger (n * 2))

{- | J-type offsets are always even. 20-bit field shifted left by one
yields a 21-bit signed offset.
-}
genImm21Even :: Gen (Signed 21)
genImm21Even = do
  n <- Gen.integral (Range.constantFrom 0 (-524288) 524287)
  pure (fromInteger (n * 2))

genInstr :: Gen Instr
genInstr =
  Gen.choice
    [ Lui <$> genReg <*> genBv20
    , Auipc <$> genReg <*> genBv20
    , Jal <$> genReg <*> genImm21Even
    , Jalr <$> genReg <*> genReg <*> genImm12
    , Lb <$> genReg <*> genReg <*> genImm12
    , Lh <$> genReg <*> genReg <*> genImm12
    , Lw <$> genReg <*> genReg <*> genImm12
    , Lbu <$> genReg <*> genReg <*> genImm12
    , Lhu <$> genReg <*> genReg <*> genImm12
    , Addi <$> genReg <*> genReg <*> genImm12
    , Slti <$> genReg <*> genReg <*> genImm12
    , Sltiu <$> genReg <*> genReg <*> genImm12
    , Xori <$> genReg <*> genReg <*> genImm12
    , Ori <$> genReg <*> genReg <*> genImm12
    , Andi <$> genReg <*> genReg <*> genImm12
    , Slli <$> genReg <*> genReg <*> genBv5
    , Srli <$> genReg <*> genReg <*> genBv5
    , Srai <$> genReg <*> genReg <*> genBv5
    , Sb <$> genReg <*> genReg <*> genImm12
    , Sh <$> genReg <*> genReg <*> genImm12
    , Sw <$> genReg <*> genReg <*> genImm12
    , Beq <$> genReg <*> genReg <*> genImm13Even
    , Bne <$> genReg <*> genReg <*> genImm13Even
    , Blt <$> genReg <*> genReg <*> genImm13Even
    , Bge <$> genReg <*> genReg <*> genImm13Even
    , Bltu <$> genReg <*> genReg <*> genImm13Even
    , Bgeu <$> genReg <*> genReg <*> genImm13Even
    , Add <$> genReg <*> genReg <*> genReg
    , Sub <$> genReg <*> genReg <*> genReg
    , Sll <$> genReg <*> genReg <*> genReg
    , Slt <$> genReg <*> genReg <*> genReg
    , Sltu <$> genReg <*> genReg <*> genReg
    , Xor <$> genReg <*> genReg <*> genReg
    , Srl <$> genReg <*> genReg <*> genReg
    , Sra <$> genReg <*> genReg <*> genReg
    , Or <$> genReg <*> genReg <*> genReg
    , And <$> genReg <*> genReg <*> genReg
    , Mul <$> genReg <*> genReg <*> genReg
    , MulH <$> genReg <*> genReg <*> genReg
    , MulHsu <$> genReg <*> genReg <*> genReg
    , MulHu <$> genReg <*> genReg <*> genReg
    , Div <$> genReg <*> genReg <*> genReg
    , DivU <$> genReg <*> genReg <*> genReg
    , Rem <$> genReg <*> genReg <*> genReg
    , RemU <$> genReg <*> genReg <*> genReg
    , Fence <$> genBv4 <*> genBv4
    , pure FenceI
    , pure Ecall
    , pure Ebreak
    , pure Mret
    , Csrrw <$> genReg <*> genReg <*> genCsr
    , Csrrs <$> genReg <*> genReg <*> genCsr
    , Csrrc <$> genReg <*> genReg <*> genCsr
    , Csrrwi <$> genReg <*> genBv5 <*> genCsr
    , Csrrsi <$> genReg <*> genBv5 <*> genCsr
    , Csrrci <$> genReg <*> genBv5 <*> genCsr
    ]
