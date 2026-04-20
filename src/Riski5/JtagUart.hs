-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Riski5.JtagUart
Description : Altera JTAG UART — simulation model + hardware black box.

The Altera JTAG UART IP ships with Quartus and rides the same
USB Blaster cable we already use for flashing; @nios2-terminal@
pairs with it on the host side. We black-box the real IP at
synthesis time and use a minimal functional Clash model for
simulation, so that the same firmware exercises both.

Phase-1 register layout (word-addressable within the 16-byte MMIO
window from 'Riski5.MemMap'):

@
  offset 0 — DATA   : writes push a byte into the TX FIFO; reads
                      pop a byte from the RX FIFO (bit 15 set iff
                      read valid, low byte = character).
  offset 4 — CONTROL: bit 0 = TX-ready (TX FIFO has space); other
                      bits ignored in phase 1.
@

The real Altera IP has a richer layout (write-availability count,
interrupt enables, activity flags). Phase-1 firmware uses only
TX-ready + DATA, so we model that much and extend as needed.
-}
module Riski5.JtagUart (
  JtagUartBus (..),
  jtagUartSim,
) where

import Clash.Prelude hiding ((&&))
import Riski5.MemMap (jtagUartBase)

{- |
Externalised UART slave bus. The SoC exposes these five signals on
its top boundary (via 'Riski5.Soc.soUartBus') instead of owning the
UART implementation internally. A test harness plugs 'jtagUartSim'
back in at that boundary; a synthesis wrapper plugs the real Altera
@altera_avalon_jtag_uart@ IP in at the same boundary. Keeping the
seam at the bus — rather than inside the SoC — is what lets sim and
hardware diverge cleanly without the core knowing which implementation
it is talking to.
-}
data JtagUartBus = JtagUartBus
  { ubSel :: Bool
  -- ^ address-decoded select: high iff the current bus transaction
  -- targets the UART MMIO window
  , ubAddr :: BitVector 32
  -- ^ byte address (caller ensures this is in the UART window when
  -- @ubSel@ is high)
  , ubWdata :: BitVector 32
  -- ^ write data (low 8 bits meaningful for DATA writes)
  , ubBe :: BitVector 4
  -- ^ byte-enable; @0@ means no write this cycle
  , ubRe :: Bool
  -- ^ read enable
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- |
Altera's @altera_avalon_jtag_uart@ IP is an Avalon-MM slave that
registers the write-data one cycle after the master first presents
@av_chipselect@ + @av_write_n@. In Avalon-MM terms this shows up as
@av_waitrequest@ being asserted for the first cycle of every
transaction — the master must hold signals until waitrequest
deasserts. We plumb the complement of @av_waitrequest@ back into the
SoC as this @ready@ signal so the bus-level stall logic in
'Riski5.Soc' can freeze the core for that one cycle.
'jtagUartSim' always returns @True@ here (no latency) so simulation
sees a single-cycle path; the real IP in the Verilog wrapper drives
it properly.
-}


{- |
Simulation-only functional model of the JTAG UART. The
synthesis-time Altera IP black-box gets added alongside in T16–T17
(when we hook up the Quartus flow).

@jtagUartSim addr wdata byteEn readEn@ returns @(rdata, txByte)@
where @txByte@ is @Just c@ on cycles that firmware pushed a byte
into the TX FIFO (simulation harness collects these and compares
them against the expected output string).
-}
jtagUartSim ::
  forall dom.
  -- | slave-select (high iff this MMIO access targets the UART)
  Signal dom Bool ->
  -- | byte address within the UART window (0 or 4)
  Signal dom (BitVector 32) ->
  -- | write data
  Signal dom (BitVector 32) ->
  -- | byte-enable (0 = no write)
  Signal dom (BitVector 4) ->
  -- | read enable (unused — reads are always valid for the UART)
  Signal dom Bool ->
  {- | @(readData, txByte)@. @txByte@ is @Just byte@ the cycle
  firmware writes to the DATA register, @Nothing@ otherwise.
  -}
  ( Signal dom (BitVector 32)
  , Signal dom (Maybe (BitVector 8))
  )
jtagUartSim selS addrS wdataS beS _ =
  (rdataS, txS)
 where
  -- Decode the absolute MMIO address into DATA vs CONTROL.
  isDataS = (\s a -> s && a == jtagUartBase + 0) <$> selS <*> addrS
  isCtrlS = (\s a -> s && a == jtagUartBase + 4) <$> selS <*> addrS

  -- DATA reads always return 0 in simulation (RX FIFO empty).
  -- CONTROL reads return 1 (bit 0 = TX-ready is always asserted —
  -- the sim FIFO is infinite).
  rdataS = (\c -> if c then 1 else 0) <$> isCtrlS

  -- TX: any byte-enabled write to DATA pushes its low 8 bits out.
  txS =
    ( \isData wdata be ->
        if isData && be /= 0
          then Just (slice d7 d0 wdata)
          else Nothing
    )
      <$> isDataS
      <*> wdataS
      <*> beS
