-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Riski5.Compressed
Description : RV32C (compressed) 16-bit instruction expander.

Pure 16-to-32-bit expander for the RISC-V "C" (compressed)
extension. Every legal RV32C encoding maps to exactly one
RV32I/M/A/Zicsr/Zifencei equivalent — the spec is explicit
about each compressed instruction's 32-bit "expanded form" — so
the cleanest implementation is a function

@
expandCompressed :: BitVector 16 -> Maybe (BitVector 32)
@

that emits the 32-bit machine word the rest of the pipeline
already knows how to decode and execute. Handing the expanded
word to 'Riski5.Decode.decode' yields the same 'Riski5.ISA.Instr'
the assembler eDSL would have built directly. Reserved encodings
(C.ADDI4SPN with @nzuimm = 0@, C.SRLI/SRAI/SLLI with @shamt[5] = 1@
on RV32, RV64-only forms, illegal Q2-100 patterns) return
'Nothing' so the IF stage can raise an illegal-instruction trap.

== Quadrant overview

All compressed instructions have @opcode[1:0] /= 0b11@:

  * @op = 00@ — Q0: stack-pointer-relative or compressed loads/stores.
    Implements C.ADDI4SPN, C.LW, C.SW. RV32 reserves C.FLD, C.FLW,
    C.FSD, C.FSW (no F/D extensions) and the unallocated funct3 = 100.
  * @op = 01@ — Q1: integer immediates and ALU ops, plus the
    compressed jumps and conditional branches.
    Implements C.NOP, C.ADDI, C.JAL, C.LI, C.LUI, C.ADDI16SP,
    C.SRLI, C.SRAI, C.ANDI, C.SUB, C.XOR, C.OR, C.AND, C.J,
    C.BEQZ, C.BNEZ. C.SUBW / C.ADDW are RV64-only and return Nothing.
  * @op = 10@ — Q2: stack-pointer-relative loads/stores plus the
    register-only forms. Implements C.SLLI, C.LWSP, C.JR, C.MV,
    C.EBREAK, C.JALR, C.ADD, C.SWSP. C.FLDSP, C.FLWSP, C.FSDSP, C.FSWSP
    return Nothing on RV32.

== Why expander not direct decoder

The hardware decoder in 'Riski5.Decode' already covers every 32-bit
form the C-extension can map onto, so growing the @Instr@ algebra
with parallel "compressed" constructors would just duplicate the
back-end. Expanding once at the IF stage means the rest of the
pipeline (Decode, Reference, ALU dispatch, RVFI) stays bit-identical
between RV32IMA and RV32IMAC builds. The only RV32IMAC-specific
hardware is the IF-stage realigner (which lets PC sit at 2-byte
boundaries and stitches uncompressed instructions across word
boundaries) plus this expander.
-}
module Riski5.Compressed (
  isCompressedHalf,
  expandCompressed,
) where

import Clash.Prelude hiding (And, Xor)
import Riski5.Encode (encode)
import Riski5.ISA

{- | True when @[1:0] /= 0b11@. The RISC-V spec carves up the
opcode space so any half-word that begins a compressed (16-bit)
instruction has its bottom two bits in @{00, 01, 10}@; uncompressed
(32-bit) instructions have @11@ in those bits. The IF-stage
realigner uses this on the lower 16 bits of each fetched word to
decide how far to advance the PC.
-}
isCompressedHalf :: BitVector 16 -> Bool
isCompressedHalf w = slice d1 d0 w /= (0b11 :: BitVector 2)

{- | Expand one 16-bit compressed instruction into its 32-bit
equivalent. Returns 'Nothing' for any reserved encoding so the IF
stage can raise an illegal-instruction trap.

Implements the bit-for-bit mapping in the RISC-V Unprivileged ISA
spec (Chapter 16 in the 2024 release): every legal compressed
encoding has exactly one expanded form, matching the immediate
width / sign-extension rules tabulated there.
-}
expandCompressed :: BitVector 16 -> Maybe (BitVector 32)
expandCompressed w = case (op, funct3) of
  -- Quadrant 0 ------------------------------------------------------
  (0b00, 0b000) -> expandCAddi4spn
  (0b00, 0b010) -> Just expandCLw
  (0b00, 0b110) -> Just expandCSw
  -- Quadrant 1 ------------------------------------------------------
  (0b01, 0b000) -> Just expandCAddi
  (0b01, 0b001) -> Just expandCJal
  (0b01, 0b010) -> Just expandCLi
  (0b01, 0b011) -> expandCLuiOrAddi16sp
  (0b01, 0b100) -> expandCMiscAlu
  (0b01, 0b101) -> Just expandCJ
  (0b01, 0b110) -> Just expandCBeqz
  (0b01, 0b111) -> Just expandCBnez
  -- Quadrant 2 ------------------------------------------------------
  (0b10, 0b000) -> expandCSlli
  (0b10, 0b010) -> expandCLwsp
  (0b10, 0b100) -> expandCQ2_100
  (0b10, 0b110) -> Just expandCSwsp
  _ -> Nothing
 where
  -- ---------------------------------------------------------------
  -- Field extractors
  -- ---------------------------------------------------------------

  op :: BitVector 2
  op = slice d1 d0 w

  funct3 :: BitVector 3
  funct3 = slice d15 d13 w

  -- Bits [11:7] — full 5-bit register field, used as both rd and rs1
  -- in different forms. C.ADDI / C.LI / C.LUI / C.ADDI16SP / C.SLLI /
  -- C.LWSP / C.JR / C.JALR all source from this slot.
  rdFull :: Reg
  rdFull = Reg (slice d11 d7 w)

  -- Bits [6:2] — 5-bit register field used as rs2 in C.MV / C.ADD /
  -- C.SWSP.
  rs2Full :: Reg
  rs2Full = Reg (slice d6 d2 w)

  -- 3-bit "compressed" register fields map to x8..x15, encoded by
  -- prefixing 01_ to the 3-bit slot.
  rdP :: Reg
  rdP = Reg ((0b01 :: BitVector 2) ++# slice d4 d2 w)

  rs1P :: Reg
  rs1P = Reg ((0b01 :: BitVector 2) ++# slice d9 d7 w)

  rs2P :: Reg
  rs2P = rdP

  -- ---------------------------------------------------------------
  -- Quadrant 0
  -- ---------------------------------------------------------------

  -- C.ADDI4SPN — addi rd', x2, nzuimm[9:2] << 2
  -- Bits: [12:11]=imm[5:4], [10:7]=imm[9:6], [6]=imm[2], [5]=imm[3]
  expandCAddi4spn :: Maybe (BitVector 32)
  expandCAddi4spn =
    let imm9_6 :: BitVector 4 = slice d10 d7 w
        imm5_4 :: BitVector 2 = slice d12 d11 w
        imm3 :: BitVector 1 = slice d5 d5 w
        imm2 :: BitVector 1 = slice d6 d6 w
        nzuimm :: BitVector 10 =
          imm9_6 ++# imm5_4 ++# imm3 ++# imm2 ++# (0 :: BitVector 2)
        imm12 :: Signed 12 = unpack (zeroExtend nzuimm)
     in if nzuimm == 0
          then Nothing
          else Just (encode (Addi rdP x2 imm12))

  -- C.LW — lw rd', uimm(rs1')
  -- Bits: [12:10]=imm[5:3], [6]=imm[2], [5]=imm[6]
  expandCLw :: BitVector 32
  expandCLw =
    let imm5_3 :: BitVector 3 = slice d12 d10 w
        imm2 :: BitVector 1 = slice d6 d6 w
        imm6 :: BitVector 1 = slice d5 d5 w
        uimm :: BitVector 7 =
          imm6 ++# imm5_3 ++# imm2 ++# (0 :: BitVector 2)
        imm12 :: Signed 12 = unpack (zeroExtend uimm)
     in encode (Lw rdP rs1P imm12)

  -- C.SW — sw rs2', uimm(rs1')
  expandCSw :: BitVector 32
  expandCSw =
    let imm5_3 :: BitVector 3 = slice d12 d10 w
        imm2 :: BitVector 1 = slice d6 d6 w
        imm6 :: BitVector 1 = slice d5 d5 w
        uimm :: BitVector 7 =
          imm6 ++# imm5_3 ++# imm2 ++# (0 :: BitVector 2)
        imm12 :: Signed 12 = unpack (zeroExtend uimm)
     in encode (Sw rs1P rs2P imm12)

  -- ---------------------------------------------------------------
  -- Quadrant 1
  -- ---------------------------------------------------------------

  -- C.ADDI — addi rd, rd, imm[5:0] (sign-extended)
  -- Bits: [12]=imm[5], [6:2]=imm[4:0]
  -- rd = x0 with imm = 0 is C.NOP; rd = x0 with imm /= 0 is HINT.
  -- Both round-trip cleanly through Addi x0 x0 imm.
  expandCAddi :: BitVector 32
  expandCAddi =
    let imm5 :: BitVector 1 = slice d12 d12 w
        imm4_0 :: BitVector 5 = slice d6 d2 w
        imm6Bv :: BitVector 6 = imm5 ++# imm4_0
        imm12 :: Signed 12 = resize (unpack imm6Bv :: Signed 6)
     in encode (Addi rdFull rdFull imm12)

  -- C.JAL — jal x1, offset[11:1]
  -- Bits: [12]=imm[11], [11]=imm[4], [10:9]=imm[9:8], [8]=imm[10],
  --       [7]=imm[6], [6]=imm[7], [5:3]=imm[3:1], [2]=imm[5]
  expandCJal :: BitVector 32
  expandCJal = encode (Jal x1 cjImm)

  -- C.J — jal x0, offset[11:1] — same imm encoding as C.JAL
  expandCJ :: BitVector 32
  expandCJ = encode (Jal x0 cjImm)

  cjImm :: Signed 21
  cjImm =
    let i11 :: BitVector 1 = slice d12 d12 w
        i4 :: BitVector 1 = slice d11 d11 w
        i9_8 :: BitVector 2 = slice d10 d9 w
        i10 :: BitVector 1 = slice d8 d8 w
        i6 :: BitVector 1 = slice d7 d7 w
        i7 :: BitVector 1 = slice d6 d6 w
        i3_1 :: BitVector 3 = slice d5 d3 w
        i5 :: BitVector 1 = slice d2 d2 w
        imm12Bv :: BitVector 12 =
          i11
            ++# i10
            ++# i9_8
            ++# i7
            ++# i6
            ++# i5
            ++# i4
            ++# i3_1
            ++# (0 :: BitVector 1)
     in resize (unpack imm12Bv :: Signed 12)

  -- C.LI — addi rd, x0, imm[5:0]
  expandCLi :: BitVector 32
  expandCLi =
    let imm5 :: BitVector 1 = slice d12 d12 w
        imm4_0 :: BitVector 5 = slice d6 d2 w
        imm6Bv :: BitVector 6 = imm5 ++# imm4_0
        imm12 :: Signed 12 = resize (unpack imm6Bv :: Signed 6)
     in encode (Addi rdFull x0 imm12)

  -- C.LUI / C.ADDI16SP — disambiguated by rd field.
  -- rd == x2: C.ADDI16SP — addi x2, x2, nzimm[9:4] << 4
  --   Bits: [12]=imm[9], [6]=imm[4], [5]=imm[6], [4:3]=imm[8:7], [2]=imm[5]
  -- rd == x0: HINT (kept; expanded to a NOP-equivalent).
  -- otherwise: C.LUI — lui rd, nzimm[17:12]
  --   Bits: [12]=imm[17], [6:2]=imm[16:12]
  -- Both reserve nzimm = 0.
  expandCLuiOrAddi16sp :: Maybe (BitVector 32)
  expandCLuiOrAddi16sp
    | unReg rdFull == 2 =
        let i9 :: BitVector 1 = slice d12 d12 w
            i4 :: BitVector 1 = slice d6 d6 w
            i6 :: BitVector 1 = slice d5 d5 w
            i8_7 :: BitVector 2 = slice d4 d3 w
            i5 :: BitVector 1 = slice d2 d2 w
            imm10Bv :: BitVector 10 =
              i9 ++# i8_7 ++# i6 ++# i5 ++# i4 ++# (0 :: BitVector 4)
            imm12 :: Signed 12 = resize (unpack imm10Bv :: Signed 10)
         in if imm10Bv == 0
              then Nothing
              else Just (encode (Addi x2 x2 imm12))
    | unReg rdFull == 0 =
        Just (encode (Addi x0 x0 0))
    | otherwise =
        let i17 :: BitVector 1 = slice d12 d12 w
            i16_12 :: BitVector 5 = slice d6 d2 w
            imm6Bv :: BitVector 6 = i17 ++# i16_12
            imm20 :: BitVector 20 =
              pack (resize (unpack imm6Bv :: Signed 6) :: Signed 20)
         in if imm6Bv == 0
              then Nothing
              else Just (encode (Lui rdFull imm20))

  -- C.MISC-ALU — Q1 funct3 = 100. Sub-decoded by [11:10]:
  --   00 -> C.SRLI
  --   01 -> C.SRAI
  --   10 -> C.ANDI
  --   11 -> C.SUB / C.XOR / C.OR / C.AND / RV64-only (reserved RV32)
  --
  -- Note: dest+src register for these forms lives in the bits [9:7]
  -- slot ('rs1P'), not bits [4:2] ('rdP'). 'rdP' / 'rs2P' name the
  -- bits [4:2] slot used by C.LW (rd') and C.SW / C.MISC-ALU (rs2').
  expandCMiscAlu :: Maybe (BitVector 32)
  expandCMiscAlu = case slice d11 d10 w :: BitVector 2 of
    0b00 -> shiftRight Srli
    0b01 -> shiftRight Srai
    0b10 ->
      let imm5 :: BitVector 1 = slice d12 d12 w
          imm4_0 :: BitVector 5 = slice d6 d2 w
          imm6Bv :: BitVector 6 = imm5 ++# imm4_0
          imm12 :: Signed 12 = resize (unpack imm6Bv :: Signed 6)
       in Just (encode (Andi rs1P rs1P imm12))
    _ -> case (slice d12 d12 w, slice d6 d5 w) of
      (0, 0b00) -> Just (encode (Sub rs1P rs1P rs2P))
      (0, 0b01) -> Just (encode (Xor rs1P rs1P rs2P))
      (0, 0b10) -> Just (encode (Or rs1P rs1P rs2P))
      (0, 0b11) -> Just (encode (And rs1P rs1P rs2P))
      _ -> Nothing
   where
    shiftRight ::
      (Reg -> Reg -> BitVector 5 -> Instr) ->
      Maybe (BitVector 32)
    shiftRight build =
      let shamtHi :: BitVector 1 = slice d12 d12 w
          shamtLo :: BitVector 5 = slice d6 d2 w
       in if shamtHi == 1
            then Nothing
            else Just (encode (build rs1P rs1P shamtLo))

  -- C.BEQZ — beq rs1', x0, offset[8:1]
  -- Bits: [12]=imm[8], [11:10]=imm[4:3], [6:5]=imm[7:6],
  --       [4:3]=imm[2:1], [2]=imm[5]
  expandCBeqz :: BitVector 32
  expandCBeqz = encode (Beq rs1P x0 cbImm)

  expandCBnez :: BitVector 32
  expandCBnez = encode (Bne rs1P x0 cbImm)

  cbImm :: Signed 13
  cbImm =
    let i8 :: BitVector 1 = slice d12 d12 w
        i4_3 :: BitVector 2 = slice d11 d10 w
        i7_6 :: BitVector 2 = slice d6 d5 w
        i2_1 :: BitVector 2 = slice d4 d3 w
        i5 :: BitVector 1 = slice d2 d2 w
        imm9Bv :: BitVector 9 =
          i8
            ++# i7_6
            ++# i5
            ++# i4_3
            ++# i2_1
            ++# (0 :: BitVector 1)
     in resize (unpack imm9Bv :: Signed 9)

  -- ---------------------------------------------------------------
  -- Quadrant 2
  -- ---------------------------------------------------------------

  -- C.SLLI — slli rd, rd, shamt
  -- Bits: [12]=shamt[5] (RV32 reserved if 1), [6:2]=shamt[4:0]
  expandCSlli :: Maybe (BitVector 32)
  expandCSlli =
    let shamtHi :: BitVector 1 = slice d12 d12 w
        shamtLo :: BitVector 5 = slice d6 d2 w
     in if shamtHi == 1
          then Nothing
          else Just (encode (Slli rdFull rdFull shamtLo))

  -- C.LWSP — lw rd, uimm(x2). rd = x0 reserved.
  -- Bits: [12]=imm[5], [6:4]=imm[4:2], [3:2]=imm[7:6]
  expandCLwsp :: Maybe (BitVector 32)
  expandCLwsp =
    let i5 :: BitVector 1 = slice d12 d12 w
        i4_2 :: BitVector 3 = slice d6 d4 w
        i7_6 :: BitVector 2 = slice d3 d2 w
        uimm8Bv :: BitVector 8 =
          i7_6 ++# i5 ++# i4_2 ++# (0 :: BitVector 2)
        imm12 :: Signed 12 = unpack (zeroExtend uimm8Bv)
     in if unReg rdFull == 0
          then Nothing
          else Just (encode (Lw rdFull x2 imm12))

  -- C.JR / C.MV / C.EBREAK / C.JALR / C.ADD — Q2 funct3 = 100,
  -- sub-decoded by bit[12], rs2 (bits[6:2]), rd/rs1 (bits[11:7]):
  --
  --   bit12=0, rs2=0, rs1=0  -> reserved (Nothing)
  --   bit12=0, rs2=0, rs1!=0 -> C.JR (jalr x0, rs1, 0)
  --   bit12=0, rs2!=0        -> C.MV (add rd, x0, rs2); rd=0 is HINT
  --   bit12=1, rs2=0, rd=0   -> C.EBREAK
  --   bit12=1, rs2=0, rd!=0  -> C.JALR (jalr x1, rs1, 0)
  --   bit12=1, rs2!=0        -> C.ADD (add rd, rd, rs2); rd=0 is HINT
  expandCQ2_100 :: Maybe (BitVector 32)
  expandCQ2_100 = case slice d12 d12 w :: BitVector 1 of
    0 ->
      if unReg rs2Full == 0
        then
          if unReg rdFull == 0
            then Nothing
            else Just (encode (Jalr x0 rdFull 0))
        else Just (encode (Add rdFull x0 rs2Full))
    _ ->
      if unReg rs2Full == 0
        then
          if unReg rdFull == 0
            then Just (encode Ebreak)
            else Just (encode (Jalr x1 rdFull 0))
        else Just (encode (Add rdFull rdFull rs2Full))

  -- C.SWSP — sw rs2, uimm(x2)
  -- Bits: [12:9]=imm[5:2], [8:7]=imm[7:6]
  expandCSwsp :: BitVector 32
  expandCSwsp =
    let i5_2 :: BitVector 4 = slice d12 d9 w
        i7_6 :: BitVector 2 = slice d8 d7 w
        uimm8Bv :: BitVector 8 =
          i7_6 ++# i5_2 ++# (0 :: BitVector 2)
        imm12 :: Signed 12 = unpack (zeroExtend uimm8Bv)
     in encode (Sw x2 rs2Full imm12)
