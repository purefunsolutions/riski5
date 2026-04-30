-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Riski5.SdrController
Description : Pure-Clash SDR SDRAM controller for the DE2's
              IS42S16400-7TL 8 MB chip.

Replaces Altera's @altera_avalon_new_sdram_controller@ IP
('Riski5.Sdram' wraps that IP today). The Altera IP shipped a
deterministic upper-half-word write drop on this board (see
'docs/sdram-hi-half-write-bug.md' for the full triage); rather
than chase the encrypted Perl-generated logic, this module
re-implements the protocol in transparent Clash. Phase-1D
explicitly listed this as the fallback if the Altera IP didn't
work (CLAUDE.md "Altera IP black-boxing policy").

== Chip target

IS42S16400 family — 4M × 16-bit, 4 banks, 12-bit row, 8-bit
column. CL=2 / CL=3 selectable via mode register. -7TL variant
is rated at 143 MHz (CL=3) or 100 MHz (CL=2); we run the chip at
108 MHz CL=3 to leave timing margin.

Datasheet timing (-7TL @ 108 MHz, period = 9.26 ns):

@
  T_RCD  = 21 ns →  3 cycles  (ACTIVATE → READ/WRITE)
  T_RP   = 21 ns →  3 cycles  (PRECHARGE recovery)
  T_RFC  = 60 ns →  7 cycles  (auto-refresh cycle)
  T_WR   = 14 ns →  2 cycles  (WRITE → PRECHARGE)
  T_MRD  = 2 cycles           (LOAD MODE REG → next command)
  CL     = 3 cycles           (READ → first data)
  T_REF  = 7.81 µs (= 4096 refreshes / 32 ms typical)
@

== Avalon-MM slave port (matches the Altera IP's pin shape)

The SDRAM 32 ↔ 16 width adapter ('Riski5.Sdram') sees the same
@az_*@ / @za_*@ signals it currently drives at the IP boundary,
so swapping IP ↔ this module is a single-instantiation change
in the Verilog top wrapper.

@
  az_cs        master select (1-bit)
  az_addr      half-word index (22-bit; rowWidth + colWidth + bankWidth)
  az_data      write data (16-bit)
  az_be_n      byte-enable, active-low (2-bit)
  az_rd_n      read request, active-low
  az_wr_n      write request, active-low
  za_data      read data (16-bit)
  za_valid     read-data valid pulse (1-cycle)
  za_waitrequest  master-stall (1-bit)
@

== Chip-side pins (SDR SDRAM commands)

@
  zs_addr     12-bit row / column / mode-register payload
  zs_ba       2-bit bank select (also doubles as MR bits in LMR)
  zs_cas_n    column-address strobe, active-low
  zs_cke      clock-enable (held high)
  zs_cs_n     chip-select, active-low
  zs_dq       16-bit data — bidirectional. Modeled as
              (oData, oeData, iData) inside Clash; the Verilog
              wrapper resolves the 'inout' the same way Riski5.Sram
              does for SRAM_DQ.
  zs_dqm      2-bit data mask (byte enable for the 16-bit half-word).
              Active-high — DQM[k]=1 masks byte k.
  zs_ras_n    row-address strobe, active-low
  zs_we_n    write-enable, active-low
@

== Command encoding

Standard SDRAM JEDEC command set:

@
  cs_n  ras_n  cas_n  we_n      meaning
   1     X      X      X         deselect / NOP
   0     1      1      1         NOP
   0     0      1      1         ACTIVATE (row in BA, addr in zs_addr)
   0     1      0      1         READ     (col in zs_addr[7:0], A10 = auto-precharge)
   0     1      0      0         WRITE    (same as READ; data on DQ)
   0     0      1      0         PRECHARGE (A10=1 → all banks, =0 → BA only)
   0     0      0      1         AUTO-REFRESH
   0     0      0      0         LOAD MODE REGISTER
@

We use auto-precharge (A10 = 1 on READ / WRITE) to avoid
explicit PRECHARGE commands per access. That cuts the
T_RP-after-each-transaction latency by amortising it inside the
chip's auto-precharge logic.

== FSM overview

@
                     POR
                      ↓
                   Init: 200µs NOP
                      ↓
                 PRECHARGE-ALL
                      ↓
                 AUTO-REFRESH × 8
                      ↓
                 LOAD MODE REGISTER (CL=3, BL=1)
                      ↓
                  ┌──→ Idle ─────────────────────────────────┐
                  │     ↓ (refresh counter expired)          │
                  │   AutoRefresh                            │
                  │     ↓                                    │
                  │   TrfcWait (7 cycles)                    │
                  │     └→─────┐                             │
                  │            │                             │
                  │     ↓ (master cs+rd or cs+wr)            │
                  │   Activate                               │
                  │     ↓                                    │
                  │   TrcdWait (3 cycles, in this 4-cycle    │
                  │             window: NOPs to chip)        │
                  │     ↓                                    │
                  │   Read │ Write       ← READ or WRITE     │
                  │   ↓        ↓             with auto-      │
                  │   ClWait   TwrWait       precharge       │
                  │   (3 cyc)  (2 cyc)                       │
                  │   ↓        └→ Trprecharge (3 cyc)        │
                  │   Capture                                │
                  │   (drive za_valid)                       │
                  │   ↓                                      │
                  │   Trprecharge (3 cyc)                    │
                  │   ↓                                      │
                  └─→ Idle                                   │
                                                             │
                  Refresh-pending priority: any time the     │
                  refresh counter expires AND the FSM is in  │
                  Idle, we issue AUTO-REFRESH instead of     │
                  servicing a master request. The refresh    │
                  counter resets after each AUTO-REFRESH.    │
                                                             │
                  We DO NOT preempt an in-flight transaction │
                  to refresh — refresh waits for Idle.       │
@

== Byte-enable handling

The chip's DQM input MASKS bytes during writes (DQM[k]=1 → don't
write byte k). For Avalon-MM we receive byte-enable as az_be_n
(active-low). We forward az_be_n to zs_dqm directly during writes,
and drive zs_dqm = 0 during reads (don't mask).

== Refresh counter

@refreshPeriodCycles@ is computed from the clock rate and the
chip's T_REF requirement (7.81 µs at typical commercial parts).
We default to 7800 ns / period_ns ≈ 842 cycles at 108 MHz. A
counter increments each cycle; when it hits the threshold the
controller asserts an internal refresh-pending flag and resets
the counter on the next AUTO-REFRESH issue.

== References

  * IS42S16400 datasheet (Integrated Silicon Solution).
  * Micron SDRAM controller TN-04-32 application note.
  * Open SDR SDRAM cores — Alex Forencich (forencich.com),
    @ProjectF@'s Verilog SDR controller, @cyrozap@'s tinyfpga-bx
    sdr controller.
  * The replaced Altera IP — generated from
    @\<quartus\>/share/altera13.0sp1/ip/altera/sopc_builder_ip/altera_avalon_new_sdram_controller@
    with the parameters in @pkgs\/riski5-core\/package.nix@ (we
    keep those parameters as the chip-spec source of truth even
    after the IP itself is gone).

NOTE: this module is in skeleton form — the FSM types and ports
are defined; the actual command-cycle table is filled in
incrementally as we test it against the behavioral chip model.
The first commit lands the structure + pin-out so the rest of the
SoC can be re-wired against the new module's port list while we
iterate on the FSM internals.
-}
module Riski5.SdrController (
  -- * Configuration
  SdrConfig (..),
  defaultDe2Config,

  -- * Chip-side I/O bundle
  SdrPins (..),

  -- * Avalon-MM slave bundle (mirrors Riski5.Sdram.SdramIpBus +
  --   SdramIpReply for drop-in compatibility)
  SdrSlaveIn (..),
  SdrSlaveOut (..),

  -- * Controller entity
  sdrController,

  -- * FSM state (re-exported for tests)
  SdrPhase (..),
  SdrCmd (..),
) where

import Clash.Prelude

-- * Configuration ---------------------------------------------------

-- | Static configuration for the controller. All values are in
-- chip / clock cycles relative to the controller clock rate.
-- Defaults match the DE2's IS42S16400-7TL @ 108 MHz CL=3.
data SdrConfig = SdrConfig
  { -- | T_RCD (ACTIVATE → READ/WRITE) in cycles.
    sdrTrcdCycles :: Unsigned 4
  , -- | T_RP (PRECHARGE recovery) in cycles.
    sdrTrpCycles :: Unsigned 4
  , -- | T_RFC (auto-refresh) in cycles.
    sdrTrfcCycles :: Unsigned 4
  , -- | T_WR (WRITE → PRECHARGE) in cycles.
    sdrTwrCycles :: Unsigned 4
  , -- | CAS latency in cycles (programmed into chip's mode
    -- register; we wait this many NOPs after a READ command
    -- before the first read-data is on DQ).
    sdrCasLatency :: Unsigned 4
  , -- | T_REF cycles between auto-refresh commands. 7.81 µs at
    -- 108 MHz = 843 cycles.
    sdrRefreshIntervalCycles :: Unsigned 16
  , -- | Initial NOP cycles after power-up. 200 µs at 108 MHz =
    -- 21600 cycles.
    sdrInitNopCycles :: Unsigned 16
  , -- | Number of auto-refresh commands during init. JEDEC
    -- recommends 8 minimum.
    sdrInitRefreshCount :: Unsigned 4
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (NFDataX)

defaultDe2Config :: SdrConfig
defaultDe2Config =
  SdrConfig
    { sdrTrcdCycles = 3
    , sdrTrpCycles = 3
    , sdrTrfcCycles = 7
    , sdrTwrCycles = 2
    , sdrCasLatency = 3
    , sdrRefreshIntervalCycles = 843
    , sdrInitNopCycles = 21600
    , sdrInitRefreshCount = 8
    }

-- * Chip-side I/O ---------------------------------------------------

-- | The 11 chip-pin signals the controller drives plus the
-- bidirectional DQ split into out/oe/in. The Verilog top wrapper
-- resolves @SDRAM_DQ@ (inout) from these the same way it does for
-- @SRAM_DQ@ — Clash never deals in tristate.
data SdrPins = SdrPins
  { sdrAddr :: BitVector 12
  , sdrBa :: BitVector 2
  , sdrCasN :: Bool
  , sdrCke :: Bool
  , sdrCsN :: Bool
  , sdrDqOut :: BitVector 16
  , sdrDqOe :: Bool -- True: drive DQ from the controller
  , sdrDqm :: BitVector 2
  , sdrRasN :: Bool
  , sdrWeN :: Bool
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (NFDataX)

-- | Idle-cycle command (deselect / NOP). All command strobes
-- inactive, DQ tri-stated.
sdrIdleCmd :: SdrPins
sdrIdleCmd =
  SdrPins
    { sdrAddr = 0
    , sdrBa = 0
    , sdrCasN = True
    , sdrCke = True
    , sdrCsN = True -- deselected
    , sdrDqOut = 0
    , sdrDqOe = False
    , sdrDqm = 0b11 -- mask both bytes when not driving
    , sdrRasN = True
    , sdrWeN = True
    }

-- * Avalon-MM slave -------------------------------------------------

-- | Master-side request bundle (mirrors @Riski5.Sdram.SdramIpBus@).
data SdrSlaveIn = SdrSlaveIn
  { ssiCs :: Bool
  , ssiAddr :: BitVector 22
  , ssiWdata :: BitVector 16
  , ssiBeN :: BitVector 2 -- active-low byte enables (Avalon convention)
  , ssiRd :: Bool
  , ssiWr :: Bool
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (NFDataX)

-- | Slave-side reply bundle (mirrors @Riski5.Sdram.SdramIpReply@).
data SdrSlaveOut = SdrSlaveOut
  { ssoRdata :: BitVector 16
  , ssoValid :: Bool
  , ssoWaitrequest :: Bool
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (NFDataX)

-- * FSM state -------------------------------------------------------

-- | Top-level FSM phase.
data SdrPhase
  = -- * Power-up init sequence
    PhInitNop -- 200 µs of NOPs
  | PhInitPrecharge -- PRECHARGE-ALL
  | PhInitTrp -- T_RP after PRECHARGE
  | PhInitRefresh -- AUTO-REFRESH (one of N during init)
  | PhInitTrfc -- T_RFC after refresh
  | PhInitLmr -- LOAD MODE REGISTER
  | PhInitTmrd -- T_MRD after LMR
  | -- * Steady state
    PhIdle
  | PhActivate
  | PhTrcd -- T_RCD wait between ACTIVATE and READ/WRITE
  | PhRead
  | PhCl -- CAS latency wait
  | PhCapture -- drive za_valid + read data
  | PhWrite
  | PhTwr -- T_WR after WRITE before PRECHARGE
  | PhTrpAfter -- T_RP after auto-precharge
  | -- * Background refresh
    PhRefresh
  | PhTrfc -- T_RFC after auto-refresh
  deriving stock (Generic, Eq, Show)
  deriving anyclass (NFDataX)

-- | High-level command shape (helper type — the controller emits
-- 'SdrPins', this type is for FSM exposition).
data SdrCmd
  = CmdNop
  | CmdActivate
  | CmdRead
  | CmdWrite
  | CmdPrecharge
  | CmdAutoRefresh
  | CmdLoadModeReg
  deriving stock (Generic, Eq, Show)
  deriving anyclass (NFDataX)

-- * Controller entity ----------------------------------------------

{- |
The SDR SDRAM controller. Wraps the FSM described in the module
header. Single Avalon-MM slave port + chip-side pins + a config
record (so we can build different presets — e.g. CL=2 if we
ever drop the clock to 100 MHz).

Currently this is a placeholder that always asserts
@waitrequest@ and emits NOP-equivalent chip pins. The real FSM
will be filled in once we have the test harness running against
a chip behavioral model. See @docs/sdram-hi-half-write-bug.md@
for the wider context this module is unblocking.
-}
sdrController ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  -- | Static config.
  SdrConfig ->
  -- | Master-side request.
  Signal dom SdrSlaveIn ->
  -- | (slave reply, chip pins).
  ( Signal dom SdrSlaveOut
  , Signal dom SdrPins
  )
sdrController _cfg _inS = (replyS, pinsS)
 where
  replyS = pure (SdrSlaveOut {ssoRdata = 0, ssoValid = False, ssoWaitrequest = True})
  pinsS = pure sdrIdleCmd
