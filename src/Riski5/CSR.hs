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

  -- * Trap-cause codes (from priv-spec §3.1.20 "Machine Cause Register")
  causeInstrAddrMisaligned,
  causeIllegalInstr,
  causeBreakpoint,
  causeLoadAddrMisaligned,
  causeStoreAddrMisaligned,
  causeEcallFromM,
) where

import Clash.Prelude
import Riski5.ISA (
  csrMcause,
  csrMepc,
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
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

-- | Reset value: all CSRs zero.
initCsrs :: Csrs
initCsrs =
  Csrs
    { cMstatus = 0
    , cMtvec = 0
    , cMepc = 0
    , cMcause = 0
    , cMtval = 0
    , cMscratch = 0
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
  | otherwise = 0

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
  cs
    { cMcause = cause
    , cMepc = epc
    , cMtval = tval
    }

-- * Trap causes ----------------------------------------------------

causeInstrAddrMisaligned, causeIllegalInstr, causeBreakpoint :: BitVector 32
causeInstrAddrMisaligned = 0
causeIllegalInstr = 2
causeBreakpoint = 3

causeLoadAddrMisaligned, causeStoreAddrMisaligned, causeEcallFromM :: BitVector 32
causeLoadAddrMisaligned = 4
causeStoreAddrMisaligned = 6
causeEcallFromM = 11
