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
  jtagUartSim,
  jtagUartAlteraSim,
) where

import Clash.Prelude hiding ((&&))
import Clash.Prelude qualified as CP
import Riski5.MemMap (jtagUartBase)

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

{- |
Altera-IP-faithful simulation model. Unlike 'jtagUartSim' (which
treats the UART as an infinite, always-ready FIFO), this model
reproduces the two silicon behaviours CM-4 uncovered empirically
and fixed in the CoreMark port:

  1. __Finite 64-byte TX FIFO.__ Writes to DATA accept immediately
     as long as the FIFO has space. Once full, @av_waitrequest@ is
     asserted (returned as @ready=False@) until the FIFO drains
     enough for the pending write to land.

  2. __Drain-gap requirement.__ Empirically, the real IP's internal
     drain FSM advances only on cycles where the master is __not__
     asserting a write transaction. Holding @av_write=1@
     continuously across the FIFO-full waitrequest cycles — which
     is exactly what happens when the riski5 core stalls on a
     bus waitrequest — prevents the drain from advancing and the
     IP stays stuck indefinitely.

     Modelled here by gating drain on @!wr@: any cycle without an
     active write transaction drains one byte from the FIFO; any
     cycle with an active write transaction does not. Back-to-back
     writes with no gap therefore fill the FIFO in 64 cycles, hit
     waitrequest, and deadlock (matching silicon). A polling
     pattern that reads the WSPACE register between writes — the
     CM-2 port's @uart_send_char@ — naturally inserts
     @!wr@ cycles on every read and avoids the deadlock.

The CONTROL register's WSPACE field (bits [31:16], per Altera's
spec) is modelled as @64 - fifoCount@ so firmware can poll it.

The output contract differs slightly from 'jtagUartSim': in
addition to @(rdata, txByte)@, 'jtagUartAlteraSim' returns the
@ready@ signal so the sim wrapper can plumb it back into the SoC
as @siUartReady@. Tests that wire this in watch the core stall
naturally under the finite-FIFO back-pressure.
-}
jtagUartAlteraSim ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  Signal dom Bool ->
  Signal dom (BitVector 32) ->
  Signal dom (BitVector 32) ->
  Signal dom (BitVector 4) ->
  Signal dom Bool ->
  ( Signal dom (BitVector 32) -- rdata
  , Signal dom (Maybe (BitVector 8)) -- txByte (emitted at accept)
  , Signal dom Bool -- ready = !waitrequest
  )
jtagUartAlteraSim selS addrS wdataS beS _reS =
  (rdataS, txS, readyS)
 where
  isDataS = (\s a -> s && a == jtagUartBase + 0) <$> selS <*> addrS
  isCtrlS = (\s a -> s && a == jtagUartBase + 4) <$> selS <*> addrS

  wrS = (\isD be -> isD && be /= 0) <$> isDataS <*> beS

  fifoCountS :: Signal dom (Unsigned 7)
  fifoCountS = register 0 fifoCountNextS

  fullS = (\c -> c == 64) <$> fifoCountS

  waitreqS = (\wr full -> wr && full) <$> wrS <*> fullS
  readyS = CP.not <$> waitreqS

  -- Accept: bus is writing AND FIFO has space.
  acceptS = (\wr full -> wr && CP.not full) <$> wrS <*> fullS

  -- Drain: bus is NOT writing this cycle AND FIFO non-empty. One
  -- byte per !wr cycle — see the module-header rationale.
  drainS = (\wr cnt -> CP.not wr && cnt > 0) <$> wrS <*> fifoCountS

  fifoCountNextS =
    ( \cnt accept drain -> case (accept, drain) of
        (True, _) -> cnt + 1
        (False, True) -> cnt - 1
        (False, False) -> cnt
    )
      <$> fifoCountS
      <*> acceptS
      <*> drainS

  -- Byte tap: observed when a write commits into the FIFO. Tests
  -- check this stream against the firmware's intended output.
  txS =
    ( \accept wdata ->
        if accept then Just (slice d7 d0 wdata) else Nothing
    )
      <$> acceptS
      <*> wdataS

  -- CONTROL read: WSPACE in bits [31:16] = 64 - fifoCount.
  -- DATA read: zero (RX FIFO always empty in sim).
  rdataS =
    ( \isC cnt ->
        if isC
          then
            let wspace :: BitVector 32
                wspace = resize (pack (64 - cnt :: Unsigned 7))
             in wspace `shiftL` 16
          else 0
    )
      <$> isCtrlS
      <*> fifoCountS
