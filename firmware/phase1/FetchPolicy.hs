-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause

{- |
Module      : FetchPolicy
Description : Per-bitstream toggles for fetch-side off-chip-memory routing.

Controls whether 'Riski5.Soc.soc' instantiates the fetch-side
arbiter wiring on the SRAM and SDRAM controllers. Top.hs imports
this module unconditionally and passes both flags into 'soc'; the
SoC gates each fetch-side path behind its own compile-time @if@,
so when a flag is 'False' the corresponding arbiter reduces to the
baseline data-only path and Quartus produces a bitstream
bit-identical to the pre-arbiter CoreMark one.

The defaults committed in git are both 'False' — safest for the
main production bitstream (@riski5-core@ / @riski5-core-coremark@)
and leaves Quartus's placement unchanged for the common case. The
debug bitstream variants overlay this file at Nix build time:

  * @riski5-core-sramexec@ flips 'enableSramFetch' to 'True'.
  * @riski5-core-sdramexec@ flips 'enableSdramFetch' to 'True'.

Both flags can be 'True' simultaneously (a future "Linux-style"
build) but no shipped variant uses that combination yet.

This is the minimal-surface way to toggle a synthesis parameter
per bitstream variant without introducing CPP into 'app/Top.hs'
(which previously caused Quartus-placement regressions — see
@docs/perf/sram-exec-probe-2026-04-24.md@).
-}
module FetchPolicy (
  enableSramFetch,
  enableSdramFetch,
) where

import Prelude (Bool (..))

-- | Default: SRAM fetch path disabled. The sramexec variant's
-- Nix overlay flips this to 'True'.
enableSramFetch :: Bool
enableSramFetch = False

-- | Default: SDRAM fetch path disabled. The sdramexec variant's
-- Nix overlay flips this to 'True'.
enableSdramFetch :: Bool
enableSdramFetch = False
