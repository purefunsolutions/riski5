-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Riski5.Gpio
Description : Simple MMIO GPIO block (LEDs in, switches/keys out).

The DE2 board has 18 red LEDs, 9 green LEDs, 4 momentary keys, and
18 switches. Phase-1 firmware uses them for liveness indication
and whatever debug scaffolding the moment needs.

Register layout inside the 32-byte MMIO window from
'Riski5.MemMap':

@
  offset 0x00 — LEDR  (18 bits, write-only, bits 17..0 drive LEDR[17:0])
  offset 0x04 — LEDG  (9 bits, write-only, bits 8..0 drive LEDG[8:0])
  offset 0x08 — SW    (18 bits, read-only, current switch positions)
  offset 0x0C — KEY   (4 bits, read-only, active-LOW push buttons)
@

Writes commit on the next clock edge; reads are combinational over
the latched output registers (LEDs) and the raw pin signals
(switches / keys).
-}
module Riski5.Gpio (
  gpio,
  GpioIn (..),
  GpioOut (..),
) where

import Clash.Prelude hiding ((&&))
import Riski5.MemMap (gpioBase)

{- |
Board-level inputs sampled by the GPIO block. Wired to the DE2 top
entity's SW[17:0] and KEY[3:0] pins by @app/Top.hs@.
-}
data GpioIn = GpioIn
  { gpiSwitches :: BitVector 18
  , gpiKeys :: BitVector 4
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

-- | Board-level outputs the GPIO block drives.
data GpioOut = GpioOut
  { gpoLedR :: BitVector 18
  , gpoLedG :: BitVector 9
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- |
MMIO GPIO block. @gpio sel addr wdata be _readEn gpIn@ returns
@(rdata, gpOut)@. Writes land in the LEDR / LEDG registers on the
next clock edge; reads return the current board-level switch /
key state combinationally.
-}
gpio ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  -- | slave-select
  Signal dom Bool ->
  -- | address (byte-granular)
  Signal dom (BitVector 32) ->
  -- | write data
  Signal dom (BitVector 32) ->
  -- | byte-enable
  Signal dom (BitVector 4) ->
  -- | read enable (unused)
  Signal dom Bool ->
  -- | board inputs
  Signal dom GpioIn ->
  -- | @(rdata, gpOut)@
  ( Signal dom (BitVector 32)
  , Signal dom GpioOut
  )
gpio selS addrS wdataS beS _readEnS gpInS = (rdataS, gpOutS)
 where
  -- Latched LED registers.
  ledRS = register 0 nextLedR
  ledGS = register 0 nextLedG

  isWriteTo off = (\s a be -> s && a == gpioBase + off && be /= 0) <$> selS <*> addrS <*> beS

  writeLedR = isWriteTo 0x00
  writeLedG = isWriteTo 0x04

  nextLedR = (\wr w old -> if wr then slice d17 d0 w else old) <$> writeLedR <*> wdataS <*> ledRS
  nextLedG = (\wr w old -> if wr then slice d8 d0 w else old) <$> writeLedG <*> wdataS <*> ledGS

  -- Combinational reads: LEDs from the latched register, SW and KEY
  -- straight from the current pin state (no synchronizer — good
  -- enough for phase-1 polling).
  rdataS =
    ( \sel addr led_r led_g (GpioIn sw ky) ->
        if sel
          then case addr - gpioBase of
            0x00 -> zeroExtend led_r
            0x04 -> zeroExtend led_g
            0x08 -> zeroExtend sw
            0x0C -> zeroExtend ky
            _ -> 0
          else 0
    )
      <$> selS
      <*> addrS
      <*> ledRS
      <*> ledGS
      <*> gpInS

  gpOutS = (\r g -> GpioOut {gpoLedR = r, gpoLedG = g}) <$> ledRS <*> ledGS
