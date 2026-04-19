-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Riski5.Lcd
Description : Minimal HD44780 (16×2 character LCD) controller.

The DE2 board carries a 16×2 HD44780-compatible character LCD
wired to FPGA pins @LCD_DATA[7:0]@, @LCD_RS@, @LCD_RW@, @LCD_EN@,
@LCD_ON@, and @LCD_BLON@. This module drives those pins from a
small MMIO window; firmware is responsible for running the power-
on initialisation sequence itself (function-set, display-on,
entry-mode, clear) via a few sequential MMIO writes to the
@DATA@ and @CMD@ registers.

Phase-1 register layout (word-offsets within the 32-byte MMIO
window from 'Riski5.MemMap'):

@
  offset 0 — DATA   : writing a byte with @RS=1@ on the LCD side
                      strobes the E pin and presents the character
                      on the 8-bit data bus.
  offset 4 — CMD    : as DATA, but @RS=0@ (commands).
  offset 8 — STATUS : bit 0 = controller busy (firmware polls).
@

Timing at the default 50 MHz clock:

  * @E@ must be held high for at least 230 ns → 12 cycles; we use
    16 to leave margin.
  * Post-write idle time for most commands is 37 µs → 1 850 cycles;
    clear / return-home need 1.52 ms → 76 000 cycles. Phase-1
    firmware always uses the conservative 2 000-cycle idle (matches
    most commands) and hand-inserts longer waits around the clear
    / home calls in its boot sequence.

Real-hardware functional verification happens once the board is
flashed; the Clash-side test here confirms the E-strobe timing
and pin fan-out.
-}
module Riski5.Lcd (
  lcd,
  LcdPins (..),
) where

import Clash.Prelude hiding (not, (&&), (||))
import Riski5.MemMap (lcdBase)

{- |
Bundle of LCD pins exposed by the controller. Wired straight to
the DE2 top-entity outputs by @Riski5.Soc@ / @app\/Top.hs@.
-}
data LcdPins = LcdPins
  { lcdData :: BitVector 8
  , lcdRs :: Bit
  , lcdRw :: Bit
  , lcdE :: Bit
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- |
Internal state of the controller FSM.
-}
data LcdState
  = -- | Nothing in flight; outputs @E=0@ and the last-latched data.
    Idle
  | -- | Holding @E@ high; @count@ cycles remaining.
    Pulse {count :: BitVector 16}
  | {- | Enforcing post-write idle; @count@ cycles remaining before
    transitioning back to 'Idle' (clears the busy flag).
    -}
    Wait {count :: BitVector 16}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

-- * Timing constants -----------------------------------------------

{- | Duration of the @E@ high pulse in clock cycles at 50 MHz.
Spec requires ≥ 230 ns; we use 16 cycles (320 ns) for margin.
-}
pulseCycles :: BitVector 16
pulseCycles = 16

{- | Idle cycles after @E@ goes low, before firmware can write again.
Covers the 37 µs \"most commands\" case at 50 MHz (2 000 cycles).
Firmware manually inserts longer waits around clear / home, which
need 1.52 ms.
-}
idleCycles :: BitVector 16
idleCycles = 2000

-- * MMIO offsets ---------------------------------------------------

offsetData, offsetCmd, offsetStatus :: BitVector 32
offsetData = lcdBase + 0
offsetCmd = lcdBase + 4
offsetStatus = lcdBase + 8

-- * Controller -----------------------------------------------------

{- |
Single-byte HD44780 controller. @lcd sel addr wdata be _readEn@
latches any firmware write to the DATA or CMD register, asserts
the @E@ pin for 'pulseCycles', then waits 'idleCycles' before
dropping @busy@.

Reads of the STATUS register return the busy flag in bit 0; other
reads return zero.
-}
lcd ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  -- | slave-select
  Signal dom Bool ->
  -- | MMIO address (byte-granular within the LCD window)
  Signal dom (BitVector 32) ->
  -- | MMIO write data
  Signal dom (BitVector 32) ->
  -- | byte-enable (0 = no write)
  Signal dom (BitVector 4) ->
  -- | read enable (unused)
  Signal dom Bool ->
  -- | @(rdata, pins)@
  ( Signal dom (BitVector 32)
  , Signal dom LcdPins
  )
lcd selS addrS wdataS beS _readEnS =
  (rdataS, pinsS)
 where
  -- State FSM
  stateS :: Signal dom LcdState
  stateS = register Idle nextStateS

  -- Latched data + RS of the transaction currently in flight.
  dataS :: Signal dom (BitVector 8)
  dataS = register 0 nextDataS

  rsS :: Signal dom Bit
  rsS = register low nextRsS

  -- Decoded MMIO write: a byte-enabled write to DATA or CMD begins
  -- a new transaction.
  writeReqS =
    ( \sel addr be wdata st ->
        let isData = sel && addr == offsetData && be /= 0
            isCmd = sel && addr == offsetCmd && be /= 0
            busy = case st of
              Idle -> False
              _ -> True
         in if (isData || isCmd) && not busy
              then Just (isData, slice d7 d0 wdata)
              else Nothing
    )
      <$> selS
      <*> addrS
      <*> beS
      <*> wdataS
      <*> stateS

  -- FSM next-state logic.
  nextStateS =
    ( \req st ->
        case st of
          Idle -> case req of
            Just _ -> Pulse {count = pulseCycles - 1}
            Nothing -> Idle
          Pulse c
            | c == 0 -> Wait {count = idleCycles - 1}
            | otherwise -> Pulse {count = c - 1}
          Wait c
            | c == 0 -> Idle
            | otherwise -> Wait {count = c - 1}
    )
      <$> writeReqS
      <*> stateS

  -- When a write request is accepted in Idle, latch its data + RS.
  nextDataS =
    ( \req st d ->
        case (st, req) of
          (Idle, Just (_, bits)) -> bits
          _ -> d
    )
      <$> writeReqS
      <*> stateS
      <*> dataS

  nextRsS =
    ( \req st r ->
        case (st, req) of
          (Idle, Just (isData, _)) -> if isData then high else low
          _ -> r
    )
      <$> writeReqS
      <*> stateS
      <*> rsS

  -- E is high only during the Pulse phase.
  eS =
    ( \st -> case st of
        Pulse {} -> high
        _ -> low
    )
      <$> stateS

  pinsS :: Signal dom LcdPins
  pinsS =
    (\d r e -> LcdPins {lcdData = d, lcdRs = r, lcdRw = low, lcdE = e})
      <$> dataS
      <*> rsS
      <*> eS

  -- STATUS register: bit 0 = busy.
  rdataS =
    ( \sel addr st ->
        if sel && addr == offsetStatus
          then case st of
            Idle -> 0
            _ -> 1
          else 0
    )
      <$> selS
      <*> addrS
      <*> stateS
