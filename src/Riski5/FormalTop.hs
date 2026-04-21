-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Riski5.FormalTop
Description : Clash top entity for the YosysHQ\/riscv-formal harness.

Emits a Verilog module named @riski5_formal@ that exposes the
core with:

  * Flat memory ports (@imem_addr@, @imem_rdata@, @dmem_addr@,
    @dmem_rdata@, @dmem_wdata@, @dmem_wmask@, @dmem_ren@) — no
    SoC, no peripherals. The @cores\/riski5\/wrapper.sv@ module in
    riscv-formal ties these off via @rvformal_rand_reg@ so the
    harness drives them symbolically.

  * Flat @rvfi_\*@ observability ports. Names match the RVFI
    spec (@docs\/source\/rvfi.rst@) so the harness's
    @`RVFI_CONN32`@ macro connects them by name.

Uses the same 'Dom30' clock domain as the synthesis top (see
@app\/Top.hs@) — doesn't strictly matter for formal verification
(no period, async reset) but keeps the Clash generation
machinery happy. SymbiYosys doesn't care about the domain's
period constant; it only wires clk and rst_n.

The top entity is annotated via 'makeTopEntityWithName' to emit
a Verilog module literally named @riski5_formal@, with
port-name pragmas mapping each Haskell field to its RVFI
canonical name. That way the downstream wrapper.sv can use
@`RVFI_CONN32`@ without a per-signal-name translation table.
-}
module Riski5.FormalTop (
  formalTopEntity,
) where

import Clash.Annotations.TH (makeTopEntityWithName)
import Clash.Prelude
import Riski5.Core.Assembly (coreWith)
import Riski5.Core.Presets (tiny32M)
import Riski5.Rvfi (Rvfi (..), RvfiCsr (..))

-- * Clock domain ---------------------------------------------------

{- | Formal-verification clock domain. Same shape as the synthesis
'Top.Dom30' but defined here so this module doesn't pull in the
synthesis top. SymbiYosys treats the period as opaque — it only
reads the reset polarity and active-edge hints.
-}
createDomain
  vSystem
    { vName = "DomFormal"
    , vPeriod = 20000
    , vResetKind = Asynchronous
    , vResetPolarity = ActiveLow
    }

-- * Top entity -----------------------------------------------------

{- | Clash top entity for the riscv-formal harness.

Inputs: clk + reset + instruction word at current PC + data
memory read word.

Outputs: fetch/data-memory address and store-word/mask, plus the
flat RVFI observability signals.

riscv-formal's wrapper.sv will declare the inputs as
@rvformal_rand_reg@ (symbolic), connect the RVFI outputs via
@`RVFI_CONN32`@, and leave the address outputs unconnected
(the harness reasons over them but doesn't drive them back).
-}
formalTopEntity ::
  "clk" ::: Clock DomFormal ->
  "rst_n" ::: Reset DomFormal ->
  -- | instruction word at current @pcFetch@ (symbolic input)
  "imem_rdata" ::: Signal DomFormal (BitVector 32) ->
  -- | data-memory read data at @dmem_addr@ (symbolic input)
  "dmem_rdata" ::: Signal DomFormal (BitVector 32) ->
  ""
    ::: ( "imem_addr" ::: Signal DomFormal (BitVector 32)
        , "dmem_addr" ::: Signal DomFormal (BitVector 32)
        , "dmem_wdata" ::: Signal DomFormal (BitVector 32)
        , "dmem_wmask" ::: Signal DomFormal (BitVector 4)
        , "dmem_ren" ::: Signal DomFormal Bool
        , -- RVFI bundle — flat rvfi_* ports the harness reads.
          "rvfi_valid" ::: Signal DomFormal Bit
        , "rvfi_order" ::: Signal DomFormal (BitVector 64)
        , "rvfi_insn" ::: Signal DomFormal (BitVector 32)
        , "rvfi_trap" ::: Signal DomFormal Bit
        , "rvfi_halt" ::: Signal DomFormal Bit
        , "rvfi_intr" ::: Signal DomFormal Bit
        , "rvfi_mode" ::: Signal DomFormal (BitVector 2)
        , "rvfi_ixl" ::: Signal DomFormal (BitVector 2)
        , "rvfi_rs1_addr" ::: Signal DomFormal (BitVector 5)
        , "rvfi_rs2_addr" ::: Signal DomFormal (BitVector 5)
        , "rvfi_rs1_rdata" ::: Signal DomFormal (BitVector 32)
        , "rvfi_rs2_rdata" ::: Signal DomFormal (BitVector 32)
        , "rvfi_rd_addr" ::: Signal DomFormal (BitVector 5)
        , "rvfi_rd_wdata" ::: Signal DomFormal (BitVector 32)
        , "rvfi_pc_rdata" ::: Signal DomFormal (BitVector 32)
        , "rvfi_pc_wdata" ::: Signal DomFormal (BitVector 32)
        , "rvfi_mem_addr" ::: Signal DomFormal (BitVector 32)
        , "rvfi_mem_rmask" ::: Signal DomFormal (BitVector 4)
        , "rvfi_mem_wmask" ::: Signal DomFormal (BitVector 4)
        , "rvfi_mem_rdata" ::: Signal DomFormal (BitVector 32)
        , "rvfi_mem_wdata" ::: Signal DomFormal (BitVector 32)
        , -- Zicsr extension: per-CSR RVFI observability. One
          -- @_rmask@ / @_wmask@ / @_rdata@ / @_wdata@ quartet
          -- per implemented CSR. The riscv-formal @csrw_*@ /
          -- @csrc_*_any@ checks consume these via the
          -- @`RVFI_CONN32`@ macro when the matching
          -- @RISCV_FORMAL_CSR_<NAME>@ define is set in
          -- @checks.cfg@.
          "rvfi_csr_mstatus_rmask" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mstatus_wmask" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mstatus_rdata" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mstatus_wdata" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mtvec_rmask" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mtvec_wmask" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mtvec_rdata" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mtvec_wdata" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mepc_rmask" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mepc_wmask" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mepc_rdata" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mepc_wdata" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mcause_rmask" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mcause_wmask" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mcause_rdata" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mcause_wdata" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mtval_rmask" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mtval_wmask" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mtval_rdata" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mtval_wdata" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mscratch_rmask" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mscratch_wmask" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mscratch_rdata" ::: Signal DomFormal (BitVector 32)
        , "rvfi_csr_mscratch_wdata" ::: Signal DomFormal (BitVector 32)
        )
formalTopEntity clk rst imemRdataS dmemRdataS =
  withClockResetEnable clk rst enableGen $
    let (pcFetchS, _pcExecS, dmemAddrS, dmemWdataS, dmemWmaskS, dmemRenS, _wbS, rvfiS) =
          coreWith tiny32M imemRdataS dmemRdataS (pure False)
     in ( pcFetchS -- imem_addr
        , dmemAddrS
        , dmemWdataS
        , dmemWmaskS
        , dmemRenS
        , -- Split 'rvfiS' into its flat fields.
          rfValid <$> rvfiS
        , rfOrder <$> rvfiS
        , rfInsn <$> rvfiS
        , rfTrap <$> rvfiS
        , rfHalt <$> rvfiS
        , rfIntr <$> rvfiS
        , rfMode <$> rvfiS
        , rfIxl <$> rvfiS
        , rfRs1Addr <$> rvfiS
        , rfRs2Addr <$> rvfiS
        , rfRs1Rdata <$> rvfiS
        , rfRs2Rdata <$> rvfiS
        , rfRdAddr <$> rvfiS
        , rfRdWdata <$> rvfiS
        , rfPcRdata <$> rvfiS
        , rfPcWdata <$> rvfiS
        , rfMemAddr <$> rvfiS
        , rfMemRmask <$> rvfiS
        , rfMemWmask <$> rvfiS
        , rfMemRdata <$> rvfiS
        , rfMemWdata <$> rvfiS
        , -- CSR quartets flattened out. One `<$>` chain per
          -- signal; Clash optimises out the shared @rvfiS@
          -- reads that remain after the record-projection
          -- simplifier runs.
          (rcRmask . rfCsrMstatus) <$> rvfiS
        , (rcWmask . rfCsrMstatus) <$> rvfiS
        , (rcRdata . rfCsrMstatus) <$> rvfiS
        , (rcWdata . rfCsrMstatus) <$> rvfiS
        , (rcRmask . rfCsrMtvec) <$> rvfiS
        , (rcWmask . rfCsrMtvec) <$> rvfiS
        , (rcRdata . rfCsrMtvec) <$> rvfiS
        , (rcWdata . rfCsrMtvec) <$> rvfiS
        , (rcRmask . rfCsrMepc) <$> rvfiS
        , (rcWmask . rfCsrMepc) <$> rvfiS
        , (rcRdata . rfCsrMepc) <$> rvfiS
        , (rcWdata . rfCsrMepc) <$> rvfiS
        , (rcRmask . rfCsrMcause) <$> rvfiS
        , (rcWmask . rfCsrMcause) <$> rvfiS
        , (rcRdata . rfCsrMcause) <$> rvfiS
        , (rcWdata . rfCsrMcause) <$> rvfiS
        , (rcRmask . rfCsrMtval) <$> rvfiS
        , (rcWmask . rfCsrMtval) <$> rvfiS
        , (rcRdata . rfCsrMtval) <$> rvfiS
        , (rcWdata . rfCsrMtval) <$> rvfiS
        , (rcRmask . rfCsrMscratch) <$> rvfiS
        , (rcWmask . rfCsrMscratch) <$> rvfiS
        , (rcRdata . rfCsrMscratch) <$> rvfiS
        , (rcWdata . rfCsrMscratch) <$> rvfiS
        )

{- | Clash annotation: emit a Verilog module named @riski5_formal@
from 'formalTopEntity'. Each input/output port carries the
port-name annotation above so the generated module matches what
the riscv-formal wrapper.sv expects.
-}
makeTopEntityWithName 'formalTopEntity "riski5_formal"
