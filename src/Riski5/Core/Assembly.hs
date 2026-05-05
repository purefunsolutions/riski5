-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}

{- |
Module      : Riski5.Core.Assembly
Description : 'coreWith' — preset-driven entry point to the
              shipping core.

Phase 2A: 'coreWith' is the single entry point for instantiating
a riski5 core from a 'CoreConfig'. Downstream modules
('Riski5.Soc', 'Riski5.FormalTop', 'Top') call @coreWith tiny32@
instead of importing @core@ from "Riski5.Core" directly.

Dispatch today is trivial — every preset whose shape matches the
one the current 'Riski5.Core.core' implementation realises
(i.e. 'Riski5.Core.Presets.tiny32') resolves to that
implementation; any other preset 'error's at elaboration.
Phase 2B\/2C\/3+ grow the dispatch table: each tier gets its own
block-composed kernel in @src/Riski5/Core/Kernel/*.hs@ and
'coreWith' selects between them by 'ccPipeline' + 'ccROB' +
related knobs.

Why value-level dispatch instead of type-level (DataKinds +
singletons + a @KnownCoreConfig@ class per §5.4 of
@core-family.md@)? Faster path to landing 2A with zero
functional change. Clash's @inlineWorkFree@ / constant folding
turns @coreWith tiny32@ into the same Verilog as calling
@core@ directly at the one concrete call site. Promotion to
type-level happens when we actually need it — likely phase 5A
(RV64), where @ccXLEN@ has to drive a width-indexed
@BitVector xlen@.

See "docs/core-family.md" for the full design.
-}
module Riski5.Core.Assembly (
  coreWith,
) where

import Clash.Prelude
import Riski5.Core (core)
import Riski5.Core.Config
import Riski5.Core.Presets (tiny32, tiny32M)
import Riski5.Rvfi (Rvfi)

{- | Instantiate a core from a 'CoreConfig' preset.

The signature mirrors 'Riski5.Core.core' exactly — same
inputs, same output tuple, same RVFI observability bundle.
The preset selects which kernel implementation is wired in.

@
 coreWith tiny32 imemData imemReadyS dmemRData stallS dataStallS mtipS meipS
@

resolves to today's 'core' kernel (pipelineless \/ F+X). Any
other preset is elaboration-time 'error' until the phase that
lands its kernel arrives.

The 'HiddenClockResetEnable' constraint is inherited from the
underlying kernel.
-}
coreWith ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  -- | which core shape to instantiate
  CoreConfig ->
  -- | instruction word at the current PC (same-cycle read)
  Signal dom (BitVector 32) ->
  -- | True whenever @imemData@ is the valid instruction for
  -- @pcFetch@. BRAM fetches strap this 'pure True'; multi-cycle
  -- fetches pulse it on the transaction-complete cycle. See the
  -- header of 'Riski5.Core.core' for the multi-cycle fetch
  -- contract.
  Signal dom Bool ->
  -- | data-memory read response (same-cycle read)
  Signal dom (BitVector 32) ->
  -- | back-pressure: freezes all sequential state when 'True'
  Signal dom Bool ->
  -- | data-side back-pressure only (not including fetch). Used
  -- by the AMO FU's slave-ready gate. See 'Riski5.Core.core'
  -- for why this is split out from combined @stallS@.
  Signal dom Bool ->
  -- | machine-timer-interrupt-pending strobe (CLINT-driven)
  Signal dom Bool ->
  -- | machine-external-interrupt-pending strobe (PLIC-driven)
  Signal dom Bool ->
  -- | @(pcFetch, pcExec, dmemAddr, dmemWdata, dmemByteEn,
  -- dmemReadEn, writeBack, rvfi)@ — see 'Riski5.Core.core'
  -- for per-field semantics.
  ( Signal dom (BitVector 32)
  , Signal dom (BitVector 32)
  , Signal dom (BitVector 32)
  , Signal dom (BitVector 32)
  , Signal dom (BitVector 4)
  , Signal dom Bool
  , Signal dom (Maybe (BitVector 5, BitVector 32))
  , Signal dom Rvfi
  , Signal dom Bool -- flushS — exposed for CoreCdcBridge cbrFlush refire (TODO #55)
  )
coreWith cfg imemData imemReadyS dmemRData stallS dataStallS mtipS meipS
  -- Phase 2A/2B: the current 'Riski5.Core.core' kernel covers both
  -- the RV32I 'tiny32' preset and its RV32M sibling 'tiny32M' —
  -- the MulDiv functional unit in "Riski5.Core.FU.MulDiv" is
  -- wired in unconditionally and simply idles when the preset
  -- doesn't enable @extM@. @core@ therefore accepts either preset
  -- without any shape change. Phase 2C's @Mem/Cache.hs@ + C-ext
  -- realigner + Zba/Zbb is the first preset boundary that needs
  -- a different kernel.
  | cfg == tiny32 = core imemData imemReadyS dmemRData stallS dataStallS mtipS meipS
  | cfg == tiny32M = core imemData imemReadyS dmemRData stallS dataStallS mtipS meipS
  | otherwise =
      errorX $
        "Riski5.Core.Assembly.coreWith: preset not yet "
          <> "implemented. Phase 2A/2B wire 'tiny32' and 'tiny32M'; "
          <> "other presets land from phase 2C/3/4/5 per "
          <> "docs/core-family.md §8. Got: "
          <> show cfg
