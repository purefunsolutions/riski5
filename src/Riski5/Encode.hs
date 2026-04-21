-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Riski5.Encode
Description : Encode 'Instr' values into 32-bit RISC-V machine words.

Mirror image of 'Riski5.Decode'. A total function — every
'Instr' value produced in Haskell encodes to some valid RV32I
machine word. The round-trip @decode . encode = Just@ is enforced
as a Hedgehog property in @test/DecodeSpec.hs@.
-}
module Riski5.Encode (
  encode,
) where

import Clash.Prelude hiding (And, Xor)
import Riski5.ISA

{- | Encode one RV32I / Zifencei / Zicsr / M-mode instruction into its
32-bit machine-word representation.
-}
encode :: Instr -> BitVector 32
encode = \case
  -- U-type
  Lui rd imm -> uType imm rd OpLui
  Auipc rd imm -> uType imm rd OpAuipc
  -- J-type
  Jal rd imm -> jType imm rd
  -- I-type (JALR + loads + arithmetic immediates)
  Jalr rd rs1 imm -> iType imm rs1 0b000 rd OpJalr
  Lb rd rs1 imm -> iType imm rs1 0b000 rd OpLoad
  Lh rd rs1 imm -> iType imm rs1 0b001 rd OpLoad
  Lw rd rs1 imm -> iType imm rs1 0b010 rd OpLoad
  Lbu rd rs1 imm -> iType imm rs1 0b100 rd OpLoad
  Lhu rd rs1 imm -> iType imm rs1 0b101 rd OpLoad
  Addi rd rs1 imm -> iType imm rs1 0b000 rd OpOpImm
  Slti rd rs1 imm -> iType imm rs1 0b010 rd OpOpImm
  Sltiu rd rs1 imm -> iType imm rs1 0b011 rd OpOpImm
  Xori rd rs1 imm -> iType imm rs1 0b100 rd OpOpImm
  Ori rd rs1 imm -> iType imm rs1 0b110 rd OpOpImm
  Andi rd rs1 imm -> iType imm rs1 0b111 rd OpOpImm
  -- I-type shifts: 5-bit shamt plus funct7 discriminating logical /
  -- arithmetic right shifts.
  Slli rd rs1 shamt -> shiftI 0b0000000 shamt rs1 0b001 rd
  Srli rd rs1 shamt -> shiftI 0b0000000 shamt rs1 0b101 rd
  Srai rd rs1 shamt -> shiftI 0b0100000 shamt rs1 0b101 rd
  -- S-type (stores)
  Sb rs1 rs2 imm -> sType imm rs2 rs1 0b000
  Sh rs1 rs2 imm -> sType imm rs2 rs1 0b001
  Sw rs1 rs2 imm -> sType imm rs2 rs1 0b010
  -- B-type (branches)
  Beq rs1 rs2 imm -> bType imm rs2 rs1 0b000
  Bne rs1 rs2 imm -> bType imm rs2 rs1 0b001
  Blt rs1 rs2 imm -> bType imm rs2 rs1 0b100
  Bge rs1 rs2 imm -> bType imm rs2 rs1 0b101
  Bltu rs1 rs2 imm -> bType imm rs2 rs1 0b110
  Bgeu rs1 rs2 imm -> bType imm rs2 rs1 0b111
  -- R-type (register-register arithmetic)
  Add rd rs1 rs2 -> rType 0b0000000 rs2 rs1 0b000 rd
  Sub rd rs1 rs2 -> rType 0b0100000 rs2 rs1 0b000 rd
  Sll rd rs1 rs2 -> rType 0b0000000 rs2 rs1 0b001 rd
  Slt rd rs1 rs2 -> rType 0b0000000 rs2 rs1 0b010 rd
  Sltu rd rs1 rs2 -> rType 0b0000000 rs2 rs1 0b011 rd
  Xor rd rs1 rs2 -> rType 0b0000000 rs2 rs1 0b100 rd
  Srl rd rs1 rs2 -> rType 0b0000000 rs2 rs1 0b101 rd
  Sra rd rs1 rs2 -> rType 0b0100000 rs2 rs1 0b101 rd
  Or rd rs1 rs2 -> rType 0b0000000 rs2 rs1 0b110 rd
  And rd rs1 rs2 -> rType 0b0000000 rs2 rs1 0b111 rd
  -- RV32M — R-type, funct7 = 0b0000001.
  Mul rd rs1 rs2 -> rType 0b0000001 rs2 rs1 0b000 rd
  MulH rd rs1 rs2 -> rType 0b0000001 rs2 rs1 0b001 rd
  MulHsu rd rs1 rs2 -> rType 0b0000001 rs2 rs1 0b010 rd
  MulHu rd rs1 rs2 -> rType 0b0000001 rs2 rs1 0b011 rd
  Div rd rs1 rs2 -> rType 0b0000001 rs2 rs1 0b100 rd
  DivU rd rs1 rs2 -> rType 0b0000001 rs2 rs1 0b101 rd
  Rem rd rs1 rs2 -> rType 0b0000001 rs2 rs1 0b110 rd
  RemU rd rs1 rs2 -> rType 0b0000001 rs2 rs1 0b111 rd
  -- FENCE: I-type with imm[11:0] = [fm(4) | pred(4) | succ(4)], rs1=0,
  -- rd=0, funct3=000. We always emit fm=0 (standard FENCE, not
  -- FENCE.TSO).
  Fence pred_ succ_ ->
    let imm12 :: BitVector 12
        imm12 = (0 :: BitVector 4) ++# pred_ ++# succ_
     in imm12 ++# unReg x0 ++# (0b000 :: BitVector 3) ++# unReg x0 ++# opcodeBits OpMiscMem
  FenceI ->
    let imm12 :: BitVector 12 = 0
     in imm12 ++# unReg x0 ++# (0b001 :: BitVector 3) ++# unReg x0 ++# opcodeBits OpMiscMem
  -- SYSTEM: environment / trap return. Hard-coded 32-bit encodings.
  Ecall -> 0x0000_0073
  Ebreak -> 0x0010_0073
  Mret -> 0x3020_0073
  -- Zicsr: register-source CSR ops (CSRRW/CSRRS/CSRRC).
  Csrrw rd rs1 csr -> csrR rs1 rd 0b001 csr
  Csrrs rd rs1 csr -> csrR rs1 rd 0b010 csr
  Csrrc rd rs1 csr -> csrR rs1 rd 0b011 csr
  -- Zicsr: immediate-source CSR ops (CSRRWI/CSRRSI/CSRRCI).
  Csrrwi rd zimm csr -> csrI zimm rd 0b101 csr
  Csrrsi rd zimm csr -> csrI zimm rd 0b110 csr
  Csrrci rd zimm csr -> csrI zimm rd 0b111 csr

{-
Format helpers. Each one assembles a 32-bit instruction from its
constituent fields in the order the spec requires.
-}

-- | R-type: @funct7 | rs2 | rs1 | funct3 | rd | opcode=OpOp@.
rType ::
  BitVector 7 ->
  Reg ->
  Reg ->
  BitVector 3 ->
  Reg ->
  BitVector 32
rType funct7 rs2 rs1 funct3 rd =
  funct7
    ++# unReg rs2
    ++# unReg rs1
    ++# funct3
    ++# unReg rd
    ++# opcodeBits OpOp

-- | I-type: @imm[11:0] | rs1 | funct3 | rd | opcode@.
iType ::
  Signed 12 ->
  Reg ->
  BitVector 3 ->
  Reg ->
  Opcode ->
  BitVector 32
iType imm rs1 funct3 rd op =
  pack imm
    ++# unReg rs1
    ++# funct3
    ++# unReg rd
    ++# opcodeBits op

-- | Shift-immediate variant of I-type: @funct7 | shamt(5) | rs1 | funct3 | rd | OpOpImm@.
shiftI ::
  BitVector 7 ->
  BitVector 5 ->
  Reg ->
  BitVector 3 ->
  Reg ->
  BitVector 32
shiftI funct7 shamt rs1 funct3 rd =
  funct7
    ++# shamt
    ++# unReg rs1
    ++# funct3
    ++# unReg rd
    ++# opcodeBits OpOpImm

-- | S-type: @imm[11:5] | rs2 | rs1 | funct3 | imm[4:0] | OpStore@.
sType ::
  Signed 12 ->
  Reg ->
  Reg ->
  BitVector 3 ->
  BitVector 32
sType imm rs2 rs1 funct3 =
  let i :: BitVector 12
      i = pack imm
      hi :: BitVector 7
      hi = slice d11 d5 i
      lo :: BitVector 5
      lo = slice d4 d0 i
   in hi
        ++# unReg rs2
        ++# unReg rs1
        ++# funct3
        ++# lo
        ++# opcodeBits OpStore

{- |
B-type: branch-offset imm is 13 bits (imm[12:0]) with imm[0] implicit
zero. Bits are permuted in the instruction:

@
 instr[31]    = imm[12]
 instr[30:25] = imm[10:5]
 instr[24:20] = rs2
 instr[19:15] = rs1
 instr[14:12] = funct3
 instr[11:8]  = imm[4:1]
 instr[7]     = imm[11]
 instr[6:0]   = opcode
@
-}
bType ::
  Signed 13 ->
  Reg ->
  Reg ->
  BitVector 3 ->
  BitVector 32
bType imm rs2 rs1 funct3 =
  let i :: BitVector 13
      i = pack imm
      b12 :: BitVector 1
      b12 = slice d12 d12 i
      b10_5 :: BitVector 6
      b10_5 = slice d10 d5 i
      b4_1 :: BitVector 4
      b4_1 = slice d4 d1 i
      b11 :: BitVector 1
      b11 = slice d11 d11 i
   in b12
        ++# b10_5
        ++# unReg rs2
        ++# unReg rs1
        ++# funct3
        ++# b4_1
        ++# b11
        ++# opcodeBits OpBranch

-- | U-type: @imm[31:12] | rd | opcode@. 20-bit immediate; no permutation.
uType :: BitVector 20 -> Reg -> Opcode -> BitVector 32
uType imm rd op = imm ++# unReg rd ++# opcodeBits op

{- |
J-type: jump-offset imm is 21 bits (imm[20:0]) with imm[0] implicit
zero. Bits are permuted in the instruction:

@
 instr[31]    = imm[20]
 instr[30:21] = imm[10:1]
 instr[20]    = imm[11]
 instr[19:12] = imm[19:12]
 instr[11:7]  = rd
 instr[6:0]   = opcode (OpJal)
@
-}
jType :: Signed 21 -> Reg -> BitVector 32
jType imm rd =
  let i :: BitVector 21
      i = pack imm
      b20 :: BitVector 1
      b20 = slice d20 d20 i
      b10_1 :: BitVector 10
      b10_1 = slice d10 d1 i
      b11 :: BitVector 1
      b11 = slice d11 d11 i
      b19_12 :: BitVector 8
      b19_12 = slice d19 d12 i
   in b20
        ++# b10_1
        ++# b11
        ++# b19_12
        ++# unReg rd
        ++# opcodeBits OpJal

-- | CSR register-source form (CSRRW / CSRRS / CSRRC).
csrR :: Reg -> Reg -> BitVector 3 -> Csr -> BitVector 32
csrR rs1 rd funct3 csr =
  unCsr csr
    ++# unReg rs1
    ++# funct3
    ++# unReg rd
    ++# opcodeBits OpSystem

{- | CSR immediate-source form (CSRRWI / CSRRSI / CSRRCI); the 5-bit
uimm replaces the rs1 field in the encoding.
-}
csrI :: BitVector 5 -> Reg -> BitVector 3 -> Csr -> BitVector 32
csrI zimm rd funct3 csr =
  unCsr csr
    ++# zimm
    ++# funct3
    ++# unReg rd
    ++# opcodeBits OpSystem
