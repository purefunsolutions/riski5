-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoStarIsType #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Riski5.Cdc
Description : Clock-domain-crossing primitives for the multi-PLL split.

Wraps Clash's standard CDC primitives in slightly friendlier names
plus an edge-detect combinator that the SDRAM and Core CDC bridges
share.

== Coverage

* 'syncBit' — 2-FF synchroniser for a single 'Bool', the bedrock
  primitive both bridges use to cross toggle signals. Direct
  wrapper around 'Clash.Explicit.Synchronizer.dualFlipFlopSynchronizer'
  with the conventional 2-stage depth.
* 'syncBitVector' — same shape over a 'BitVector n', used to carry
  captured read data back across a CDC boundary as a quasi-static
  bus (source domain holds stable until a separate toggle indicates
  the new value is valid).
* 'edgeDetect' — registers an input and XORs against the previous
  value so a 'True' pulse appears for one cycle on every transition.
  Used downstream of the toggle-side synchronisers.

The toggle-handshake protocol itself lives in 'Riski5.SdramCdcBridge'
and 'Riski5.CoreCdcBridge'; their FSMs are too coupled to the
bus-payload type to factor cleanly into a single combinator.

Clash 1.8's 'dualFlipFlopSynchronizer' lowers to a clean two-flop
chain in the emitted Verilog, with a Quartus-friendly @ALTERA_ATTRIBUTE@
comment when the @-fclash-hdlsyn Quartus@ flag is on. No need to
drop down to raw Verilog primitives.
-}
module Riski5.Cdc (
  syncBit,
  syncBitVector,
  edgeDetect,
) where

import Clash.Explicit.Prelude (
  BitVector,
  Clock,
  Enable,
  KnownDomain,
  KnownNat,
  Reset,
  Signal,
  register,
 )
import qualified Clash.Explicit.Synchronizer as Sync
import Data.Bits (xor)

{- | 2-flop synchroniser for a single 'Bool'. Source domain drives
@srcS@ at any rate; destination domain sees the value through two
back-to-back DST-clock flops, which by construction resolves any
metastable sample at the first flop into a stable value at the
second flop with overwhelmingly high probability.

The 2-stage depth ('d2') is the industry-standard MTBF-budgeted
default. For higher reliability move to 'd3' or 'd4' explicitly via
'Sync.dualFlipFlopSynchronizer'.
-}
syncBit ::
  forall src dst.
  (KnownDomain src, KnownDomain dst) =>
  Clock src ->
  Clock dst ->
  Reset dst ->
  Enable dst ->
  Signal src Bool ->
  Signal dst Bool
syncBit clkSrc clkDst rstDst enDst =
  Sync.dualFlipFlopSynchronizer clkSrc clkDst rstDst enDst False

{- | 2-flop synchroniser for a 'BitVector n'. WARNING: synchronising
a multi-bit bus this way is only safe if the source holds the
value stable for the entire window the destination might sample
it. The toggle-handshake pattern guarantees this: master toggles
'req_toggle' on each new transaction, and only after the slave
sees the toggle edge does it sample the latched-bus register —
which the master is holding stable for the whole 'M_BUSY' interval.
-}
syncBitVector ::
  forall src dst n.
  (KnownDomain src, KnownDomain dst, KnownNat n) =>
  Clock src ->
  Clock dst ->
  Reset dst ->
  Enable dst ->
  Signal src (BitVector n) ->
  Signal dst (BitVector n)
syncBitVector clkSrc clkDst rstDst enDst =
  Sync.dualFlipFlopSynchronizer clkSrc clkDst rstDst enDst 0

{- | Pulse-on-transition. Registers the input and XORs against the
delayed copy. Output is 'True' for exactly one destination-clock
cycle on every input transition.

Typical use: feed the output of 'syncBit' on a toggle into
'edgeDetect' and case on it to fire the destination-side FSM
state transition.
-}
edgeDetect ::
  forall dom.
  (KnownDomain dom) =>
  Clock dom ->
  Reset dom ->
  Enable dom ->
  Signal dom Bool ->
  Signal dom Bool
edgeDetect clk rst en s =
  let prev = register clk rst en False s
   in xor <$> s <*> prev
