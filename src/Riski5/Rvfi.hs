-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

{- |
Module      : Riski5.Rvfi
Description : RISC-V Formal Interface (RVFI) port record.

Observability bundle that
[YosysHQ/riscv-formal](https://github.com/YosysHQ/riscv-formal)
consumes to model-check the core against the ISA spec via
SymbiYosys. Every clock cycle the core fills in this record;
when @rfValid@ is high, the other fields describe the single
instruction that retired this cycle.

The port set matches @docs/source/rvfi.rst@ of @riscv-formal@ for
@NRET=1@, @XLEN=32@, @ILEN=32@ with @RISCV_FORMAL_ALIGNED_MEM@ —
our core traps misaligned loads/stores (@mcause = 4 / 6@) so the
harness never has to reason about sub-word split transactions.

CSR-side RVFI ports
(@rvfi_csr_\<name\>_\{rmask,wmask,rdata,wdata\}@) are not in this
first cut. They land in the same commit as the @csrw@ /
@csrc_any@ checks if the initial @insn_*@ / @pc_*@ / @reg@ / @ill@
sweep finds enough bugs to justify the extra wiring.

The record field names use @rfXxx@ rather than the raw Verilog
@rvfi_xxx@ to stay clear of Haskell's reserved-word rules.
'Riski5.FormalTop' maps them back to the canonical @rvfi_xxx@
names via its top-entity port-name annotations when emitting
the formal-verification Verilog.
-}
module Riski5.Rvfi (
  Rvfi (..),
  zeroRvfi,
) where

import Clash.Prelude

-- | Bundled RVFI observability signals for one cycle.
--
-- All fields are only meaningful on cycles where 'rfValid' is
-- @1@. On non-retire cycles the harness ignores them — the
-- contract is that their values on non-retire cycles are
-- irrelevant, not that they're zero.
data Rvfi = Rvfi
  { rfValid :: !Bit
  -- ^ @rvfi_valid@ — asserted the cycle an instruction retires.
  , rfOrder :: !(BitVector 64)
  -- ^ @rvfi_order@ — monotonic retire index, no gaps, no repeats.
  , rfInsn :: !(BitVector 32)
  -- ^ @rvfi_insn@ — instruction word that retired.
  , rfTrap :: !Bit
  -- ^ @rvfi_trap@ — high iff this instruction raised a trap
  -- (illegal, misaligned, or ECALL / EBREAK). Still retires.
  , rfHalt :: !Bit
  -- ^ @rvfi_halt@ — liveness marker. Always @0@ for riski5; we
  -- never halt.
  , rfIntr :: !Bit
  -- ^ @rvfi_intr@ — high on the first instruction executed in a
  -- trap handler (i.e. this cycle's @pc_rdata@ does not equal
  -- the previous retire's @pc_wdata@).
  , rfMode :: !(BitVector 2)
  -- ^ @rvfi_mode@ — current privilege level. Always @3@ (M).
  , rfIxl :: !(BitVector 2)
  -- ^ @rvfi_ixl@ — XLEN encoding. Always @1@ (RV32).
  , rfRs1Addr :: !(BitVector 5)
  -- ^ @rvfi_rs1_addr@ — register index of the rs1 source, or
  -- @0@ if the instruction doesn't read one.
  , rfRs2Addr :: !(BitVector 5)
  -- ^ @rvfi_rs2_addr@ — same convention as 'rfRs1Addr' for rs2.
  , rfRs1Rdata :: !(BitVector 32)
  -- ^ @rvfi_rs1_rdata@ — pre-execution value of rs1. MUST be
  -- zero when 'rfRs1Addr' is zero (the harness asserts it).
  , rfRs2Rdata :: !(BitVector 32)
  -- ^ @rvfi_rs2_rdata@ — same convention for rs2.
  , rfRdAddr :: !(BitVector 5)
  -- ^ @rvfi_rd_addr@ — destination register index, or @0@ if
  -- the instruction writes no rd.
  , rfRdWdata :: !(BitVector 32)
  -- ^ @rvfi_rd_wdata@ — post-execution value written to rd.
  -- MUST be zero when 'rfRdAddr' is zero.
  , rfPcRdata :: !(BitVector 32)
  -- ^ @rvfi_pc_rdata@ — PC of the retiring instruction.
  , rfPcWdata :: !(BitVector 32)
  -- ^ @rvfi_pc_wdata@ — PC that will be fetched next.
  , rfMemAddr :: !(BitVector 32)
  -- ^ @rvfi_mem_addr@ — memory access address (zero if neither
  -- a load nor a store).
  , rfMemRmask :: !(BitVector 4)
  -- ^ @rvfi_mem_rmask@ — per-byte mask of which bytes of
  -- 'rfMemRdata' the instruction consumed.
  , rfMemWmask :: !(BitVector 4)
  -- ^ @rvfi_mem_wmask@ — per-byte mask of which bytes of
  -- 'rfMemWdata' the instruction wrote.
  , rfMemRdata :: !(BitVector 32)
  -- ^ @rvfi_mem_rdata@ — pre-store memory value at 'rfMemAddr'.
  -- For loads this is the value the instruction read; for
  -- stores this is the original value (before the write lands).
  , rfMemWdata :: !(BitVector 32)
  -- ^ @rvfi_mem_wdata@ — new value written. Byte lanes outside
  -- 'rfMemWmask' are don't-care.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

-- | All-zero RVFI bundle with static fields (mode, ixl) set to
-- their riski5 constants. Used in places where a retire isn't
-- happening — the harness ignores everything under
-- @rvfi_valid=0@ anyway but a deterministic zero keeps the
-- Clash-emitted Verilog clean.
zeroRvfi :: Rvfi
zeroRvfi =
  Rvfi
    { rfValid = 0
    , rfOrder = 0
    , rfInsn = 0
    , rfTrap = 0
    , rfHalt = 0
    , rfIntr = 0
    , rfMode = 3
    , rfIxl = 1
    , rfRs1Addr = 0
    , rfRs2Addr = 0
    , rfRs1Rdata = 0
    , rfRs2Rdata = 0
    , rfRdAddr = 0
    , rfRdWdata = 0
    , rfPcRdata = 0
    , rfPcWdata = 0
    , rfMemAddr = 0
    , rfMemRmask = 0
    , rfMemWmask = 0
    , rfMemRdata = 0
    , rfMemWdata = 0
    }
