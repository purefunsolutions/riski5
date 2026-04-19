-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Riski5.Core
Description : Pipelineless single-cycle RV32I core with M-mode CSRs + traps.

One instruction retires per clock. The fetch path absorbs a
1-cycle latency (PC latched at cycle N−1 → instruction arrives at
cycle N); everything else — register read, ALU, branch comparator,
CSR access, memory-access issue, writeback, trap latch — is
combinational within the cycle. Writes to the register file, CSR
file, and data memory take effect on the following clock edge.

The core's outside-world interface is deliberately tiny: an imem
port that returns a 32-bit instruction for the current PC, a dmem
port that takes an address / byte-enable / read-enable and returns
read data, plus an observability output for the regfile writeback
stream (ignored by real SoC tops). CSR state is fully internal.

Trap handling, per the RISC-V priv spec (M-mode only):

  * Illegal instruction: @mcause = 2@, @mtval = instruction bits@.
  * Environment call from M-mode (ECALL): @mcause = 11@, @mtval = 0@.
  * Breakpoint (EBREAK): @mcause = 3@, @mtval = 0@.
  * Load / store address misaligned: @mcause = 4@ / @6@,
    @mtval = faulting address@.

On any trap: @mepc = pc@, @pc ← mtvec.base@, no regfile writeback,
no data-memory write. @MRET@ copies @mepc@ back into @pc@ (no
privilege-mode switch — there's only M-mode). No xIE/xPIE dance
yet; interrupts arrive with 'Riski5.CSR' growth in a later phase.
-}
module Riski5.Core (
  core,
) where

import Clash.Prelude hiding (And, Xor, not, (!!))
import Riski5.ALU (AluOp (..), BranchOp (..), alu, branchTaken)
import Riski5.CSR (
  Csrs (..),
  applyTrap,
  causeBreakpoint,
  causeEcallFromM,
  causeIllegalInstr,
  causeLoadAddrMisaligned,
  causeStoreAddrMisaligned,
  initCsrs,
  readCsr,
  writeCsr,
 )
import Riski5.Decode (decode)
import Riski5.ISA
import Riski5.Regfile (regfile)

{- |
Top-level core entity. Inputs are the instruction word at the
current PC and the data-memory read response; outputs are the
addresses, write data, and enable signals the memory subsystem
needs plus the observability write-back stream. CSR state is
internal and doesn't leak through the interface.
-}
core ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  -- | instruction word at the current PC (assumed same-cycle read)
  Signal dom (BitVector 32) ->
  -- | data memory read response (assumed same-cycle read)
  Signal dom (BitVector 32) ->
  {- | @(pc, dmemAddr, dmemWdata, dmemByteEn, dmemReadEn, writeBack)@.
  @writeBack@ is @Just (rd, value)@ on cycles that commit a
  register-file write, @Nothing@ otherwise (and always @Nothing@ on
  a trap cycle).
  -}
  ( Signal dom (BitVector 32) -- current PC, drives imem addr
  , Signal dom (BitVector 32) -- dmem address
  , Signal dom (BitVector 32) -- dmem write data
  , Signal dom (BitVector 4) -- per-byte write-enable (0 = no write)
  , Signal dom Bool -- read enable
  , Signal dom (Maybe (BitVector 5, BitVector 32)) -- regfile write
  )
core imemData dmemRData =
  (pc, dmemAddr, dmemWdata, dmemBe, dmemRen, writeBack)
 where
  -- ----- PC + CSR state ---------------------------------------------
  pc :: Signal dom (BitVector 32)
  pc = register 0 pcNext

  csrs :: Signal dom Csrs
  csrs = register initCsrs csrsNext

  -- ----- Decode + operand extraction --------------------------------
  mInstr :: Signal dom (Maybe Instr)
  mInstr = decode <$> imemData

  rs1Addr, rs2Addr :: Signal dom (BitVector 5)
  rs1Addr = slice d19 d15 <$> imemData
  rs2Addr = slice d24 d20 <$> imemData

  (rs1V, rs2V) = regfile rs1Addr rs2Addr writeBack

  -- ----- Combinational dispatch -------------------------------------
  bundledOut =
    handleInstr
      <$> pc
      <*> imemData
      <*> mInstr
      <*> rs1V
      <*> rs2V
      <*> dmemRData
      <*> csrs

  (pcNext, csrsNext, dmemAddr, dmemWdata, dmemBe, dmemRen, writeBack) =
    unbundle bundledOut

-- * Combinational dispatch -----------------------------------------

{- |
Per-cycle output bundle. @pcNext@ and @csrsNext@ feed the core's
two sequential registers; the remaining five signals drive memory
and the regfile write port (consumed by 'Riski5.Regfile.regfile').
-}
type Out =
  ( BitVector 32 -- pcNext
  , Csrs -- csrsNext
  , BitVector 32 -- dmemAddr
  , BitVector 32 -- dmemWdata
  , BitVector 4 -- dmemByteEn (0 = no write)
  , Bool -- dmemReadEn
  , Maybe (BitVector 5, BitVector 32) -- regfile writeback
  )

{- |
Per-cycle combinational behaviour. Threaded CSR state makes every
branch pure, which keeps this function straightforwardly diffable
against 'Riski5.Reference' and easy to Hedgehog against.
-}
handleInstr ::
  BitVector 32 ->
  BitVector 32 -> -- raw instruction word (for mtval on illegal)
  Maybe Instr ->
  BitVector 32 ->
  BitVector 32 ->
  BitVector 32 ->
  Csrs ->
  Out
handleInstr pc rawInstr Nothing _ _ _ cs =
  -- Illegal instruction → trap.
  trap causeIllegalInstr pc rawInstr cs
handleInstr pc _ (Just instr) rs1V rs2V memRData cs = case instr of
  -- ----- U-type ---------------------------------------------------
  Lui rd imm ->
    let res = imm ++# (0 :: BitVector 12)
     in regWb cs rd res (pc + 4)
  Auipc rd imm ->
    let res = pc + (imm ++# (0 :: BitVector 12))
     in regWb cs rd res (pc + 4)
  -- ----- J-type (JAL) --------------------------------------------
  Jal rd off ->
    let target = pc + sxImm21 off
     in regWb cs rd (pc + 4) target
  -- ----- I-type: JALR --------------------------------------------
  Jalr rd _ off ->
    let target = (rs1V + sxImm12 off) .&. complement 1
     in regWb cs rd (pc + 4) target
  -- ----- I-type: loads -------------------------------------------
  Lb rd _ off -> doLoad cs rd off 1 True rs1V memRData pc
  Lh rd _ off -> doLoad cs rd off 2 True rs1V memRData pc
  Lw rd _ off -> doLoad cs rd off 4 False rs1V memRData pc
  Lbu rd _ off -> doLoad cs rd off 1 False rs1V memRData pc
  Lhu rd _ off -> doLoad cs rd off 2 False rs1V memRData pc
  -- ----- I-type: arithmetic / logical imms -----------------------
  Addi rd _ imm -> aluImm cs rd AluAdd rs1V imm pc
  Slti rd _ imm -> aluImm cs rd AluSlt rs1V imm pc
  Sltiu rd _ imm -> aluImm cs rd AluSltu rs1V imm pc
  Xori rd _ imm -> aluImm cs rd AluXor rs1V imm pc
  Ori rd _ imm -> aluImm cs rd AluOr rs1V imm pc
  Andi rd _ imm -> aluImm cs rd AluAnd rs1V imm pc
  Slli rd _ shamt -> aluShamt cs rd AluSll rs1V shamt pc
  Srli rd _ shamt -> aluShamt cs rd AluSrl rs1V shamt pc
  Srai rd _ shamt -> aluShamt cs rd AluSra rs1V shamt pc
  -- ----- S-type: stores ------------------------------------------
  Sb _ _ off -> doStore cs off rs1V rs2V 1 pc
  Sh _ _ off -> doStore cs off rs1V rs2V 2 pc
  Sw _ _ off -> doStore cs off rs1V rs2V 4 pc
  -- ----- B-type: branches ---------------------------------------
  Beq _ _ off -> doBranch cs BrEq rs1V rs2V off pc
  Bne _ _ off -> doBranch cs BrNe rs1V rs2V off pc
  Blt _ _ off -> doBranch cs BrLt rs1V rs2V off pc
  Bge _ _ off -> doBranch cs BrGe rs1V rs2V off pc
  Bltu _ _ off -> doBranch cs BrLtu rs1V rs2V off pc
  Bgeu _ _ off -> doBranch cs BrGeu rs1V rs2V off pc
  -- ----- R-type --------------------------------------------------
  Add rd _ _ -> aluReg cs rd AluAdd rs1V rs2V pc
  Sub rd _ _ -> aluReg cs rd AluSub rs1V rs2V pc
  Sll rd _ _ -> aluReg cs rd AluSll rs1V rs2V pc
  Slt rd _ _ -> aluReg cs rd AluSlt rs1V rs2V pc
  Sltu rd _ _ -> aluReg cs rd AluSltu rs1V rs2V pc
  Xor rd _ _ -> aluReg cs rd AluXor rs1V rs2V pc
  Srl rd _ _ -> aluReg cs rd AluSrl rs1V rs2V pc
  Sra rd _ _ -> aluReg cs rd AluSra rs1V rs2V pc
  Or rd _ _ -> aluReg cs rd AluOr rs1V rs2V pc
  And rd _ _ -> aluReg cs rd AluAnd rs1V rs2V pc
  -- ----- MISC-MEM (FENCE as no-op until we have caches) ----------
  Fence _ _ -> nop cs pc
  FenceI -> nop cs pc
  -- ----- SYSTEM: environment / trap-return -----------------------
  Ecall -> trap causeEcallFromM pc 0 cs
  Ebreak -> trap causeBreakpoint pc 0 cs
  Mret ->
    -- Return to the saved pc (no xIE/xPIE dance yet — we don't have
    -- interrupt enables to juggle).
    (cMepc cs, cs, 0, 0, 0, False, Nothing)
  -- ----- SYSTEM: Zicsr — register-source forms -------------------
  Csrrw rd _ csr ->
    let addr = unCsr csr
        old = readCsr cs addr
        new = rs1V
        cs' = writeCsr addr new cs
     in regWb cs' rd old (pc + 4)
  Csrrs rd _ csr ->
    let addr = unCsr csr
        old = readCsr cs addr
        new = old .|. rs1V
        cs' = writeCsr addr new cs
     in regWb cs' rd old (pc + 4)
  Csrrc rd _ csr ->
    let addr = unCsr csr
        old = readCsr cs addr
        new = old .&. complement rs1V
        cs' = writeCsr addr new cs
     in regWb cs' rd old (pc + 4)
  -- ----- SYSTEM: Zicsr — immediate-source forms ------------------
  Csrrwi rd zimm csr ->
    let addr = unCsr csr
        old = readCsr cs addr
        new = zeroExtend zimm
        cs' = writeCsr addr new cs
     in regWb cs' rd old (pc + 4)
  Csrrsi rd zimm csr ->
    let addr = unCsr csr
        old = readCsr cs addr
        new = old .|. zeroExtend zimm
        cs' = writeCsr addr new cs
     in regWb cs' rd old (pc + 4)
  Csrrci rd zimm csr ->
    let addr = unCsr csr
        old = readCsr cs addr
        new = old .&. complement (zeroExtend zimm)
        cs' = writeCsr addr new cs
     in regWb cs' rd old (pc + 4)

-- * Pure helper outputs ---------------------------------------------

-- | PC advances by 4; no memory access, no regfile write, CSR unchanged.
nop :: Csrs -> BitVector 32 -> Out
nop cs p = (p + 4, cs, 0, 0, 0, False, Nothing)

-- | Register writeback (and optionally a non-sequential PC); CSR unchanged.
regWb :: Csrs -> Reg -> BitVector 32 -> BitVector 32 -> Out
regWb cs rd val nextPc =
  (nextPc, cs, 0, 0, 0, False, Just (unReg rd, val))

aluImm :: Csrs -> Reg -> AluOp -> BitVector 32 -> Signed 12 -> BitVector 32 -> Out
aluImm cs rd op rs1V imm p = regWb cs rd (alu op rs1V (sxImm12 imm)) (p + 4)

aluShamt :: Csrs -> Reg -> AluOp -> BitVector 32 -> BitVector 5 -> BitVector 32 -> Out
aluShamt cs rd op rs1V shamt p = regWb cs rd (alu op rs1V (zeroExtend shamt)) (p + 4)

aluReg :: Csrs -> Reg -> AluOp -> BitVector 32 -> BitVector 32 -> BitVector 32 -> Out
aluReg cs rd op a b p = regWb cs rd (alu op a b) (p + 4)

{- |
Load: traps on misaligned access (load-addr-misaligned, cause 4);
otherwise writes back the extracted + sign-extended load data.
-}
doLoad ::
  Csrs ->
  Reg ->
  Signed 12 ->
  Int ->
  Bool ->
  BitVector 32 ->
  BitVector 32 ->
  BitVector 32 ->
  Out
doLoad cs rd off width signed rs1 rdata p =
  let addr = rs1 + sxImm12 off
      aligned = case width of
        1 -> True
        2 -> slice d0 d0 addr == 0
        4 -> slice d1 d0 addr == 0
        _ -> True
   in if not aligned
        then trap causeLoadAddrMisaligned p addr cs
        else
          let loaded = extendLoad width signed addr rdata
           in (p + 4, cs, addr, 0, 0, True, Just (unReg rd, loaded))

{- |
Store: traps on misaligned access; otherwise issues the write to
dmem with the byte-enable for the requested width / alignment.
-}
doStore ::
  Csrs ->
  Signed 12 ->
  BitVector 32 ->
  BitVector 32 ->
  Int ->
  BitVector 32 ->
  Out
doStore cs off base value width p =
  let addr = base + sxImm12 off
      aligned = case width of
        1 -> True
        2 -> slice d0 d0 addr == 0
        4 -> slice d1 d0 addr == 0
        _ -> True
   in if not aligned
        then trap causeStoreAddrMisaligned p addr cs
        else
          let be = byteEnable width addr
              wdata = shiftStoreData width addr value
           in (p + 4, cs, addr, wdata, be, False, Nothing)

-- | Branch: take it (PC ← PC + off) iff the comparator says so.
doBranch ::
  Csrs ->
  BranchOp ->
  BitVector 32 ->
  BitVector 32 ->
  Signed 13 ->
  BitVector 32 ->
  Out
doBranch cs op a b off p =
  let taken = branchTaken op a b
      target = p + sxImm13 off
      pcNext = if taken then target else p + 4
   in (pcNext, cs, 0, 0, 0, False, Nothing)

{- |
Latch a trap: record @mcause@ / @mepc@ / @mtval@ in the CSR file,
jump to @mtvec.base@ (bottom two bits cleared — direct mode).
No regfile writeback, no memory access.
-}
trap :: BitVector 32 -> BitVector 32 -> BitVector 32 -> Csrs -> Out
trap cause epc tval cs =
  let cs' = applyTrap cause epc tval cs
      target = cMtvec cs .&. complement 3
   in (target, cs', 0, 0, 0, False, Nothing)

-- * Load / store byte-lane helpers ---------------------------------

{- |
Extract and sign-extend the loaded byte/half/word from the 32-bit
memory read response. Assumes the aligned-access check in 'doLoad'
has already rejected misaligned addresses.
-}
extendLoad :: Int -> Bool -> BitVector 32 -> BitVector 32 -> BitVector 32
extendLoad width signed addr rdata = case (width, signed) of
  (4, _) -> rdata
  (2, True) -> pack (signExtendTo32 half)
  (2, False) -> resize half
  (1, True) -> pack (signExtendTo32 byte)
  (1, False) -> resize byte
  _ -> 0
 where
  byte :: BitVector 8
  byte = case slice d1 d0 addr of
    0 -> slice d7 d0 rdata
    1 -> slice d15 d8 rdata
    2 -> slice d23 d16 rdata
    _ -> slice d31 d24 rdata

  half :: BitVector 16
  half = case slice d1 d1 addr of
    0 -> slice d15 d0 rdata
    _ -> slice d31 d16 rdata

-- | Sign-extend an n-bit value to 32 bits.
signExtendTo32 :: forall n. (KnownNat n) => BitVector n -> Signed 32
signExtendTo32 v = resize (unpack v :: Signed n)

-- | Per-byte write-enable: 4 bits, one per byte lane.
byteEnable :: Int -> BitVector 32 -> BitVector 4
byteEnable width addr = case (width, slice d1 d0 addr) of
  (4, _) -> 0b1111
  (2, 0) -> 0b0011
  (2, _) -> 0b1100
  (1, 0) -> 0b0001
  (1, 1) -> 0b0010
  (1, 2) -> 0b0100
  (1, 3) -> 0b1000
  _ -> 0

{- | Shift a store's data into the correct byte lane(s) of the 32-bit
memory word.
-}
shiftStoreData :: Int -> BitVector 32 -> BitVector 32 -> BitVector 32
shiftStoreData width addr value = case (width, slice d1 d0 addr) of
  (4, _) -> value
  (2, 0) -> value
  (2, _) -> value `shiftL` 16
  (1, 0) -> value
  (1, 1) -> value `shiftL` 8
  (1, 2) -> value `shiftL` 16
  (1, 3) -> value `shiftL` 24
  _ -> value

-- * Immediate helpers ----------------------------------------------

sxImm12 :: Signed 12 -> BitVector 32
sxImm12 = pack . (resize :: Signed 12 -> Signed 32)

sxImm13 :: Signed 13 -> BitVector 32
sxImm13 = pack . (resize :: Signed 13 -> Signed 32)

sxImm21 :: Signed 21 -> BitVector 32
sxImm21 = pack . (resize :: Signed 21 -> Signed 32)
