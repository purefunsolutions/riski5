-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Riski5.Decode
Description : Decode 32-bit RV32I machine words back to 'Instr'.

Mirror image of 'Riski5.Encode'. Every bit pattern that 'encode'
can produce round-trips through @decode@ exactly; any pattern that
doesn't correspond to a supported instruction returns 'Nothing',
which the hardware core treats as an illegal-instruction trap.
The round-trip @decode . encode = Just@ is enforced as a Hedgehog
property in @test/DecodeSpec.hs@.
-}
module Riski5.Decode (
  decode,
) where

import Clash.Prelude hiding (And, Xor, (&&))
import Riski5.ISA

{- | Decode one 32-bit RISC-V machine word into an 'Instr'.

Returns 'Nothing' for illegal / unsupported patterns — the core's
trap logic uses that to raise @mcause = illegal-instruction@.
-}
decode :: BitVector 32 -> Maybe Instr
decode w = case opcode of
  0b011_0111 -> Just (Lui rd uImm)
  0b001_0111 -> Just (Auipc rd uImm)
  0b110_1111 -> Just (Jal rd jImm)
  0b110_0111
    | funct3 == 0b000 -> Just (Jalr rd rs1 iImm)
    | otherwise -> Nothing
  0b000_0011 -> decodeLoad rd rs1 iImm funct3
  0b010_0011 -> decodeStore rs1 rs2 sImm funct3
  0b001_0011 -> decodeOpImm rd rs1 iImm funct3 shamt funct7
  0b011_0011 -> decodeOp rd rs1 rs2 funct3 funct7
  0b110_0011 -> decodeBranch rs1 rs2 bImm funct3
  0b000_1111 -> decodeMiscMem w funct3
  0b111_0011 -> decodeSystem w rd rs1 funct3 csr zimm
  0b010_1111 -> decodeAmo rd rs1 rs2 funct3 funct5 aqrl
  _ -> Nothing
 where
  -- Field extraction. These are pure wire slices; Clash/Quartus will
  -- eliminate any unused ones as dead logic.
  opcode :: BitVector 7
  opcode = slice d6 d0 w

  rd :: Reg
  rd = Reg (slice d11 d7 w)

  funct3 :: BitVector 3
  funct3 = slice d14 d12 w

  rs1 :: Reg
  rs1 = Reg (slice d19 d15 w)

  rs2 :: Reg
  rs2 = Reg (slice d24 d20 w)

  funct7 :: BitVector 7
  funct7 = slice d31 d25 w

  -- Shift-immediate shamt (5 bits).
  shamt :: BitVector 5
  shamt = slice d24 d20 w

  -- I-type immediate: sign-extended 12 bits.
  iImm :: Signed 12
  iImm = unpack (slice d31 d20 w)

  -- S-type immediate: imm[11:5] | imm[4:0] = [31:25] | [11:7].
  sImm :: Signed 12
  sImm =
    unpack
      ( slice d31 d25 w
          ++# (slice d11 d7 w :: BitVector 5)
      )

  -- B-type immediate: imm[12] | imm[10:5] | imm[4:1] | imm[11] | 0.
  -- Reassembled as a 13-bit signed offset, LSB always zero.
  bImm :: Signed 13
  bImm =
    unpack
      ( (slice d31 d31 w :: BitVector 1)
          ++# (slice d7 d7 w :: BitVector 1)
          ++# (slice d30 d25 w :: BitVector 6)
          ++# (slice d11 d8 w :: BitVector 4)
          ++# (0 :: BitVector 1)
      )

  -- U-type immediate: top 20 bits, no permutation.
  uImm :: BitVector 20
  uImm = slice d31 d12 w

  -- J-type immediate: imm[20] | imm[19:12] | imm[11] | imm[10:1] | 0.
  jImm :: Signed 21
  jImm =
    unpack
      ( (slice d31 d31 w :: BitVector 1)
          ++# (slice d19 d12 w :: BitVector 8)
          ++# (slice d20 d20 w :: BitVector 1)
          ++# (slice d30 d21 w :: BitVector 10)
          ++# (0 :: BitVector 1)
      )

  -- CSR address: top 12 bits of the SYSTEM-opcode instruction.
  csr :: Csr
  csr = Csr (slice d31 d20 w)

  -- Zicsr immediate-form 5-bit zero-extended immediate (sits in the
  -- rs1 field).
  zimm :: BitVector 5
  zimm = slice d19 d15 w

  -- A-extension funct5 picker (top 5 bits of funct7's home).
  funct5 :: BitVector 5
  funct5 = slice d31 d27 w

  -- A-extension aq/rl hint pair: bit 26 = aq, bit 25 = rl.
  aqrl :: BitVector 2
  aqrl = slice d26 d25 w

decodeLoad :: Reg -> Reg -> Signed 12 -> BitVector 3 -> Maybe Instr
decodeLoad rd rs1 imm = \case
  0b000 -> Just (Lb rd rs1 imm)
  0b001 -> Just (Lh rd rs1 imm)
  0b010 -> Just (Lw rd rs1 imm)
  0b100 -> Just (Lbu rd rs1 imm)
  0b101 -> Just (Lhu rd rs1 imm)
  _ -> Nothing

decodeStore :: Reg -> Reg -> Signed 12 -> BitVector 3 -> Maybe Instr
decodeStore rs1 rs2 imm = \case
  0b000 -> Just (Sb rs1 rs2 imm)
  0b001 -> Just (Sh rs1 rs2 imm)
  0b010 -> Just (Sw rs1 rs2 imm)
  _ -> Nothing

decodeOpImm ::
  Reg ->
  Reg ->
  Signed 12 ->
  BitVector 3 ->
  BitVector 5 ->
  BitVector 7 ->
  Maybe Instr
decodeOpImm rd rs1 imm funct3 shamt funct7 = case funct3 of
  0b000 -> Just (Addi rd rs1 imm)
  0b010 -> Just (Slti rd rs1 imm)
  0b011 -> Just (Sltiu rd rs1 imm)
  0b100 -> Just (Xori rd rs1 imm)
  0b110 -> Just (Ori rd rs1 imm)
  0b111 -> Just (Andi rd rs1 imm)
  0b001
    | funct7 == 0b0000000 -> Just (Slli rd rs1 shamt)
    | otherwise -> Nothing
  0b101 -> case funct7 of
    0b0000000 -> Just (Srli rd rs1 shamt)
    0b0100000 -> Just (Srai rd rs1 shamt)
    _ -> Nothing
  _ -> Nothing

decodeOp ::
  Reg ->
  Reg ->
  Reg ->
  BitVector 3 ->
  BitVector 7 ->
  Maybe Instr
decodeOp rd rs1 rs2 funct3 funct7 = case (funct3, funct7) of
  (0b000, 0b0000000) -> Just (Add rd rs1 rs2)
  (0b000, 0b0100000) -> Just (Sub rd rs1 rs2)
  (0b001, 0b0000000) -> Just (Sll rd rs1 rs2)
  (0b010, 0b0000000) -> Just (Slt rd rs1 rs2)
  (0b011, 0b0000000) -> Just (Sltu rd rs1 rs2)
  (0b100, 0b0000000) -> Just (Xor rd rs1 rs2)
  (0b101, 0b0000000) -> Just (Srl rd rs1 rs2)
  (0b101, 0b0100000) -> Just (Sra rd rs1 rs2)
  (0b110, 0b0000000) -> Just (Or rd rs1 rs2)
  (0b111, 0b0000000) -> Just (And rd rs1 rs2)
  -- RV32M: same opcode + R-type as integer ops, funct7 = 0b0000001
  -- disambiguates. funct3 selects the specific variant.
  (0b000, 0b0000001) -> Just (Mul rd rs1 rs2)
  (0b001, 0b0000001) -> Just (MulH rd rs1 rs2)
  (0b010, 0b0000001) -> Just (MulHsu rd rs1 rs2)
  (0b011, 0b0000001) -> Just (MulHu rd rs1 rs2)
  (0b100, 0b0000001) -> Just (Div rd rs1 rs2)
  (0b101, 0b0000001) -> Just (DivU rd rs1 rs2)
  (0b110, 0b0000001) -> Just (Rem rd rs1 rs2)
  (0b111, 0b0000001) -> Just (RemU rd rs1 rs2)
  _ -> Nothing

decodeBranch :: Reg -> Reg -> Signed 13 -> BitVector 3 -> Maybe Instr
decodeBranch rs1 rs2 imm = \case
  0b000 -> Just (Beq rs1 rs2 imm)
  0b001 -> Just (Bne rs1 rs2 imm)
  0b100 -> Just (Blt rs1 rs2 imm)
  0b101 -> Just (Bge rs1 rs2 imm)
  0b110 -> Just (Bltu rs1 rs2 imm)
  0b111 -> Just (Bgeu rs1 rs2 imm)
  _ -> Nothing

decodeMiscMem :: BitVector 32 -> BitVector 3 -> Maybe Instr
decodeMiscMem w = \case
  0b000 ->
    -- FENCE: we accept any fm=0 encoding with rs1=0, rd=0.
    let fm :: BitVector 4 = slice d31 d28 w
        pred_ :: BitVector 4 = slice d27 d24 w
        succ_ :: BitVector 4 = slice d23 d20 w
        rs1Field :: BitVector 5 = slice d19 d15 w
        rdField :: BitVector 5 = slice d11 d7 w
     in if fm == 0 && rs1Field == 0 && rdField == 0
          then Just (Fence pred_ succ_)
          else Nothing
  0b001 ->
    -- FENCE.I: strictly zero imm/rs1/rd.
    if slice d31 d20 w == (0 :: BitVector 12)
      && slice d19 d15 w == (0 :: BitVector 5)
      && slice d11 d7 w == (0 :: BitVector 5)
      then Just FenceI
      else Nothing
  _ -> Nothing

decodeAmo ::
  Reg ->
  Reg ->
  Reg ->
  BitVector 3 ->
  BitVector 5 ->
  BitVector 2 ->
  Maybe Instr
decodeAmo rd rs1 rs2 funct3 funct5 aqrl
  | funct3 /= 0b010 = Nothing
  | otherwise = case funct5 of
      0b00010
        -- LR.W requires rs2 = 0 per the spec.
        | unReg rs2 == 0 -> Just (LrW rd rs1 aqrl)
        | otherwise -> Nothing
      0b00011 -> Just (ScW rd rs1 rs2 aqrl)
      0b00001 -> Just (AmoSwapW rd rs1 rs2 aqrl)
      0b00000 -> Just (AmoAddW rd rs1 rs2 aqrl)
      0b00100 -> Just (AmoXorW rd rs1 rs2 aqrl)
      0b01100 -> Just (AmoAndW rd rs1 rs2 aqrl)
      0b01000 -> Just (AmoOrW rd rs1 rs2 aqrl)
      0b10000 -> Just (AmoMinW rd rs1 rs2 aqrl)
      0b10100 -> Just (AmoMaxW rd rs1 rs2 aqrl)
      0b11000 -> Just (AmoMinuW rd rs1 rs2 aqrl)
      0b11100 -> Just (AmoMaxuW rd rs1 rs2 aqrl)
      _ -> Nothing

decodeSystem ::
  BitVector 32 ->
  Reg ->
  Reg ->
  BitVector 3 ->
  Csr ->
  BitVector 5 ->
  Maybe Instr
decodeSystem w rd rs1 funct3 csr zimm
  -- ECALL / EBREAK / MRET: funct3 = 000. Disambiguated by the top 12
  -- bits.
  | funct3 == 0b000 && unReg rd == 0 && unReg rs1 == 0 =
      case slice d31 d20 w :: BitVector 12 of
        0x000 -> Just Ecall
        0x001 -> Just Ebreak
        0x302 -> Just Mret
        0x105 -> Just Wfi
        _ -> Nothing
  -- Zicsr register-source forms.
  | funct3 == 0b001 = Just (Csrrw rd rs1 csr)
  | funct3 == 0b010 = Just (Csrrs rd rs1 csr)
  | funct3 == 0b011 = Just (Csrrc rd rs1 csr)
  -- Zicsr immediate-source forms — zimm replaces rs1 in the bit
  -- layout, so we reconstruct from the raw slice.
  | funct3 == 0b101 = Just (Csrrwi rd zimm csr)
  | funct3 == 0b110 = Just (Csrrsi rd zimm csr)
  | funct3 == 0b111 = Just (Csrrci rd zimm csr)
  | otherwise = Nothing
