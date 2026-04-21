-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Riski5.AvalonMm
Description : Canonical Avalon-MM master-side bus tap.

Altera IP cores (JTAG UART, SDRAM controller, Triple-Speed Ethernet,
…) all expose an Avalon-MM slave interface with a consistent subset
of signals: @chipselect@, @address@, @writedata@, @byteenable@,
@read@, @write@, @readdata@, @waitrequest@. The riski5 SoC drives
those from a simpler internal bus (address-decoded @sel@ + common
@addr/wdata/be/re@ lines) and receives @readdata@ + a @ready@
(i.e. @~waitrequest@) indicator back.

Rather than each slave module redeclaring the same record shape,
this module defines a single canonical 'AvalonMmBus' and 'AvalonMmReply'
pair. Slaves consume 'AvalonMmBus' (on the master → slave leg) and
produce 'AvalonMmReply' (on the slave → master leg); the SoC
decoder builds one of each per slave per cycle.

Why not model the full Avalon-MM superset? Burst, lock, debugaccess,
master-id, wait-cycle parameters, pipelined readdata etc. all exist
in the standard but none of the IP we integrate in phase 1 drives
or consumes them. Extending this module when we need them is
straightforward; over-engineering now would add noise to the core →
slave contract without any caller benefit.

The master-side shape here is intentionally identical to what was
previously called @JtagUartBus@ — 'Riski5.JtagUart' now re-exports
it under that name for source compatibility while this module owns
the canonical definition.
-}
module Riski5.AvalonMm (
  -- * Master → slave
  AvalonMmBus (..),
  mkAvalonMmBus,

  -- * Slave → master
  AvalonMmReply (..),
  mkAvalonMmReply,

  -- * Helpers for Verilog wrappers
  avRead,
  avWrite,
) where

import Clash.Prelude hiding ((&&))

{- | Master-side view of an Avalon-MM slave transaction exposed on
the SoC boundary for a single slave. The SoC's address decoder
fills one of these per cycle: @ambSel@ is the slave-select the
decoder derived from the bus address; the other fields carry the
same common bus signals every slave sees.

Hardware translation (done in @pkgs\/riski5-core\/package.nix@'s
@riski5_top.v@ wrapper):

@
  av_chipselect  = ambSel
  av_address     = ambAddr  -- sliced to the IP's address width
  av_writedata   = ambWdata
  av_byteenable  = ambBe
  av_write_n     = ~(ambSel && (ambBe /= 0))
  av_read_n      = ~(ambSel && ambRe)
@

Simulation models (see 'Riski5.JtagUart.jtagUartSim') consume the
same record directly, no Verilog wrapper involved.
-}
data AvalonMmBus = AvalonMmBus
  { ambSel :: Bool
  -- ^ address-decoded select for this slave (@av_chipselect@)
  , ambAddr :: BitVector 32
  {- ^ byte address (caller ensures this is in the slave's window
  when @ambSel@ is high). The Verilog wrapper slices this down
  to the IP's native address width.
  -}
  , ambWdata :: BitVector 32
  -- ^ write data (@av_writedata@)
  , ambBe :: BitVector 4
  -- ^ byte-enable; @0@ means no write this cycle (@av_byteenable@)
  , ambRe :: Bool
  -- ^ read enable (derives @av_read_n@ when combined with @ambSel@)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- | Bundle five parallel signals into a single 'Signal dom AvalonMmBus'.
Thin helper so slave-driving code in 'Riski5.Soc' (and future
SoCs in the core-family work) reads as @mkAvalonMmBus sel addr wd be re@
instead of the wordier applicative pattern.
-}
mkAvalonMmBus ::
  Signal dom Bool ->
  Signal dom (BitVector 32) ->
  Signal dom (BitVector 32) ->
  Signal dom (BitVector 4) ->
  Signal dom Bool ->
  Signal dom AvalonMmBus
mkAvalonMmBus selS addrS wdataS beS reS =
  AvalonMmBus
    <$> selS
    <*> addrS
    <*> wdataS
    <*> beS
    <*> reS

{- | Slave → master reply channel. A slave that finishes its
transaction in the same cycle the master presented the request
returns @AvalonMmReply rdata True@. Multi-cycle slaves (the SDRAM
controller during a burst, the JTAG UART on the first cycle of
every Avalon-MM transaction) return @ready = False@ until they
latch the request, and the SoC's stall logic freezes the core
accordingly.
-}
data AvalonMmReply = AvalonMmReply
  { armRdata :: BitVector 32
  -- ^ read data (@av_readdata@); undefined on cycles the master isn't reading
  , armReady :: Bool
  -- ^ transaction accepted this cycle (@~av_waitrequest@)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

-- | Symmetric counterpart to 'mkAvalonMmBus' for the return leg.
mkAvalonMmReply ::
  Signal dom (BitVector 32) ->
  Signal dom Bool ->
  Signal dom AvalonMmReply
mkAvalonMmReply rdS rdyS = AvalonMmReply <$> rdS <*> rdyS

-- * Helpers for Verilog wrappers ----------------------------------

{- | Derive the active-high @av_read@ strobe for an Avalon-MM slave
from the master-side bus tap. Typical wrappers then negate this to
produce the slave IP's @av_read_n@. Kept here so every wrapper
agrees on the same definition.
-}
avRead :: AvalonMmBus -> Bool
avRead AvalonMmBus {..} = ambSel && ambRe

{- | Active-high @av_write@ strobe. A write is meaningful only when
any byte-enable bit is set, so we key off @ambBe /= 0@ rather than
introducing a separate @we@ field.
-}
avWrite :: AvalonMmBus -> Bool
avWrite AvalonMmBus {..} = ambSel && ambBe /= 0
