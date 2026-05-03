-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoStarIsType #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

{- |
Module      : Riski5.Domains
Description : Single source of truth for the SoC's clock domains.

Phase 1 of the multi-PLL split lays out three clock domains the SoC
will eventually run on, each driven by its own Cyclone II PLL via the
@riski5_top.v@ wrapper:

  * 'DomBus'   — the Avalon-MM bus, peripherals (UART, JTAG-UART,
                 JTAG-Avalon-Master, GPIO, LCD), the SRAM controller,
                 the BRAM read/write ports, and the @Riski5.Sdram@
                 32↔16 two-port adapter (the chip-side SDRAM
                 controller lives in 'DomSdram'; the bus-side adapter
                 is part of the bus domain).
  * 'DomCore'  — the RISC-V core itself (CPU pipeline, regfile, IF
                 stage, CSR/CLINT/PLIC, ALU, AMO/MulDiv FUs).
  * 'DomSdram' — the pure-Clash @Riski5.SdrController@ + the
                 chip-side @DRAM_*@ pin drivers. Runs at the
                 @IS42S16400-7TL@'s rated clock so refresh and
                 ACTIVATE/CAS timing are at the chip's design
                 envelope without the rest of the SoC having to keep
                 up.

== Why three separate domains

Today everything runs on a single 40 MHz @clkBus@. Quartus STA reports
the combined design's restricted Fmax at 52.13 MHz; the slowest path
caps the entire SoC. Splitting into independent domains lets each
subsystem find its own ceiling: the CPU and the bus likely each push
to ~55 MHz on their own, and the SDRAM controller can target the
chip's 133 MHz spec. Multi-domain also fixes the pathological case
where slowing the whole design to give the SDRAM more refresh margin
(@slowClock=true@ at 30 MHz) makes the CPU equally slow — wasted
silicon-iteration time.

== CPP-overrideable periods

Each domain's period is tunable at compile time via
@-DSOC_BUS_PERIOD_PS=...@, @-DSOC_CORE_PERIOD_PS=...@,
@-DSOC_SDRAM_PERIOD_PS=...@. The Nix build (in
@pkgs/riski5-core/package.nix@) computes these from the per-PLL
multiplier/divider parameters and passes them through to Clash.
Defaults match the existing 40 MHz single-domain values for DomBus
and DomCore (so the Phase A scaffolding doesn't change behaviour);
DomSdram defaults to 7500 ps (133.33 MHz).

The Clash sim engine treats the period as opaque numerically — it
only matters that two domains with different periods advance their
clocks asynchronously, which is exactly what we want for testing
CDC bridges. The synthesis toolchain (Quartus + altpll) takes the
period from the SDC file, not from these CPP defines, so the
hardware-side rates are independently controlled by
@pkgs/riski5-core/package.nix@'s PLL parameters.
-}
module Riski5.Domains (
  DomBus,
  DomCore,
  DomSdram,
) where

import Clash.Prelude

-- | DomBus period (picoseconds). Default 25_000 ps = 40 MHz.
-- Override via @-DSOC_BUS_PERIOD_PS=N@ at Clash invocation time.
#ifndef SOC_BUS_PERIOD_PS
#define SOC_BUS_PERIOD_PS 25000
#endif

-- | DomCore period (picoseconds). Default 25_000 ps = 40 MHz.
-- Override via @-DSOC_CORE_PERIOD_PS=N@ at Clash invocation time.
#ifndef SOC_CORE_PERIOD_PS
#define SOC_CORE_PERIOD_PS 25000
#endif

-- | DomSdram period (picoseconds). Default 7500 ps = 133.33 MHz
-- (the IS42S16400-7TL rated clock).
-- Override via @-DSOC_SDRAM_PERIOD_PS=N@ at Clash invocation time.
#ifndef SOC_SDRAM_PERIOD_PS
#define SOC_SDRAM_PERIOD_PS 7500
#endif

createDomain
  vSystem
    { vName = "DomBus"
    , vPeriod = SOC_BUS_PERIOD_PS
    , vResetKind = Asynchronous
    , vResetPolarity = ActiveLow
    }

createDomain
  vSystem
    { vName = "DomCore"
    , vPeriod = SOC_CORE_PERIOD_PS
    , vResetKind = Asynchronous
    , vResetPolarity = ActiveLow
    }

createDomain
  vSystem
    { vName = "DomSdram"
    , vPeriod = SOC_SDRAM_PERIOD_PS
    , vResetKind = Asynchronous
    , vResetPolarity = ActiveLow
    }
