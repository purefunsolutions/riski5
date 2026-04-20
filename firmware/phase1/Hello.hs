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
Description : Phase-1B/1C "Hello + SRAM self-test" firmware.

Boots, initialises the HD44780 LCD, runs a SRAM round-trip self-
test against the off-chip 512 KB IS61LV25616-class chip, and then
displays the result on the LCD itself (no counters, no scrolling
— the LCD doubles as our debug console for this milestone).

LCD layout:

  Line 1: \"riski5: SRAM OK\" / \"riski5: SRAM ERR\"
  Line 2: \"got=XXXX exp=YYYY\"        (XXXX = read result, YYYY = expected)

LEDs (one-shot, written once at boot — no spin-loop overlay):

  LEDR[17] = SRAM round-trip succeeded
  LEDG[8]  = SRAM round-trip failed
-}
module Hello (
  helloFirmware,
  helloFirmwareWords,
) where

import Clash.Prelude (BitVector, Signed)
import Control.Monad (forM_)
import Data.Bits ((.|.))
import Data.Either qualified as DE
import Data.Int (Int32)
import Riski5.Asm
import Riski5.ISA
import Prelude (Int, ($), (.))
import Prelude qualified as P

-- * Top-level program ----------------------------------------------

helloFirmware :: Asm ()
helloFirmware = do
  -- Address-register setup.
  loadAddr uartReg 0x1000_0000
  loadAddr lcdReg 0x1000_0040
  loadAddr gpioReg 0x1000_0020
  loadAddr sramReg 0x2000_0000

  -- LEDs cleared at boot.
  ledrSet 0
  ledgSet 0

  -- HD44780 power-on wake sequence.
  delayCycles 1_000_000
  lcdCmdRaw 0x30
  delayCycles 250_000
  lcdCmdRaw 0x30
  delayCycles 5_000
  lcdCmdRaw 0x30
  delayCycles 5_000

  -- HD44780 normal init.
  lcdCmd 0x38
  lcdCmd 0x0C
  lcdCmd 0x06
  lcdCmd 0x01
  delayCycles 200_000

  -- UART banner so we know the core booted.
  uartString "hello, world\n"

  -- SRAM round-trip self-test (T30). Single-address: write 0xA5A5
  -- to base, settle, read back twice (controller registers
  -- SRAM_DQ_I one cycle on hardware-timing-closure grounds — see
  -- Riski5.Sram). Display the result on the LCD, light an LED.
  li scratchReg 0xA5A5
  sh sramReg scratchReg 0
  delayCycles 100
  lhu resultReg sramReg 0
  lhu resultReg sramReg 0

  li scratchReg 0xA5A5
  sramOk <- labelUnplaced
  beq resultReg scratchReg sramOk

  -- Failure path: light LEDG[8] and write \"riski5: SRAM ERR\".
  ledgSet 0x100
  lcdCmd 0x80
  lcdString "riski5: SRAM ERR"
  sramAfter <- labelUnplaced
  j sramAfter

  placeAt sramOk
  -- Success path: light LEDR[17] and write \"riski5: SRAM OK\".
  ledrSet 0x20000
  lcdCmd 0x80
  lcdString "riski5: SRAM OK "

  placeAt sramAfter

  -- Line 2: a fixed status line.
  lcdCmd 0xC0
  lcdString " expected A5A5  "

  spin <- label
  j spin

helloFirmwareWords :: [BitVector 32]
helloFirmwareWords =
  DE.fromRight
    (P.error "helloFirmware failed to assemble")
    (assemble helloFirmware)

-- * Convenience registers ------------------------------------------

uartReg, lcdReg, gpioReg, sramReg, tmpReg, delayReg, scratchReg, resultReg, hexReg :: Reg
uartReg = x20
lcdReg = x21
gpioReg = x23
sramReg = x15
tmpReg = x22
delayReg = x24
scratchReg = x31
resultReg = x14
hexReg = x13

-- * Addressing helper ----------------------------------------------

loadAddr :: Reg -> Int -> Asm ()
loadAddr rd addr = li rd (P.fromIntegral addr)

-- * Delay helper --------------------------------------------------

delayCycles :: Int -> Asm ()
delayCycles n = do
  li delayReg (P.fromIntegral (n `P.div` 2) :: Int32)
  loop <- label
  addi delayReg delayReg (-1 :: Signed 12)
  bne delayReg x0 loop

-- * LCD helpers ----------------------------------------------------

lcdWait :: Asm ()
lcdWait = do
  waitL <- label
  lw tmpReg lcdReg 8
  bne tmpReg x0 waitL

lcdCmd :: Int -> Asm ()
lcdCmd cmdByte = do
  lcdWait
  addi tmpReg x0 (P.fromIntegral cmdByte :: Signed 12)
  sw lcdReg tmpReg 4

lcdCmdRaw :: Int -> Asm ()
lcdCmdRaw cmdByte = do
  addi tmpReg x0 (P.fromIntegral cmdByte :: Signed 12)
  sw lcdReg tmpReg 4

lcdChar :: Int -> Asm ()
lcdChar ch = do
  lcdWait
  addi tmpReg x0 (P.fromIntegral ch :: Signed 12)
  sw lcdReg tmpReg 0

-- | Write the literal characters of @str@ to the LCD via DATA writes.
lcdString :: P.String -> Asm ()
lcdString = P.mapM_ (lcdChar . P.fromEnum)

{- | Write the four-character hex representation of the low 16 bits
of @rd@ to the LCD. Each nibble is masked, branched on threshold
to pick @0@..@9@ vs @A@..@F@, and emitted via @lcdChar@'s polled
path. Uses @hexReg@ as a scratch.
-}
lcdHex16 :: Reg -> Asm ()
lcdHex16 rd =
  -- Walk nibbles from MSB (12) to LSB (0).
  forM_ [12, 8, 4, 0 :: Int] $ \shift -> do
    -- Extract nibble: (rd >> shift) & 0xF.
    if shift P.== 0
      then add hexReg x0 rd
      else srli hexReg rd (P.fromIntegral shift)
    andi hexReg hexReg 0xF
    -- If nibble < 10, emit '0' + nibble; else emit 'A' + (nibble - 10).
    addi tmpReg x0 10
    isAlpha <- labelUnplaced
    bge hexReg tmpReg isAlpha
    -- Digit branch: hexReg += '0'.
    addi hexReg hexReg (P.fromIntegral (P.fromEnum '0') :: Signed 12)
    afterChar <- labelUnplaced
    j afterChar
    placeAt isAlpha
    -- Alpha branch: hexReg += 'A' - 10.
    addi hexReg hexReg (P.fromIntegral (P.fromEnum 'A' P.- 10) :: Signed 12)
    placeAt afterChar
    -- Emit hexReg as a character.
    lcdWait
    sw lcdReg hexReg 0

-- * GPIO helpers ---------------------------------------------------

ledrSet :: Int -> Asm ()
ledrSet bits = do
  li scratchReg (P.fromIntegral bits :: Int32)
  sw gpioReg scratchReg 0

ledgSet :: Int -> Asm ()
ledgSet bits = do
  li scratchReg (P.fromIntegral bits :: Int32)
  sw gpioReg scratchReg 4

-- * UART helpers ---------------------------------------------------

uartChar :: Int -> Asm ()
uartChar ch = do
  addi tmpReg x0 (P.fromIntegral ch :: Signed 12)
  sw uartReg tmpReg 0

uartString :: P.String -> Asm ()
uartString = P.mapM_ (uartChar . P.fromEnum)
