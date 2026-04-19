-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Riski5.Core
Description : Pipelineless single-cycle RV32I core (no CSR yet).

One instruction retires per clock. The fetch path absorbs a
1-cycle latency (PC latched at cycle N−1 → instruction arrives at
cycle N); everything else — register read, ALU, branch comparator,
memory-access issue, writeback — is combinational within the
cycle. Writes to the register file and data memory take effect on
the following clock edge.

The core's outside-world interface is deliberately tiny: an imem
port that returns a 32-bit instruction for the current PC, a dmem
port that takes an address / byte-enable / read-enable and returns
read data, and that's it. The SoC module ('Riski5.Soc', coming in
T14) wires those up to BRAM / JTAG UART / GPIO / LCD / SRAM / SDRAM
via the bus decoder.

Phase-1 omissions (tracked in @TODO.md@):

  * No CSR file. CSRRW/CSRRS/CSRRC/CSRRWI/CSRRSI/CSRRCI + MRET
    currently behave as NOPs that advance PC. ECALL/EBREAK/
    illegal-instruction also just advance PC for now. T12 replaces
    all of these with real trap semantics.
  * No RVFI output ports yet. The hooks get added in the T11
    verilambda whole-core simulation or earlier if convenient; the
    formal-verification harness (T-whenever) then turns them on.
-}
module Riski5.Core (
  core,
) where

import Clash.Prelude hiding (And, Xor, (!!))
import Riski5.ALU (AluOp (..), BranchOp (..), alu, branchTaken)
import Riski5.Decode (decode)
import Riski5.ISA
import Riski5.Regfile (regfile)

{- |
Top-level core entity. Inputs are the instruction word at the
current PC and the data-memory read response; outputs are the
addresses, write data, and enable signals the memory subsystem
needs. Writes to dmem commit on the next clock edge; reads are
assumed to be combinational (async) — the SoC layer wraps
synchronous block RAMs with a one-cycle delay if needed.
-}
core ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  -- | instruction word at the current PC (assumed same-cycle read)
  Signal dom (BitVector 32) ->
  -- | data memory read response (assumed same-cycle read)
  Signal dom (BitVector 32) ->
  -- | @(pc, dmemAddr, dmemWdata, dmemByteEn, dmemReadEn)@
  ( Signal dom (BitVector 32) -- current PC, drives imem addr
  , Signal dom (BitVector 32) -- dmem address
  , Signal dom (BitVector 32) -- dmem write data
  , Signal dom (BitVector 4) -- per-byte write-enable (0 = no write)
  , Signal dom Bool -- read enable
  )
core imemData dmemRData =
  (pc, dmemAddr, dmemWdata, dmemBe, dmemRen)
 where
  -- ----- PC ---------------------------------------------------------
  pc :: Signal dom (BitVector 32)
  pc = register 0 pcNext

  -- ----- Decode + operand extraction --------------------------------
  mInstr :: Signal dom (Maybe Instr)
  mInstr = decode <$> imemData

  rs1Addr, rs2Addr :: Signal dom (BitVector 5)
  rs1Addr = slice d19 d15 <$> imemData
  rs2Addr = slice d24 d20 <$> imemData

  (rs1V, rs2V) = regfile rs1Addr rs2Addr writeBack

  -- ----- Combinational dispatch -------------------------------------
  -- handleInstr is a pure function from (pc, instr, rs1V, rs2V,
  -- dmemReadData) to the full output bundle. Keeping the entire
  -- control path in one function avoids scattered let-bindings and
  -- makes Hedgehog / verilambda diffing straightforward.
  bundledOut = handleInstr <$> pc <*> mInstr <*> rs1V <*> rs2V <*> dmemRData

  (pcNext, dmemAddr, dmemWdata, dmemBe, dmemRen, writeBack) =
    unbundle bundledOut

{- | Per-cycle combinational behaviour: given the current PC, decoded
instruction, source-register values, and dmem read data, produce
the next PC, memory-interface signals, and regfile write.
-}
handleInstr ::
  BitVector 32 ->
  Maybe Instr ->
  BitVector 32 ->
  BitVector 32 ->
  BitVector 32 ->
  ( BitVector 32 -- pcNext
  , BitVector 32 -- dmemAddr
  , BitVector 32 -- dmemWdata
  , BitVector 4 -- dmemByteEn (0 = no write this cycle)
  , Bool -- dmemReadEn
  , Maybe (BitVector 5, BitVector 32) -- regfile writeback
  )
handleInstr pc Nothing _ _ _ =
  -- Illegal instruction. Until T12 adds trap semantics, just advance.
  (pc + 4, 0, 0, 0, False, Nothing)
handleInstr pc (Just instr) rs1V rs2V memRData = case instr of
  -- ----- U-type ---------------------------------------------------
  Lui rd imm ->
    let res = imm ++# (0 :: BitVector 12)
     in regWb rd res (pc + 4)
  Auipc rd imm ->
    let res = pc + (imm ++# (0 :: BitVector 12))
     in regWb rd res (pc + 4)
  -- ----- J-type (JAL) --------------------------------------------
  Jal rd off ->
    let target = pc + sxImm21 off
     in regWb rd (pc + 4) target
  -- ----- I-type: JALR --------------------------------------------
  Jalr rd _ off ->
    let target = (rs1V + sxImm12 off) .&. complement 1
     in regWb rd (pc + 4) target
  -- ----- I-type: loads -------------------------------------------
  Lb rd _ off -> doLoad rd off 1 True rs1V memRData pc
  Lh rd _ off -> doLoad rd off 2 True rs1V memRData pc
  Lw rd _ off -> doLoad rd off 4 False rs1V memRData pc
  Lbu rd _ off -> doLoad rd off 1 False rs1V memRData pc
  Lhu rd _ off -> doLoad rd off 2 False rs1V memRData pc
  -- ----- I-type: arithmetic / logical imms -----------------------
  Addi rd _ imm -> aluImm rd AluAdd rs1V imm pc
  Slti rd _ imm -> aluImm rd AluSlt rs1V imm pc
  Sltiu rd _ imm -> aluImm rd AluSltu rs1V imm pc
  Xori rd _ imm -> aluImm rd AluXor rs1V imm pc
  Ori rd _ imm -> aluImm rd AluOr rs1V imm pc
  Andi rd _ imm -> aluImm rd AluAnd rs1V imm pc
  Slli rd _ shamt -> aluShamt rd AluSll rs1V shamt pc
  Srli rd _ shamt -> aluShamt rd AluSrl rs1V shamt pc
  Srai rd _ shamt -> aluShamt rd AluSra rs1V shamt pc
  -- ----- S-type: stores ------------------------------------------
  Sb _ _ off -> doStore off rs1V rs2V 1 pc
  Sh _ _ off -> doStore off rs1V rs2V 2 pc
  Sw _ _ off -> doStore off rs1V rs2V 4 pc
  -- ----- B-type: branches ---------------------------------------
  Beq _ _ off -> doBranch BrEq rs1V rs2V off pc
  Bne _ _ off -> doBranch BrNe rs1V rs2V off pc
  Blt _ _ off -> doBranch BrLt rs1V rs2V off pc
  Bge _ _ off -> doBranch BrGe rs1V rs2V off pc
  Bltu _ _ off -> doBranch BrLtu rs1V rs2V off pc
  Bgeu _ _ off -> doBranch BrGeu rs1V rs2V off pc
  -- ----- R-type --------------------------------------------------
  Add rd _ _ -> aluReg rd AluAdd rs1V rs2V pc
  Sub rd _ _ -> aluReg rd AluSub rs1V rs2V pc
  Sll rd _ _ -> aluReg rd AluSll rs1V rs2V pc
  Slt rd _ _ -> aluReg rd AluSlt rs1V rs2V pc
  Sltu rd _ _ -> aluReg rd AluSltu rs1V rs2V pc
  Xor rd _ _ -> aluReg rd AluXor rs1V rs2V pc
  Srl rd _ _ -> aluReg rd AluSrl rs1V rs2V pc
  Sra rd _ _ -> aluReg rd AluSra rs1V rs2V pc
  Or rd _ _ -> aluReg rd AluOr rs1V rs2V pc
  And rd _ _ -> aluReg rd AluAnd rs1V rs2V pc
  -- ----- MISC-MEM (FENCE as no-op until we have caches) ----------
  Fence _ _ -> nop pc
  FenceI -> nop pc
  -- ----- SYSTEM: traps/CSRs — stubs until T12 --------------------
  Ecall -> nop pc
  Ebreak -> nop pc
  Mret -> nop pc
  Csrrw {} -> nop pc
  Csrrs {} -> nop pc
  Csrrc {} -> nop pc
  Csrrwi {} -> nop pc
  Csrrsi {} -> nop pc
  Csrrci {} -> nop pc

-- * Pure helper outputs ---------------------------------------------

type Out =
  ( BitVector 32
  , BitVector 32
  , BitVector 32
  , BitVector 4
  , Bool
  , Maybe (BitVector 5, BitVector 32)
  )

-- | PC advances by 4; no memory access, no regfile write.
nop :: BitVector 32 -> Out
nop p = (p + 4, 0, 0, 0, False, Nothing)

-- | Register writeback (and optionally a non-sequential PC).
regWb :: Reg -> BitVector 32 -> BitVector 32 -> Out
regWb rd val nextPc = (nextPc, 0, 0, 0, False, Just (unReg rd, val))

aluImm :: Reg -> AluOp -> BitVector 32 -> Signed 12 -> BitVector 32 -> Out
aluImm rd op rs1V imm p = regWb rd (alu op rs1V (sxImm12 imm)) (p + 4)

aluShamt :: Reg -> AluOp -> BitVector 32 -> BitVector 5 -> BitVector 32 -> Out
aluShamt rd op rs1V shamt p = regWb rd (alu op rs1V (zeroExtend shamt)) (p + 4)

aluReg :: Reg -> AluOp -> BitVector 32 -> BitVector 32 -> BitVector 32 -> Out
aluReg rd op a b p = regWb rd (alu op a b) (p + 4)

{- | Load: address = rs1 + sign-extended offset; assert read enable;
writeback the extracted + sign-extended load data into @rd@.
-}
doLoad ::
  Reg ->
  Signed 12 ->
  Int ->
  Bool ->
  BitVector 32 ->
  BitVector 32 ->
  BitVector 32 ->
  Out
doLoad rd off width signed rs1 rdata p =
  let addr = rs1 + sxImm12 off
      loaded = extendLoad width signed addr rdata
   in (p + 4, addr, 0, 0, True, Just (unReg rd, loaded))

{- | Store: compute byte-lane address / byte-enable / store-data
alignment; PC advances sequentially.
-}
doStore ::
  Signed 12 ->
  BitVector 32 ->
  BitVector 32 ->
  Int ->
  BitVector 32 ->
  Out
doStore off base value width p =
  let addr = base + sxImm12 off
      be = byteEnable width addr
      wdata = shiftStoreData width addr value
   in (p + 4, addr, wdata, be, False, Nothing)

-- | Branch: take it (PC ← PC + off) iff the comparator says so.
doBranch ::
  BranchOp ->
  BitVector 32 ->
  BitVector 32 ->
  Signed 13 ->
  BitVector 32 ->
  Out
doBranch op a b off p =
  let taken = branchTaken op a b
      target = p + sxImm13 off
   in ( if taken then target else p + 4
      , 0
      , 0
      , 0
      , False
      , Nothing
      )

-- * Immediate helpers ----------------------------------------------

sxImm12 :: Signed 12 -> BitVector 32
sxImm12 = pack . (resize :: Signed 12 -> Signed 32)

sxImm13 :: Signed 13 -> BitVector 32
sxImm13 = pack . (resize :: Signed 13 -> Signed 32)

sxImm21 :: Signed 21 -> BitVector 32
sxImm21 = pack . (resize :: Signed 21 -> Signed 32)

{- |
Extract and sign-extend the loaded byte/half/word from the 32-bit
memory read response. Assumes aligned accesses; misalignment handling
lives in T12 alongside the other trap logic.
-}
extendLoad :: Int -> Bool -> BitVector 32 -> BitVector 32 -> BitVector 32
extendLoad width signed addr rdata = case (width, signed) of
  (4, _) -> rdata
  (2, True) -> pack (signExtendTo32 16 half)
  (2, False) -> resize half
  (1, True) -> pack (signExtendTo32 8 byte)
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

-- | Sign-extend a k-bit value (passed as a 'BitVector') to 32 bits.
signExtendTo32 :: forall n. (KnownNat n) => Int -> BitVector n -> Signed 32
signExtendTo32 _ v = resize (unpack v :: Signed n)

{- | Per-byte write-enable: 4 bits, one per byte lane. Alignment
assumption matches 'extendLoad'.
-}
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
