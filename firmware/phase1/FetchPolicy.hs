-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause

{- |
Module      : FetchPolicy
Description : Per-bitstream toggle for fetch-side SRAM routing.

Controls whether 'Riski5.Soc.soc' instantiates the fetch-side
bus decoder + SRAM arbiter wiring. Top.hs imports this module
unconditionally and passes 'enableSramFetch' into 'soc'; the
SoC gates its @fetchInSramS@ on the flag, so when it's 'False'
the arbiter reduces to the baseline data-only SRAM path and
Quartus produces a bitstream bit-identical to the pre-arbiter
CoreMark one.

The default committed in git is 'False' — safest for the main
production bitstream (@riski5-core@ / @riski5-core-coremark@)
and leaves Quartus's placement unchanged for the common case.
The sramexec bitstream variant overlays this file at Nix build
time with 'enableSramFetch = True' to turn the arbiter on.

This is the minimal-surface way to toggle a synthesis parameter
per bitstream variant without introducing CPP into 'app/Top.hs'
(which previously caused Quartus-placement regressions — see
@docs/perf/sram-exec-probe-2026-04-24.md@).
-}
module FetchPolicy (
  enableSramFetch,
) where

import Prelude (Bool (..))

-- | Default: SRAM fetch path disabled. The sramexec variant's
-- Nix overlay flips this to 'True'.
enableSramFetch :: Bool
enableSramFetch = False
