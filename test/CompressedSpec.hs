-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : CompressedSpec
Description : Golden-table + round-trip checks for 'Riski5.Compressed.expandCompressed'.

The expander has to match the spec exactly — every legal
RV32C bit pattern maps to one specific 32-bit equivalent, and a
single bit-twiddle off (wrong immediate slot, wrong sign extension,
wrong register field permutation) silently breaks every program
the IF realigner feeds through it. Two complementary tests:

  1. __Golden table__ — hand-built compressed encodings whose
     expected expansion is also hand-built directly via
     'Riski5.Encode'. Catches bit-permutation typos in the
     expander's immediate-reassembly logic.
  2. __Round-trip property__ — a generator for every C-instruction
     family that picks well-formed (rd, rs1, rs2, imm) tuples,
     packs them into a 16-bit RVC encoding, and asserts the
     expander's output decodes back into the canonical 'Instr'
     it should have. Bridges the spec's "mapping" view (each
     compressed maps to a 32-bit equivalent) and the project's
     'Instr' algebra.

Reserved-encoding cases (C.ADDI4SPN nzuimm = 0, C.SRLI/SRAI/SLLI
shamt[5] = 1 on RV32, RV64-only forms) get their own focused
unit tests.
-}
module CompressedSpec (tests) where

import Clash.Prelude (BitVector, Signed, pack, resize, slice, unpack, zeroExtend, (++#), d0, d1, d2, d4, d5)
import Hedgehog (Gen, Property, forAll, property, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Riski5.Compressed (expandCompressed, isCompressedHalf)
import Riski5.Decode (decode)
import Riski5.Encode (encode)
import Riski5.ISA
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)
import Test.Tasty.Hedgehog (testProperty)
import Prelude

tests :: TestTree
tests =
  testGroup
    "Riski5.Compressed"
    [ testGroup
        "spot checks (golden table)"
        [ case_cnop
        , case_caddi
        , case_cli
        , case_clui
        , case_caddi16sp
        , case_caddi4spn
        , case_clw
        , case_csw
        , case_clwsp
        , case_cswsp
        , case_cmv
        , case_cadd
        , case_cjr
        , case_cjalr
        , case_cebreak
        , case_cj
        , case_cjal
        , case_cbeqz
        , case_cbnez
        , case_csub
        , case_cxor
        , case_cor
        , case_cand
        , case_candi
        , case_cslli
        , case_csrli
        , case_csrai
        ]
    , testGroup
        "reserved / illegal"
        [ case_caddi4spn_zero_reserved
        , case_clui_zero_reserved
        , case_caddi16sp_zero_reserved
        , case_clwsp_x0_reserved
        , case_cslli_rv64_reserved
        , case_csrli_rv64_reserved
        , case_csrai_rv64_reserved
        , case_cjr_x0_reserved
        ]
    , testGroup
        "is-compressed predicate"
        [ testProperty "isCompressedHalf w  ==  (w[1:0] /= 0b11)" prop_isCompressed
        ]
    , testGroup
        "expand → decode round-trip"
        [ testProperty "C.ADDI" (propRoundTrip genCAddi)
        , testProperty "C.LI" (propRoundTrip genCLi)
        , testProperty "C.LUI" (propRoundTrip genCLui)
        , testProperty "C.ADDI16SP" (propRoundTrip genCAddi16sp)
        , testProperty "C.ADDI4SPN" (propRoundTrip genCAddi4spn)
        , testProperty "C.LW" (propRoundTrip genCLw)
        , testProperty "C.SW" (propRoundTrip genCSw)
        , testProperty "C.LWSP" (propRoundTrip genCLwsp)
        , testProperty "C.SWSP" (propRoundTrip genCSwsp)
        , testProperty "C.J / C.JAL" (propRoundTrip genCJalLike)
        , testProperty "C.BEQZ / C.BNEZ" (propRoundTrip genCBranch)
        , testProperty "C.MV / C.ADD" (propRoundTrip genCMvAdd)
        , testProperty "C.JR / C.JALR" (propRoundTrip genCJrJalr)
        , testProperty "C.SUB/XOR/OR/AND" (propRoundTrip genCRegAlu)
        , testProperty "C.SLLI / C.SRLI / C.SRAI" (propRoundTrip genCShift)
        , testProperty "C.ANDI" (propRoundTrip genCAndi)
        ]
    ]

--------------------------------------------------------------------------
-- Spot checks
--------------------------------------------------------------------------

-- | Build a 16-bit RVC word and assert it expands to the same 32-bit
-- machine word that 'encode' would produce for the named 'Instr'.
golden :: String -> BitVector 16 -> Instr -> TestTree
golden name w expected =
  testCase name $
    assertEqual name (Just (encode expected)) (expandCompressed w)

-- | Same but expects 'Nothing' (reserved encoding).
reserved :: String -> BitVector 16 -> TestTree
reserved name w =
  testCase name $
    assertEqual name Nothing (expandCompressed w)

-- C.NOP — addi x0, x0, 0 — encoding 0x0001 (op=01, funct3=000, all imm=0)
case_cnop :: TestTree
case_cnop = golden "C.NOP" 0x0001 (Addi x0 x0 0)

-- C.ADDI x9, 5: rd=9 (x9), imm=5
-- op=01, funct3=000, rd=01001, imm[5]=0, imm[4:0]=00101
-- bits: [15:13]=000, [12]=0, [11:7]=01001, [6:2]=00101, [1:0]=01
-- = 0000_0_01001_00101_01 = 0b0000010010010101 = 0x0495
case_caddi :: TestTree
case_caddi = golden "C.ADDI x9, 5" 0x0495 (Addi x9 x9 5)

-- C.LI x10, -3: rd=10, imm=-3 (6-bit signed = 0b111101)
-- imm[5]=1, imm[4:0]=11101
-- op=01, funct3=010, rd=01010
-- bits: [15:13]=010, [12]=1, [11:7]=01010, [6:2]=11101, [1:0]=01
-- = 010_1_01010_11101_01 = 0b0101010101110101 = 0x5575
case_cli :: TestTree
case_cli = golden "C.LI x10, -3" 0x5575 (Addi x10 x0 (-3))

-- C.LUI x5, 1 — imm[17:12]=000001, sign-ext to 20-bit imm=0x00001
-- op=01, funct3=011, rd=00101, imm[17]=0, imm[16:12]=00001
-- bits: [15:13]=011, [12]=0, [11:7]=00101, [6:2]=00001, [1:0]=01
-- = 011_0_00101_00001_01 = 0b0110_0010_1000_0101 = 0x6285
case_clui :: TestTree
case_clui = golden "C.LUI x5, 1" 0x6285 (Lui x5 0x00001)

-- C.ADDI16SP x2, 16: imm=16 (10-bit signed)
-- imm[9]=0, imm[8:7]=00, imm[6]=0, imm[5]=0, imm[4]=1
-- bits: [15:13]=011, [12]=imm[9]=0, [11:7]=00010 (rd=x2),
--       [6]=imm[4]=1, [5]=imm[6]=0, [4:3]=imm[8:7]=00, [2]=imm[5]=0
-- = 011_0_00010_1_0_00_0_01
-- = 0110 0001 0100 0001 = 0x6141
case_caddi16sp :: TestTree
case_caddi16sp = golden "C.ADDI16SP x2, 16" 0x6141 (Addi x2 x2 16)

-- C.ADDI4SPN x8, 4: rd'=000 (x8), nzuimm=4
-- nzuimm[9:6]=0, [5:4]=0, [3]=0, [2]=1
-- bits: [15:13]=000, [12:11]=00, [10:7]=0000, [6]=imm[2]=1,
--       [5]=imm[3]=0, [4:2]=000 (rd'), [1:0]=00
-- = 0000_0_0000_1_0_000_00 = 0b0000000001000000 = 0x0040
case_caddi4spn :: TestTree
case_caddi4spn = golden "C.ADDI4SPN x8, 4" 0x0040 (Addi x8 x2 4)

-- C.LW x9, 4(x10): rd'=001 (x9), rs1'=010 (x10), uimm=4
-- imm[5:3]=000, imm[2]=1, imm[6]=0
-- bits: [15:13]=010, [12:10]=000, [9:7]=010 (rs1'), [6]=imm[2]=1,
--       [5]=imm[6]=0, [4:2]=001 (rd'), [1:0]=00
-- = 010_000_010_1_0_001_00 = 0b0100000101000100 = 0x4144
case_clw :: TestTree
case_clw = golden "C.LW x9, 4(x10)" 0x4144 (Lw x9 x10 4)

-- C.SW x9, 4(x10): rs1'=010 (x10), rs2'=001 (x9), uimm=4
-- bits: [15:13]=110, [12:10]=000, [9:7]=010, [6]=1, [5]=0, [4:2]=001, [1:0]=00
-- = 110_000_010_1_0_001_00 = 0b1100000101000100 = 0xC144
case_csw :: TestTree
case_csw = golden "C.SW x9, 4(x10)" 0xC144 (Sw x10 x9 4)

-- C.LWSP x5, 4(x2): rd=5, uimm=4 (8-bit, byte-aligned-to-4)
-- imm[7:6]=00, imm[5]=0, imm[4:2]=001, imm[1:0]=00
-- bits: [15:13]=010, [12]=imm[5]=0, [11:7]=00101 (rd), [6:4]=imm[4:2]=001,
--       [3:2]=imm[7:6]=00, [1:0]=10
-- = 010_0_00101_001_00_10 = 0b0100_0010_1001_0010 = 0x4292
case_clwsp :: TestTree
case_clwsp = golden "C.LWSP x5, 4(x2)" 0x4292 (Lw x5 x2 4)

-- C.SWSP x5, 4(x2): rs2=5, uimm=4
-- imm[5:2]=0001, imm[7:6]=00
-- bits: [15:13]=110, [12:9]=imm[5:2]=0001, [8:7]=imm[7:6]=00,
--       [6:2]=00101 (rs2), [1:0]=10
-- = 110_0001_00_00101_10 = 0xC216
case_cswsp :: TestTree
case_cswsp = golden "C.SWSP x5, 4(x2)" 0xC216 (Sw x2 x5 4)

-- C.MV x10, x11: rd=10, rs2=11
-- bit12=0, [11:7]=01010, [6:2]=01011, [1:0]=10, funct3=100
-- = 100_0_01010_01011_10 = 0x852E
case_cmv :: TestTree
case_cmv = golden "C.MV x10, x11" 0x852E (Add x10 x0 x11)

-- C.ADD x10, x11: rd=10, rs2=11
-- bit12=1, [11:7]=01010, [6:2]=01011, [1:0]=10, funct3=100
-- = 100_1_01010_01011_10 = 0x952E
case_cadd :: TestTree
case_cadd = golden "C.ADD x10, x11" 0x952E (Add x10 x10 x11)

-- C.JR x5: rs1=5, rs2=0, bit12=0
-- = 100_0_00101_00000_10 = 0x8282
case_cjr :: TestTree
case_cjr = golden "C.JR x5" 0x8282 (Jalr x0 x5 0)

-- C.JALR x5: rs1=5, rs2=0, bit12=1
-- = 100_1_00101_00000_10 = 0x9282
case_cjalr :: TestTree
case_cjalr = golden "C.JALR x5" 0x9282 (Jalr x1 x5 0)

-- C.EBREAK: bit12=1, rs2=0, rd=0
-- = 100_1_00000_00000_10 = 0x9002
case_cebreak :: TestTree
case_cebreak = golden "C.EBREAK" 0x9002 Ebreak

-- C.J 0: imm=0
-- bits: [15:13]=101, [12]=imm[11]=0, [11]=imm[4]=0, [10:9]=imm[9:8]=0,
--       [8]=imm[10]=0, [7]=imm[6]=0, [6]=imm[7]=0, [5:3]=imm[3:1]=0,
--       [2]=imm[5]=0, [1:0]=01
-- = 101_0_0_00_0_0_0_000_0_01 = 0xA001
case_cj :: TestTree
case_cj = golden "C.J 0" 0xA001 (Jal x0 0)

-- C.JAL 4: imm=4 (so imm[2]=1, others zero)
-- imm[2]=1 means we set position [5] in the encoded bit vector? Wait let me retrace:
-- Per spec (and C.J/C.JAL imm encoding):
-- imm[5] is at bit[2] of encoded, imm[4] at bit[11], imm[3:1] at bits[5:3].
-- For imm=4 (binary 00000_000100), imm[2]=1, all others 0.
-- imm[2] is at bits[5:3] (imm[3:1])... no wait. imm[3:1] live at bits[5:3]. imm[2] is the middle bit of imm[3:1].
-- bit[4] of bits[5:3] = imm[2].
-- bits: [15:13]=001, [12]=imm[11]=0, [11]=imm[4]=0, [10:9]=0, [8]=0,
--       [7]=imm[6]=0, [6]=imm[7]=0, [5:3]=imm[3:1]=010, [2]=imm[5]=0, [1:0]=01
-- = 001_0_0_00_0_0_0_010_0_01 = 0x2011
case_cjal :: TestTree
case_cjal = golden "C.JAL 4" 0x2011 (Jal x1 4)

-- C.BEQZ x9, 4: rs1'=001 (x9), imm=4
-- imm[8]=0, imm[7:6]=00, imm[5]=0, imm[4:3]=00, imm[2:1]=10
-- bits: [15:13]=110, [12]=imm[8]=0, [11:10]=imm[4:3]=00, [9:7]=rs1'=001,
--       [6:5]=imm[7:6]=00, [4:3]=imm[2:1]=10, [2]=imm[5]=0, [1:0]=01
-- = 110_0_00_001_00_10_0_01 = 0b1100_0000_1001_0001 = 0xC091
case_cbeqz :: TestTree
case_cbeqz = golden "C.BEQZ x9, 4" 0xC091 (Beq x9 x0 4)

-- C.BNEZ x9, 4: same as BEQZ but funct3=111
-- = 111_0_00_001_00_10_0_01 = 0xE091
case_cbnez :: TestTree
case_cbnez = golden "C.BNEZ x9, 4" 0xE091 (Bne x9 x0 4)

-- C.SUB x8, x9: rd'=000 (x8), rs2'=001 (x9)
-- funct3=100, [12]=0, [11:10]=11, [9:7]=000 (rd'), [6:5]=00, [4:2]=001, [1:0]=01
-- = 100_0_11_000_00_001_01 = 0x8C05
case_csub :: TestTree
case_csub = golden "C.SUB x8, x9" 0x8C05 (Sub x8 x8 x9)

-- C.XOR x8, x9: [6:5]=01
-- = 100_0_11_000_01_001_01 = 0x8C25
case_cxor :: TestTree
case_cxor = golden "C.XOR x8, x9" 0x8C25 (Xor x8 x8 x9)

-- C.OR x8, x9: [6:5]=10
-- = 100_0_11_000_10_001_01 = 0x8C45
case_cor :: TestTree
case_cor = golden "C.OR x8, x9" 0x8C45 (Or x8 x8 x9)

-- C.AND x8, x9: [6:5]=11
-- = 100_0_11_000_11_001_01 = 0x8C65
case_cand :: TestTree
case_cand = golden "C.AND x8, x9" 0x8C65 (And x8 x8 x9)

-- C.ANDI x8, -1: rd'=000, imm=-1 (6-bit = 0b111111)
-- funct3=100, [11:10]=10, imm[5]=bit12=1, imm[4:0]=bits[6:2]=11111
-- = 100_1_10_000_11111_01 = 0x987D
case_candi :: TestTree
case_candi = golden "C.ANDI x8, -1" 0x987D (Andi x8 x8 (-1))

-- C.SLLI x5, 4: rd=5, shamt=4 (RV32: shamt[5] must be 0)
-- funct3=000, [12]=0, [11:7]=00101, [6:2]=00100, [1:0]=10
-- = 000_0_00101_00100_10 = 0x0292
case_cslli :: TestTree
case_cslli = golden "C.SLLI x5, 4" 0x0292 (Slli x5 x5 4)

-- C.SRLI x8, 4: rd'=000 (x8), shamt=4
-- funct3=100, [11:10]=00, [12]=shamt[5]=0, [9:7]=000 (rd'), [6:2]=00100, [1:0]=01
-- = 100_0_00_000_00100_01 = 0x8011
case_csrli :: TestTree
case_csrli = golden "C.SRLI x8, 4" 0x8011 (Srli x8 x8 4)

-- C.SRAI x8, 4: same but [11:10]=01
-- = 100_0_01_000_00100_01 = 0x8411
case_csrai :: TestTree
case_csrai = golden "C.SRAI x8, 4" 0x8411 (Srai x8 x8 4)

--------------------------------------------------------------------------
-- Reserved
--------------------------------------------------------------------------

-- C.ADDI4SPN with nzuimm = 0 is reserved (it would alias C.ILLEGAL).
case_caddi4spn_zero_reserved :: TestTree
case_caddi4spn_zero_reserved = reserved "C.ADDI4SPN nzuimm=0" 0x0000

-- C.LUI rd!=x0,x2 with nzimm = 0 is reserved.
-- bits: [15:13]=011, [12]=0, [11:7]=00101 (rd=x5), [6:2]=00000, [1:0]=01
-- = 011_0_00101_00000_01 = 0x6281
case_clui_zero_reserved :: TestTree
case_clui_zero_reserved = reserved "C.LUI x5 nzimm=0" 0x6281

-- C.ADDI16SP rd=x2 with nzimm = 0 is reserved.
-- bits: [15:13]=011, [12]=0, [11:7]=00010 (x2), [6:2]=00000, [1:0]=01
-- = 011_0_00010_00000_01 = 0x6101
case_caddi16sp_zero_reserved :: TestTree
case_caddi16sp_zero_reserved = reserved "C.ADDI16SP nzimm=0" 0x6101

-- C.LWSP rd=x0 is reserved.
-- bits: [15:13]=010, [12:7]=000000, [6:2]=00000, [1:0]=10
case_clwsp_x0_reserved :: TestTree
case_clwsp_x0_reserved = reserved "C.LWSP x0" 0x4002

-- C.SLLI shamt[5]=1 reserved on RV32.
-- bits: [15:13]=000, [12]=1, [11:7]=00101, [6:2]=00000, [1:0]=10
-- = 000_1_00101_00000_10 = 0x1282
case_cslli_rv64_reserved :: TestTree
case_cslli_rv64_reserved = reserved "C.SLLI shamt[5]=1" 0x1282

-- C.SRLI shamt[5]=1 reserved on RV32.
-- = 100_1_00_000_00000_01 = 0x9001
case_csrli_rv64_reserved :: TestTree
case_csrli_rv64_reserved = reserved "C.SRLI shamt[5]=1" 0x9001

-- C.SRAI shamt[5]=1 reserved on RV32.
-- = 100_1_01_000_00000_01 = 0x9401
case_csrai_rv64_reserved :: TestTree
case_csrai_rv64_reserved = reserved "C.SRAI shamt[5]=1" 0x9401

-- C.JR with rs1=0 is reserved.
-- = 100_0_00000_00000_10 = 0x8002
case_cjr_x0_reserved :: TestTree
case_cjr_x0_reserved = reserved "C.JR x0" 0x8002

--------------------------------------------------------------------------
-- Round-trip property
--------------------------------------------------------------------------

-- | Each generator emits a tuple @(rvc, expected)@: a legal compressed
-- encoding plus the 'Instr' the expander should produce after a
-- @decode@ round-trip.
type CGen = Gen (BitVector 16, Instr)

propRoundTrip :: CGen -> Property
propRoundTrip gen = property $ do
  (rvc, expected) <- forAll gen
  case expandCompressed rvc of
    Nothing -> fail "expander returned Nothing on a generator-emitted legal C-instr"
    Just w32 -> decode w32 === Just expected

prop_isCompressed :: Property
prop_isCompressed = property $ do
  w <- forAll genBv16
  let lo = slice d1 d0 w :: BitVector 2
  isCompressedHalf w === (lo /= 0b11)

genBv16 :: Gen (BitVector 16)
genBv16 = fromInteger <$> Gen.integral (Range.constant 0 ((2 ^ (16 :: Int)) - 1))

-- ---------------------------------------------------------------------
-- C-instruction generators (well-formed encodings only)
-- ---------------------------------------------------------------------

genBv1 :: Gen (BitVector 1)
genBv1 = fromInteger <$> Gen.integral (Range.constant 0 1)

genBv2 :: Gen (BitVector 2)
genBv2 = fromInteger <$> Gen.integral (Range.constant 0 3)

genBv3 :: Gen (BitVector 3)
genBv3 = fromInteger <$> Gen.integral (Range.constant 0 7)

genBv4 :: Gen (BitVector 4)
genBv4 = fromInteger <$> Gen.integral (Range.constant 0 15)

genBv5 :: Gen (BitVector 5)
genBv5 = fromInteger <$> Gen.integral (Range.constant 0 31)

genBv6 :: Gen (BitVector 6)
genBv6 = fromInteger <$> Gen.integral (Range.constant 0 63)

-- 5-bit register, in [0,31] (any register).
genReg :: Gen Reg
genReg = Reg <$> genBv5

-- 5-bit register but excluding x0 (for slots where x0 is reserved).
genRegNonZero :: Gen Reg
genRegNonZero = Reg . fromInteger <$> Gen.integral (Range.constant 1 31)

-- 3-bit "compressed" register (x8..x15) directly as a Reg.
genRegP :: Gen Reg
genRegP = do
  b <- genBv3
  pure (Reg ((0b01 :: BitVector 2) ++# b))

-- C.ADDI generator: rd is any reg, imm 6-bit signed.
-- rd=x0 with imm=0 is C.NOP; rd=x0 with imm/=0 is HINT — both round-trip
-- through Addi x0 x0 imm. Generator just picks any.
genCAddi :: CGen
genCAddi = do
  rd <- genReg
  imm6 <- genBv6
  let imm12 :: Signed 12 = resize (unpack imm6 :: Signed 6)
      i5 :: BitVector 1 = slice d5 d5 imm6
      i4_0 :: BitVector 5 = slice d4 d0 imm6
      w =
        (0b000 :: BitVector 3)
          ++# i5
          ++# unReg rd
          ++# i4_0
          ++# (0b01 :: BitVector 2)
  pure (w, Addi rd rd imm12)

genCLi :: CGen
genCLi = do
  rd <- genReg
  imm6 <- genBv6
  let imm12 :: Signed 12 = resize (unpack imm6 :: Signed 6)
      i5 :: BitVector 1 = slice d5 d5 imm6
      i4_0 :: BitVector 5 = slice d4 d0 imm6
      w =
        (0b010 :: BitVector 3)
          ++# i5
          ++# unReg rd
          ++# i4_0
          ++# (0b01 :: BitVector 2)
  pure (w, Addi rd x0 imm12)

genCLui :: CGen
genCLui = do
  -- rd in {1, 3..31} (rd=0 is HINT, rd=2 is ADDI16SP)
  rd <-
    Reg . fromInteger
      <$> Gen.choice
        [ Gen.integral (Range.constant 3 31)
        , pure 1
        ]
  imm6 <- Gen.filter (/= 0) genBv6
  let imm20 :: BitVector 20 =
        pack (resize (unpack imm6 :: Signed 6) :: Signed 20)
      i17 :: BitVector 1 = slice d5 d5 imm6
      i16_12 :: BitVector 5 = slice d4 d0 imm6
      w =
        (0b011 :: BitVector 3)
          ++# i17
          ++# unReg rd
          ++# i16_12
          ++# (0b01 :: BitVector 2)
  pure (w, Lui rd imm20)

genCAddi16sp :: CGen
genCAddi16sp = do
  -- imm10 layout: [9 | 8:7 | 6 | 5 | 4 | 0:3=zero]
  i9 <- genBv1
  i8_7 <- genBv2
  i6 <- genBv1
  i5 <- genBv1
  i4 <- genBv1
  let imm10Bv :: BitVector 10 =
        i9 ++# i8_7 ++# i6 ++# i5 ++# i4 ++# (0 :: BitVector 4)
  if imm10Bv == 0
    then genCAddi16sp
    else do
      let imm12 :: Signed 12 = resize (unpack imm10Bv :: Signed 10)
          w =
            (0b011 :: BitVector 3)
              ++# i9
              ++# (0b00010 :: BitVector 5)
              ++# i4
              ++# i6
              ++# i8_7
              ++# i5
              ++# (0b01 :: BitVector 2)
      pure (w, Addi x2 x2 imm12)

genCAddi4spn :: CGen
genCAddi4spn = do
  rdP <- genRegP
  -- nzuimm10: [9:6 | 5:4 | 3 | 2 | 0:1=zero]
  i9_6 <- genBv4
  i5_4 <- genBv2
  i3 <- genBv1
  i2 <- genBv1
  let nzuimm :: BitVector 10 =
        i9_6 ++# i5_4 ++# i3 ++# i2 ++# (0 :: BitVector 2)
  if nzuimm == 0
    then genCAddi4spn
    else do
      let imm12 :: Signed 12 = unpack (zeroExtend nzuimm)
          rdLo :: BitVector 3 = slice d2 d0 (unReg rdP)
          w =
            (0b000 :: BitVector 3)
              ++# i5_4
              ++# i9_6
              ++# i2
              ++# i3
              ++# rdLo
              ++# (0b00 :: BitVector 2)
      pure (w, Addi rdP x2 imm12)

genCLw :: CGen
genCLw = do
  rdP <- genRegP
  rs1P <- genRegP
  i5_3 <- genBv3
  i2 <- genBv1
  i6 <- genBv1
  let uimm :: BitVector 7 = i6 ++# i5_3 ++# i2 ++# (0 :: BitVector 2)
      imm12 :: Signed 12 = unpack (zeroExtend uimm)
      rdLo :: BitVector 3 = slice d2 d0 (unReg rdP)
      rs1Lo :: BitVector 3 = slice d2 d0 (unReg rs1P)
      w =
        (0b010 :: BitVector 3)
          ++# i5_3
          ++# rs1Lo
          ++# i2
          ++# i6
          ++# rdLo
          ++# (0b00 :: BitVector 2)
  pure (w, Lw rdP rs1P imm12)

genCSw :: CGen
genCSw = do
  rs2P <- genRegP
  rs1P <- genRegP
  i5_3 <- genBv3
  i2 <- genBv1
  i6 <- genBv1
  let uimm :: BitVector 7 = i6 ++# i5_3 ++# i2 ++# (0 :: BitVector 2)
      imm12 :: Signed 12 = unpack (zeroExtend uimm)
      rs2Lo :: BitVector 3 = slice d2 d0 (unReg rs2P)
      rs1Lo :: BitVector 3 = slice d2 d0 (unReg rs1P)
      w =
        (0b110 :: BitVector 3)
          ++# i5_3
          ++# rs1Lo
          ++# i2
          ++# i6
          ++# rs2Lo
          ++# (0b00 :: BitVector 2)
  pure (w, Sw rs1P rs2P imm12)

genCLwsp :: CGen
genCLwsp = do
  rd <- genRegNonZero
  -- uimm8: [7:6 | 5 | 4:2 | 0:1=zero]
  i5 <- genBv1
  i4_2 <- genBv3
  i7_6 <- genBv2
  let uimm :: BitVector 8 = i7_6 ++# i5 ++# i4_2 ++# (0 :: BitVector 2)
      imm12 :: Signed 12 = unpack (zeroExtend uimm)
      w =
        (0b010 :: BitVector 3)
          ++# i5
          ++# unReg rd
          ++# i4_2
          ++# i7_6
          ++# (0b10 :: BitVector 2)
  pure (w, Lw rd x2 imm12)

genCSwsp :: CGen
genCSwsp = do
  rs2 <- genReg
  i5_2 <- genBv4
  i7_6 <- genBv2
  let uimm :: BitVector 8 = i7_6 ++# i5_2 ++# (0 :: BitVector 2)
      imm12 :: Signed 12 = unpack (zeroExtend uimm)
      w =
        (0b110 :: BitVector 3)
          ++# i5_2
          ++# i7_6
          ++# unReg rs2
          ++# (0b10 :: BitVector 2)
  pure (w, Sw x2 rs2 imm12)

-- C.J / C.JAL share the imm encoding; we generate one or the other
-- per call.
genCJalLike :: CGen
genCJalLike = do
  isJal <- Gen.bool
  i11 <- genBv1
  i10 <- genBv1
  i9_8 <- genBv2
  i7 <- genBv1
  i6 <- genBv1
  i5 <- genBv1
  i4 <- genBv1
  i3_1 <- genBv3
  let imm12Bv :: BitVector 12 =
        i11
          ++# i10
          ++# i9_8
          ++# i7
          ++# i6
          ++# i5
          ++# i4
          ++# i3_1
          ++# (0 :: BitVector 1)
      imm21 :: Signed 21 = resize (unpack imm12Bv :: Signed 12)
      funct3 :: BitVector 3 = if isJal then 0b001 else 0b101
      rd = if isJal then x1 else x0
      w =
        funct3
          ++# i11
          ++# i4
          ++# i9_8
          ++# i10
          ++# i6
          ++# i7
          ++# i3_1
          ++# i5
          ++# (0b01 :: BitVector 2)
  pure (w, Jal rd imm21)

genCBranch :: CGen
genCBranch = do
  isBnez <- Gen.bool
  rs1P <- genRegP
  i8 <- genBv1
  i7_6 <- genBv2
  i5 <- genBv1
  i4_3 <- genBv2
  i2_1 <- genBv2
  let imm9Bv :: BitVector 9 =
        i8
          ++# i7_6
          ++# i5
          ++# i4_3
          ++# i2_1
          ++# (0 :: BitVector 1)
      imm13 :: Signed 13 = resize (unpack imm9Bv :: Signed 9)
      funct3 :: BitVector 3 = if isBnez then 0b111 else 0b110
      rs1Lo :: BitVector 3 = slice d2 d0 (unReg rs1P)
      ctor = if isBnez then Bne else Beq
      w =
        funct3
          ++# i8
          ++# i4_3
          ++# rs1Lo
          ++# i7_6
          ++# i2_1
          ++# i5
          ++# (0b01 :: BitVector 2)
  pure (w, ctor rs1P x0 imm13)

genCMvAdd :: CGen
genCMvAdd = do
  isAdd <- Gen.bool
  rd <- genRegNonZero
  rs2 <- genRegNonZero
  let bit12 :: BitVector 1 = if isAdd then 1 else 0
      rs1Slot = if isAdd then rd else x0
      w =
        (0b100 :: BitVector 3)
          ++# bit12
          ++# unReg rd
          ++# unReg rs2
          ++# (0b10 :: BitVector 2)
  pure (w, Add rd rs1Slot rs2)

genCJrJalr :: CGen
genCJrJalr = do
  isJalr <- Gen.bool
  rs1 <- genRegNonZero
  let bit12 :: BitVector 1 = if isJalr then 1 else 0
      rdSlot = if isJalr then x1 else x0
      w =
        (0b100 :: BitVector 3)
          ++# bit12
          ++# unReg rs1
          ++# (0b00000 :: BitVector 5)
          ++# (0b10 :: BitVector 2)
  pure (w, Jalr rdSlot rs1 0)

genCRegAlu :: CGen
genCRegAlu = do
  -- rd' = rs1', rs2' = rs2P
  rdP <- genRegP
  rs2P <- genRegP
  sel <- Gen.element [(0b00 :: BitVector 2, Sub rdP rdP rs2P), (0b01, Xor rdP rdP rs2P), (0b10, Or rdP rdP rs2P), (0b11, And rdP rdP rs2P)]
  let (sel65, expected) = sel
      rdLo :: BitVector 3 = slice d2 d0 (unReg rdP)
      rs2Lo :: BitVector 3 = slice d2 d0 (unReg rs2P)
      w =
        (0b100 :: BitVector 3)
          ++# (0b0 :: BitVector 1) -- bit12
          ++# (0b11 :: BitVector 2) -- bits[11:10]
          ++# rdLo
          ++# sel65
          ++# rs2Lo
          ++# (0b01 :: BitVector 2)
  pure (w, expected)

genCShift :: CGen
genCShift = do
  -- C.SLLI uses rd_full (bits[11:7]); C.SRLI/C.SRAI use rd' (bits[9:7]+8).
  pick <- Gen.element ["slli", "srli", "srai"]
  shamtLo <- genBv5
  case pick of
    "slli" -> do
      rd <- genReg
      let w =
            (0b000 :: BitVector 3)
              ++# (0b0 :: BitVector 1)
              ++# unReg rd
              ++# shamtLo
              ++# (0b10 :: BitVector 2)
      pure (w, Slli rd rd shamtLo)
    "srli" -> do
      rdP <- genRegP
      let rdLo :: BitVector 3 = slice d2 d0 (unReg rdP)
          w =
            (0b100 :: BitVector 3)
              ++# (0b0 :: BitVector 1)
              ++# (0b00 :: BitVector 2)
              ++# rdLo
              ++# shamtLo
              ++# (0b01 :: BitVector 2)
      pure (w, Srli rdP rdP shamtLo)
    _ -> do
      rdP <- genRegP
      let rdLo :: BitVector 3 = slice d2 d0 (unReg rdP)
          w =
            (0b100 :: BitVector 3)
              ++# (0b0 :: BitVector 1)
              ++# (0b01 :: BitVector 2)
              ++# rdLo
              ++# shamtLo
              ++# (0b01 :: BitVector 2)
      pure (w, Srai rdP rdP shamtLo)

genCAndi :: CGen
genCAndi = do
  rdP <- genRegP
  imm6 <- genBv6
  let imm12 :: Signed 12 = resize (unpack imm6 :: Signed 6)
      i5 :: BitVector 1 = slice d5 d5 imm6
      i4_0 :: BitVector 5 = slice d4 d0 imm6
      rdLo :: BitVector 3 = slice d2 d0 (unReg rdP)
      w =
        (0b100 :: BitVector 3)
          ++# i5
          ++# (0b10 :: BitVector 2)
          ++# rdLo
          ++# i4_0
          ++# (0b01 :: BitVector 2)
  pure (w, Andi rdP rdP imm12)
