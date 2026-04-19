-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Riski5.ISA
Description : Type-level RV32I + Zicsr + privileged-mode ISA definition.

Single source of truth for the riski5 RISC-V core. Every bit-level
detail of the instruction set — opcodes, funct-3 / funct-7 codes,
instruction formats, register and CSR namespaces — lives here.
'Riski5.Encode' turns 'Instr' values into 32-bit machine words,
'Riski5.Decode' turns 32-bit machine words back into 'Instr', and
both the hardware decoder inside the core and the Haskell-embedded
assembler eDSL ('Riski5.Asm') consume this module verbatim. There
is no separate \"software\" copy of the ISA; changing it means
editing this file.

Instruction coverage:

  * All 47 base RV32I instructions (arithmetic, logical, shifts,
    loads, stores, branches, jumps, upper-immediate ops, FENCE,
    ECALL, EBREAK).
  * Zifencei: @FENCE.I@.
  * Zicsr: six CSR access instructions.
  * M-mode privileged: @MRET@ (trap return). @WFI@ is not
    implemented yet — in phase 1 it decodes as an illegal
    instruction and traps like any other.
-}
module Riski5.ISA (
  -- * Registers
  Reg (..),
  x0,
  x1,
  x2,
  x3,
  x4,
  x5,
  x6,
  x7,
  x8,
  x9,
  x10,
  x11,
  x12,
  x13,
  x14,
  x15,
  x16,
  x17,
  x18,
  x19,
  x20,
  x21,
  x22,
  x23,
  x24,
  x25,
  x26,
  x27,
  x28,
  x29,
  x30,
  x31,

  -- ** ABI-name synonyms
  zero,
  ra,
  sp,
  gp,
  tp,
  t0,
  t1,
  t2,
  fp,
  s0,
  s1,
  a0,
  a1,
  a2,
  a3,
  a4,
  a5,
  a6,
  a7,
  s2,
  s3,
  s4,
  s5,
  s6,
  s7,
  s8,
  s9,
  s10,
  s11,
  t3,
  t4,
  t5,
  t6,

  -- * CSRs
  Csr (..),
  csrMstatus,
  csrMisa,
  csrMie,
  csrMtvec,
  csrMscratch,
  csrMepc,
  csrMcause,
  csrMtval,
  csrMip,
  csrMhartid,
  csrMcycle,
  csrMinstret,
  csrMcycleh,
  csrMinstreth,

  -- * Major opcodes
  Opcode (..),
  opcodeBits,

  -- * Instructions
  Instr (..),
) where

import Clash.Prelude

{- | A RISC-V integer register index, 5 bits wide (x0..x31).
@x0@ is hard-wired to zero in the architecture, handled in 'Riski5.Regfile'.
-}
newtype Reg = Reg {unReg :: BitVector 5}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (NFDataX, BitPack)

x0, x1, x2, x3, x4, x5, x6, x7 :: Reg
x0 = Reg 0
x1 = Reg 1
x2 = Reg 2
x3 = Reg 3
x4 = Reg 4
x5 = Reg 5
x6 = Reg 6
x7 = Reg 7

x8, x9, x10, x11, x12, x13, x14, x15 :: Reg
x8 = Reg 8
x9 = Reg 9
x10 = Reg 10
x11 = Reg 11
x12 = Reg 12
x13 = Reg 13
x14 = Reg 14
x15 = Reg 15

x16, x17, x18, x19, x20, x21, x22, x23 :: Reg
x16 = Reg 16
x17 = Reg 17
x18 = Reg 18
x19 = Reg 19
x20 = Reg 20
x21 = Reg 21
x22 = Reg 22
x23 = Reg 23

x24, x25, x26, x27, x28, x29, x30, x31 :: Reg
x24 = Reg 24
x25 = Reg 25
x26 = Reg 26
x27 = Reg 27
x28 = Reg 28
x29 = Reg 29
x30 = Reg 30
x31 = Reg 31

-- ABI-name synonyms (RISC-V calling convention).
zero, ra, sp, gp, tp, t0, t1, t2 :: Reg
zero = x0
ra = x1
sp = x2
gp = x3
tp = x4
t0 = x5
t1 = x6
t2 = x7

-- @fp@ and @s0@ alias the same physical register — distinguished only
-- by whether the caller treats it as a frame pointer or a saved
-- register.
fp, s0, s1 :: Reg
fp = x8
s0 = x8
s1 = x9

a0, a1, a2, a3, a4, a5, a6, a7 :: Reg
a0 = x10
a1 = x11
a2 = x12
a3 = x13
a4 = x14
a5 = x15
a6 = x16
a7 = x17

s2, s3, s4, s5, s6, s7, s8, s9, s10, s11 :: Reg
s2 = x18
s3 = x19
s4 = x20
s5 = x21
s6 = x22
s7 = x23
s8 = x24
s9 = x25
s10 = x26
s11 = x27

t3, t4, t5, t6 :: Reg
t3 = x28
t4 = x29
t5 = x30
t6 = x31

-- | A CSR address, 12 bits wide. Known addresses provided as constants.
newtype Csr = Csr {unCsr :: BitVector 12}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (NFDataX, BitPack)

-- Machine-mode CSRs used by riski5's minimal CSR file. Addresses follow
-- the RISC-V Privileged Architecture spec; the naming of each constant
-- matches the spec (minus the @csr@ prefix we add to avoid colliding
-- with Haskell reserved-ish identifiers).
csrMstatus
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
  , csrMinstreth ::
    Csr
csrMstatus = Csr 0x300
csrMisa = Csr 0x301
csrMie = Csr 0x304
csrMtvec = Csr 0x305
csrMscratch = Csr 0x340
csrMepc = Csr 0x341
csrMcause = Csr 0x342
csrMtval = Csr 0x343
csrMip = Csr 0x344
csrMhartid = Csr 0xF14
csrMcycle = Csr 0xB00
csrMinstret = Csr 0xB02
csrMcycleh = Csr 0xB80
csrMinstreth = Csr 0xB82

{- | The seven base integer major opcodes, plus MISC-MEM and SYSTEM.
The bottom two bits are always @11@ for uncompressed (32-bit)
instructions; this enumeration covers every 7-bit group riski5
supports.
-}
data Opcode
  = -- | @0000011@ - LB / LH / LW / LBU / LHU
    OpLoad
  | -- | @0001111@ - FENCE / FENCE.I
    OpMiscMem
  | -- | @0010011@ - arithmetic with immediate
    OpOpImm
  | -- | @0010111@ - AUIPC
    OpAuipc
  | -- | @0100011@ - SB / SH / SW
    OpStore
  | -- | @0110011@ - register-register arithmetic
    OpOp
  | -- | @0110111@ - LUI
    OpLui
  | -- | @1100011@ - conditional branches
    OpBranch
  | -- | @1100111@ - JALR
    OpJalr
  | -- | @1101111@ - JAL
    OpJal
  | -- | @1110011@ - ECALL / EBREAK / CSR / MRET
    OpSystem
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (NFDataX)

-- | Concrete 7-bit encoding of each 'Opcode'.
opcodeBits :: Opcode -> BitVector 7
opcodeBits = \case
  OpLoad -> 0b000_0011
  OpMiscMem -> 0b000_1111
  OpOpImm -> 0b001_0011
  OpAuipc -> 0b001_0111
  OpStore -> 0b010_0011
  OpOp -> 0b011_0011
  OpLui -> 0b011_0111
  OpBranch -> 0b110_0011
  OpJalr -> 0b110_0111
  OpJal -> 0b110_1111
  OpSystem -> 0b111_0011

{- | A single RV32I + Zicsr + Zifencei + M-mode instruction.

One constructor per mnemonic; each carries the fields its format
requires. Immediates are width-indexed so illegal widths cannot be
constructed (e.g. a 20-bit U-type immediate is a 'BitVector' 20,
not an 'Int'). The assembler eDSL 'Riski5.Asm' provides
pseudo-instruction sugar on top of this alphabet.
-}
data Instr
  = -- U-type
    Lui Reg (BitVector 20)
  | Auipc Reg (BitVector 20)
  | -- J-type
    Jal Reg (Signed 21)
  | -- I-type (jumps, loads, immediates)
    Jalr Reg Reg (Signed 12)
  | Lb Reg Reg (Signed 12)
  | Lh Reg Reg (Signed 12)
  | Lw Reg Reg (Signed 12)
  | Lbu Reg Reg (Signed 12)
  | Lhu Reg Reg (Signed 12)
  | Addi Reg Reg (Signed 12)
  | Slti Reg Reg (Signed 12)
  | Sltiu Reg Reg (Signed 12)
  | Xori Reg Reg (Signed 12)
  | Ori Reg Reg (Signed 12)
  | Andi Reg Reg (Signed 12)
  | -- I-type shifts: 5-bit unsigned shamt
    Slli Reg Reg (BitVector 5)
  | Srli Reg Reg (BitVector 5)
  | Srai Reg Reg (BitVector 5)
  | -- S-type (stores)
    Sb Reg Reg (Signed 12)
  | Sh Reg Reg (Signed 12)
  | Sw Reg Reg (Signed 12)
  | -- B-type (branches; immediates are in bytes but always even, so the
    -- LSB is implicit zero and the field is 13 bits wide)
    Beq Reg Reg (Signed 13)
  | Bne Reg Reg (Signed 13)
  | Blt Reg Reg (Signed 13)
  | Bge Reg Reg (Signed 13)
  | Bltu Reg Reg (Signed 13)
  | Bgeu Reg Reg (Signed 13)
  | -- R-type (register-register arithmetic)
    Add Reg Reg Reg
  | Sub Reg Reg Reg
  | Sll Reg Reg Reg
  | Slt Reg Reg Reg
  | Sltu Reg Reg Reg
  | Xor Reg Reg Reg
  | Srl Reg Reg Reg
  | Sra Reg Reg Reg
  | Or Reg Reg Reg
  | And Reg Reg Reg
  | -- MISC-MEM

    -- | @FENCE pred succ@; rd/rs1 and @fm@ are 0 for the non-TSO form.
    Fence (BitVector 4) (BitVector 4)
  | FenceI
  | -- SYSTEM: environment / trap return
    Ecall
  | Ebreak
  | Mret
  | -- SYSTEM: Zicsr. Register-source forms.
    Csrrw Reg Reg Csr
  | Csrrs Reg Reg Csr
  | Csrrc Reg Reg Csr
  | -- SYSTEM: Zicsr. Immediate-source forms carry a 5-bit unsigned
    -- immediate in place of @rs1@.
    Csrrwi Reg (BitVector 5) Csr
  | Csrrsi Reg (BitVector 5) Csr
  | Csrrci Reg (BitVector 5) Csr
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)
