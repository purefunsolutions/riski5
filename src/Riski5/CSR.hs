-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Riski5.CSR
Description : Minimal M-mode CSR file + trap plumbing.

riski5 implements only the machine-mode CSRs the phase-1 core
actually needs to take a trap and return from it:
@mstatus@, @mtvec@, @mepc@, @mcause@, @mtval@, @mscratch@. Cycle /
instruction counters are modelled as free-running registers.
Reads of un-implemented CSR addresses return 0; writes are
silently dropped (the hardware core will trap on them later, but
phase-1 firmware doesn't touch them).

The module is pure: Core holds the 'Csrs' record in a 'register'
and threads it through 'handleInstr', calling the functions here
to read, write, and latch traps. Keeping it pure makes it trivial
to diff against 'Riski5.Reference'.
-}
module Riski5.CSR (
  Csrs (..),
  initCsrs,
  readCsr,
  writeCsr,
  applyTrap,
  applyMret,
  interruptPending,
  causeMachineTimerInterrupt,
  causeMachineExternalInterrupt,

  -- * Trap-cause codes (from priv-spec §3.1.20 "Machine Cause Register")
  causeInstrAddrMisaligned,
  causeIllegalInstr,
  causeBreakpoint,
  causeLoadAddrMisaligned,
  causeStoreAddrMisaligned,
  causeEcallFromM,
) where

import Clash.Prelude hiding ((&&))
import Riski5.ISA (
  csrMcause,
  csrMcycle,
  csrMepc,
  csrMie,
  csrMip,
  csrMisa,
  csrMscratch,
  csrMstatus,
  csrMtval,
  csrMtvec,
  unCsr,
 )

{- | Machine-mode CSR state riski5 actually stores. Everything else
decodes to zero on read.
-}
data Csrs = Csrs
  { cMstatus :: BitVector 32
  , cMtvec :: BitVector 32
  , cMepc :: BitVector 32
  , cMcause :: BitVector 32
  , cMtval :: BitVector 32
  , cMscratch :: BitVector 32
  , cMcycle :: BitVector 32
  -- ^ Lower 32 bits of the machine cycle counter (Zicntr). Increments
  -- once per core clock in 'Riski5.Core', regardless of stall / bubble
  -- — i.e. counts every clock edge, not just retired instructions.
  -- Wraps at 2^32, which at the shipping 40 MHz clock is ~107 s —
  -- large enough for CoreMark-class benchmark timing. The upper 32
  -- bits (mcycleh) are not yet implemented; reads return 0.
  , cMie :: BitVector 32
  -- ^ Machine interrupt-enable mask. Bits MTIE (7), MSIE (3), MEIE (11)
  -- gate which machine-mode interrupts can fire. Software-controlled.
  , cMip :: BitVector 32
  -- ^ Machine interrupt-pending. Bit MTIP (7) is __read-only__ — it
  -- follows the external @mtipS@ strobe driven by 'Riski5.Clint'
  -- (updated each cycle in 'Riski5.Core' alongside 'cMcycle'). Bits
  -- MSIP / MEIP are not yet wired and stay at 0.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

-- | Reset value: all CSRs zero.
initCsrs :: Csrs
initCsrs =
  Csrs
    { -- mstatus.MPP (bits 12:11) defaults to M-mode = 0b11 because
      -- this core only implements M-mode. Linux's trap handlers READ
      -- this on every trap entry to decide whether the offending
      -- instruction was in user or kernel mode (handle_break routes
      -- user-mode EBREAKs to SIGTRAP and kernel-mode EBREAKs to
      -- the WARN/BUG path). Initialising MPP to 0 (= U-mode) makes
      -- the kernel treat M-mode WARN_ON()s as user-mode signals,
      -- which queues SIGTRAP for init_task and hangs the boot CPU
      -- in irqentry_exit_to_user_mode forever (task #52). Per the
      -- RISC-V priv spec, for M-only cores MPP is a WARL field that
      -- can ONLY hold the M-mode value, so 0b11 is the architecturally
      -- correct default — leaving it 0 was a spec violation.
      cMstatus = 0b11 `shiftL` 11
    , cMtvec = 0
    , cMepc = 0
    , cMcause = 0
    , cMtval = 0
    , cMscratch = 0
    , cMcycle = 0
    , cMie = 0
    , cMip = 0
    }

{- | Read a 32-bit CSR value. Addresses the core doesn't implement
return zero, matching what the hardware will produce once we add
proper trap-on-unknown-CSR behaviour in a later phase.
-}
readCsr :: Csrs -> BitVector 12 -> BitVector 32
readCsr cs addr
  | addr == unCsr csrMstatus = cMstatus cs
  | addr == unCsr csrMtvec = cMtvec cs
  | addr == unCsr csrMepc = cMepc cs
  | addr == unCsr csrMcause = cMcause cs
  | addr == unCsr csrMtval = cMtval cs
  | addr == unCsr csrMscratch = cMscratch cs
  | addr == unCsr csrMcycle = cMcycle cs
  | addr == unCsr csrMie = cMie cs
  | addr == unCsr csrMip = cMip cs
  | addr == unCsr csrMisa = misaValue
  -- ^ misa: hard-wired read-only CSR advertising the implemented
  -- ISA shape. Linux head.S reset_regs reads it to decide whether
  -- to clear the F/D-extension registers, and traps on illegal
  -- instr if we lie about having F/D. We implement RV32IMA + Zicsr
  -- + Zifencei: bit 8 (I), bit 12 (M), bit 0 (A), MXL=01 (= RV32)
  -- in the top bits (mxl[1:0] = 01 means XLEN=32). All other
  -- extension bits MUST be 0.
  | otherwise = 0
  where
    -- MXL = 01 (RV32) in bits[31:30] = 0x4000_0000
    -- Extensions: I (bit 8 = 0x100), M (bit 12 = 0x1000), A (bit 0 = 0x1)
    misaValue :: BitVector 32
    misaValue = 0x40001101

{- | Write a 32-bit CSR value. Writes to addresses the core doesn't
implement are dropped (Csrs unchanged).
-}
writeCsr :: BitVector 12 -> BitVector 32 -> Csrs -> Csrs
writeCsr addr v cs
  | addr == unCsr csrMstatus = cs {cMstatus = v}
  | addr == unCsr csrMtvec = cs {cMtvec = v}
  | addr == unCsr csrMepc = cs {cMepc = v}
  | addr == unCsr csrMcause = cs {cMcause = v}
  | addr == unCsr csrMtval = cs {cMtval = v}
  | addr == unCsr csrMscratch = cs {cMscratch = v}
  | addr == unCsr csrMcycle = cs {cMcycle = v}
  | addr == unCsr csrMie = cs {cMie = v}
  -- mip is mostly read-only; software writes affect only the soft-set
  -- bits MSIP / MEIP / SSIP / STIP / UTIP. MTIP is hardware-driven.
  -- Phase-2 firmware doesn't touch mip writes, so we accept the write
  -- but mask MTIP back from the hardware pin on the next cycle.
  | addr == unCsr csrMip = cs {cMip = v}
  | otherwise = cs

{- | Latch a trap: record the cause, the instruction's @pc@ in
@mepc@, and any trap-specific \"value\" (e.g. faulting address or
the offending instruction word) in @mtval@. Mirrors the hardware
trap path without the privilege-mode / delegation dance we don't
have yet.
-}
applyTrap ::
  -- | cause code (see @causeXxx@ constants below)
  BitVector 32 ->
  -- | pc at the time of the trap
  BitVector 32 ->
  -- | trap value (address, instruction, or zero)
  BitVector 32 ->
  Csrs ->
  Csrs
applyTrap cause epc tval cs =
  let oldStatus = cMstatus cs
      oldMie = oldStatus .&. bit 3 -- MIE bit (bit 3)
      -- MPIE := old MIE (shifted to bit 7); clear MIE.
      mpieSet = if oldMie /= 0 then bit 7 else 0
      -- MPP := previous privilege mode. Our core only implements
      -- M-mode (no U/S/H), so the prev mode is always M-mode = 0b11
      -- (bits 12:11). Linux's trap handlers READ mstatus.MPP to
      -- decide whether the trap came from user or kernel — e.g.
      -- handle_break (arch/riscv/kernel/traps.c) routes EBREAKs
      -- from user mode to force_sig_fault(SIGTRAP) and EBREAKs from
      -- kernel mode to report_bug() (the WARN_ON / BUG_ON path).
      -- If MPP is left at 0 (U-mode), every WARN_ON in the kernel
      -- ends up queuing a SIGTRAP for the boot CPU's idle task,
      -- and the idle task spins in irqentry_exit_to_user_mode
      -- forever because no signal handler clears TIF_SIGPENDING.
      -- Caught by Linux mid-init hang on Verilator hwsim AND
      -- silicon (task #52): early_init_dt_scan_root WARN()s about
      -- missing #address-cells (a separate bug downstream from
      -- this), the WARN's ebreak entered handle_break, kernel saw
      -- MPP=0 and shipped a SIGTRAP, idle task hung on it.
      mppMmode = 0b11 `shiftL` 11 -- bits[12:11] = 0b11
      newStatus =
        (oldStatus .&. complement (bit 3 .|. bit 7 .|. (0b11 `shiftL` 11)))
          .|. mpieSet
          .|. mppMmode
   in cs
        { cMcause = cause
        , cMepc = epc
        , cMtval = tval
        , cMstatus = newStatus
        }

{- | Apply the @MRET@ instruction to the CSR file: restore @mstatus.MIE@
from @mstatus.MPIE@ and re-arm @MPIE@ to 1. The PC redirect to
@mepc@ is handled by the caller in 'Riski5.Core.handleInstr'.
-}
applyMret :: Csrs -> Csrs
applyMret cs =
  let oldStatus = cMstatus cs
      mpie = oldStatus .&. bit 7
      mieFromMpie = if mpie /= 0 then bit 3 else 0
      -- Clear current MIE, install MPIE there; set MPIE := 1.
      newStatus =
        (oldStatus .&. complement (bit 3))
          .|. mieFromMpie
          .|. bit 7
   in cs {cMstatus = newStatus}

{- | True iff a machine-mode interrupt is pending and architecturally
allowed to fire — i.e. @mstatus.MIE@ is set, the corresponding
@mie.* bit is set, and the matching @mip.* bit is set. Returns the
cause code if pending, 'Nothing' otherwise.

Priority order (per priv-spec §3.1.9, table "Synchronous exception
priority"): MEI > MSI > MTI > SEI > … We currently model only
MTI and MEI; if both fire on the same cycle, MEI takes
precedence.
-}
interruptPending :: Csrs -> Maybe (BitVector 32)
interruptPending cs
  | meiAllEnabled = Just causeMachineExternalInterrupt
  | mtiAllEnabled = Just causeMachineTimerInterrupt
  | otherwise = Nothing
 where
  mieEnabled = cMstatus cs .&. bit 3 /= 0
  mtieEnabled = cMie cs .&. bit 7 /= 0
  mtipPending = cMip cs .&. bit 7 /= 0
  meieEnabled = cMie cs .&. bit 11 /= 0
  meipPending = cMip cs .&. bit 11 /= 0
  mtiAllEnabled = mieEnabled && mtieEnabled && mtipPending
  meiAllEnabled = mieEnabled && meieEnabled && meipPending

-- | Cause code for a machine-timer interrupt (bit 31 set, low bits 7).
causeMachineTimerInterrupt :: BitVector 32
causeMachineTimerInterrupt = bit 31 .|. 7

-- | Cause code for a machine-external interrupt (bit 31 set, low bits 11).
-- The PLIC's @meipS@ output pulls the trap path here when
-- @mstatus.MIE && mie.MEIE@.
causeMachineExternalInterrupt :: BitVector 32
causeMachineExternalInterrupt = bit 31 .|. 11

-- * Trap causes ----------------------------------------------------

causeInstrAddrMisaligned, causeIllegalInstr, causeBreakpoint :: BitVector 32
causeInstrAddrMisaligned = 0
causeIllegalInstr = 2
causeBreakpoint = 3

causeLoadAddrMisaligned, causeStoreAddrMisaligned, causeEcallFromM :: BitVector 32
causeLoadAddrMisaligned = 4
causeStoreAddrMisaligned = 6
causeEcallFromM = 11
