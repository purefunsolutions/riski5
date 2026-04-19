-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Hello
Description : Phase-1B "Hello from Riski5" firmware.

An @Riski5.Asm@ program that:

  1. Sets up base registers pointing at the UART and LCD MMIO
     regions.
  2. Runs the HD44780 init sequence (function-set, display-on,
     entry-mode, clear).
  3. Writes @Hello from Riski5@ to the first line of the LCD.
  4. Writes @hello, world\n@ to the JTAG UART.
  5. Spins forever so the board output remains visible.

Intentionally does not use interrupts, CSRs, or the data memory —
every byte of output flows through straight-line MMIO stores so
the firmware stays readable and easy to reason about on hardware.
Assembles to roughly 150 instructions; @Top.hs@ bumps its imem
size accordingly.
-}
module Hello (
  helloFirmware,
  helloFirmwareWords,
) where

import Clash.Prelude (BitVector, Signed)
import Data.Either qualified as DE
import Riski5.Asm
import Riski5.ISA
import Prelude (Int, ($), (.))
import Prelude qualified as P

-- * Top-level program ----------------------------------------------

-- | The full firmware program.
helloFirmware :: Asm ()
helloFirmware = do
  -- Load the UART and LCD base addresses into dedicated registers so
  -- the subsequent store sequences are one instruction each.
  loadAddr uartReg 0x1000_0000 -- UART DATA
  loadAddr lcdReg 0x1000_0040 -- LCD DATA (offset 0 within window)

  -- HD44780 power-on init: function-set → display-on → entry-mode →
  -- clear. Each command goes through the busy-polled path.
  lcdCmd 0x38 -- function set: 8-bit, 2-line, 5x8 font
  lcdCmd 0x0C -- display on, cursor off, blink off
  lcdCmd 0x06 -- entry mode: increment, no display shift
  lcdCmd 0x01 -- clear display (controller internally waits longer)

  -- Top line of the LCD.
  lcdString "Hello from Riski5"

  -- JTAG UART banner.
  uartString "hello, world\n"

  -- Park the core in a tight loop so the core's retirement signal
  -- keeps toggling (useful for on-board \"alive\" LEDs wired up by
  -- Gpio).
  spin <- label
  j spin

{- | The firmware assembled to 32-bit machine words. Exported so
@Top.hs@, @Emit.hs@, and simulation tests share one assemble call.
-}
helloFirmwareWords :: [BitVector 32]
helloFirmwareWords =
  DE.fromRight
    (P.error "helloFirmware failed to assemble")
    (assemble helloFirmware)

-- * Convenience registers ------------------------------------------

uartReg, lcdReg, tmpReg :: Reg
uartReg = x20
lcdReg = x21
tmpReg = x22

-- * Addressing helper ----------------------------------------------

{- |
Load a 32-bit absolute address into @rd@ using the LUI + ADDI
pattern. Handles the sign-extension adjustment automatically via
'Riski5.Asm.li'.
-}
loadAddr :: Reg -> Int -> Asm ()
loadAddr rd addr = li rd (P.fromIntegral addr)

-- * LCD helpers ----------------------------------------------------

{- | Poll the LCD STATUS register (offset 8 from lcdReg) until bit 0
(busy) clears.
-}
lcdWait :: Asm ()
lcdWait = do
  waitL <- label
  lw tmpReg lcdReg 8
  bne tmpReg x0 waitL

-- | Issue an HD44780 command (RS=0, CMD register at offset 4).
lcdCmd :: Int -> Asm ()
lcdCmd cmdByte = do
  lcdWait
  addi tmpReg x0 (P.fromIntegral cmdByte :: Signed 12)
  sw lcdReg tmpReg 4

-- | Write one character (RS=1, DATA register at offset 0).
lcdChar :: Int -> Asm ()
lcdChar ch = do
  lcdWait
  addi tmpReg x0 (P.fromIntegral ch :: Signed 12)
  sw lcdReg tmpReg 0

-- | Emit LCD writes for an entire string.
lcdString :: P.String -> Asm ()
lcdString = P.mapM_ (lcdChar . P.fromEnum)

-- * UART helpers ---------------------------------------------------

-- | Write a character to the JTAG UART DATA register.
uartChar :: Int -> Asm ()
uartChar ch = do
  addi tmpReg x0 (P.fromIntegral ch :: Signed 12)
  sw uartReg tmpReg 0

-- | Emit UART writes for an entire string.
uartString :: P.String -> Asm ()
uartString = P.mapM_ (uartChar . P.fromEnum)
