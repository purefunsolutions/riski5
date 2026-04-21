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
  -- SDRAM base = 0x8000_0000 — top bit set, so li expands to
  -- LUI 0x80000 + ADDI 0. The 8 MB SDRAM is decoded from upper
  -- 4 bits 0x8 by Bus.hs's address decoder (see Riski5.MemMap).
  loadAddr sdramReg 0x8000_0000

  -- LEDs cleared at boot.
  ledrSet 0
  ledgSet 0

  -- UART banner so we know the core booted. The LCD controller is
  -- running its own Vcc-settle + HD44780 wake + init sequence in
  -- the background; firmware's first LCD write will spin on the
  -- busy flag until that completes.
  uartString "hello, world\n"

  -- ===== RV32M smoke tests (Phase 2B on silicon) =====
  -- Fold the per-op outcome into a single summary bit (in hexReg).
  -- UART stays compact — the Altera JTAG UART IP's 64-byte TX FIFO
  -- back-pressures the core once exceeded, and prior runs with a
  -- line per op tripped that boundary and stalled the downstream
  -- SRAM / LCD diagnostics. M-ext correctness itself is already
  -- validated in sim + formal; the on-silicon run just has to
  -- confirm the FU is wired correctly.
  --
  -- hexReg accumulates "failures-so-far"; any nonzero at the end
  -- flips the UART line to M-ext FAIL.
  add hexReg x0 x0 -- hexReg := 0

  -- MUL 7 * 6 = 42
  li tmpReg 7
  li scratchReg 6
  mul resultReg tmpReg scratchReg
  addi tmpReg x0 42
  xor_ resultReg resultReg tmpReg
  or_ hexReg hexReg resultReg

  -- DIVU 100 / 7 = 14
  li tmpReg 100
  li scratchReg 7
  divu resultReg tmpReg scratchReg
  addi tmpReg x0 14
  xor_ resultReg resultReg tmpReg
  or_ hexReg hexReg resultReg

  -- REMU 100 % 7 = 2
  li tmpReg 100
  li scratchReg 7
  remu resultReg tmpReg scratchReg
  addi tmpReg x0 2
  xor_ resultReg resultReg tmpReg
  or_ hexReg hexReg resultReg

  -- MULH — signed, (-1)*(-1) high 32 = 0.
  li tmpReg (-1)
  li scratchReg (-1)
  mulh resultReg tmpReg scratchReg
  or_ hexReg hexReg resultReg

  -- DIVU by zero → Q = 0xFFFFFFFF.
  li tmpReg 42
  addi scratchReg x0 0
  divu resultReg tmpReg scratchReg
  addi tmpReg x0 (-1)
  xor_ resultReg resultReg tmpReg
  or_ hexReg hexReg resultReg

  -- Emit one summary line.
  mextFailL <- labelUnplaced
  bne hexReg x0 mextFailL
  uartString "M-ext OK\n"
  afterMextL <- labelUnplaced
  j afterMextL
  placeAt mextFailL
  uartString "M-ext FAIL\n"
  placeAt afterMextL

  -- Reset the SRAM failure accumulator (hexReg) — the M-ext block
  -- above left it nonzero iff M-ext failed; the LCD summary below
  -- only reflects SRAM status.
  add hexReg x0 x0

  -- SRAM half-word round-trip (T30). Writes 0xA5A5 to the first
  -- SRAM half-word, reads back via LHU, compares to the expected
  -- pattern.
  li scratchReg 0xA5A5
  sh sramReg scratchReg 0
  lhu resultReg sramReg 0

  li scratchReg 0xA5A5
  sramHalfOk <- labelUnplaced
  beq resultReg scratchReg sramHalfOk

  -- Half-word failure path: flag it in hexReg, log the bad value.
  li tmpReg 1
  or_ hexReg hexReg tmpReg
  uartString "SRAM ERR got=0x"
  uartHex16 resultReg
  uartChar 0x0A
  sramHalfAfter <- labelUnplaced
  j sramHalfAfter

  placeAt sramHalfOk
  uartString "SRAM OK\n"

  placeAt sramHalfAfter

  -- T31a: 32-bit SRAM round-trip. The SRAM FSM now splits the access
  -- into two back-to-back half-word transactions with pulse + recovery
  -- for writes and a registered-input word-read combine for loads;
  -- firmware just sees a 4-cycle SW and 3-cycle LW through the
  -- ready-stall path. Tests SRAM[0..3] concurrently with the
  -- half-word test above (lo half has 0xA5A5, hi half is fresh).
  -- Use an alternating-bit pattern far from the half-word test to
  -- stress byte-lane routing across the full word.
  li scratchReg 0xDEADBEEF
  sw sramReg scratchReg 4
  lw resultReg sramReg 4

  li scratchReg 0xDEADBEEF
  sramWordOk <- labelUnplaced
  beq resultReg scratchReg sramWordOk

  -- Word failure path: flag it in hexReg, log both halves.
  li tmpReg 2
  or_ hexReg hexReg tmpReg
  uartString "SRAM W32 ERR got=0x"
  srli tmpReg resultReg 16
  uartHex16 tmpReg
  uartHex16 resultReg
  uartChar 0x0A
  sramWordAfter <- labelUnplaced
  j sramWordAfter

  placeAt sramWordOk
  uartString "SRAM W32 OK\n"

  placeAt sramWordAfter

  -- T38: SDRAM 32-bit round-trip. Writes 0xCAFEBABE to SDRAM[0..3]
  -- via the Altera SDRAM Controller IP, reads it back via LW, and
  -- reports on the UART. Exercises the full path:
  --   core bus → Riski5.Sdram adapter FSM → Avalon-MM slave
  --   → altera_avalon_new_sdram_controller IP → DRAM_* pins on the
  --   off-chip IS42S16400 chip, round-tripping back through the
  --   IP's FIFO + za_data.
  li scratchReg 0xCAFEBABE
  sw sdramReg scratchReg 0
  lw resultReg sdramReg 0

  li scratchReg 0xCAFEBABE
  sdramOk <- labelUnplaced
  beq resultReg scratchReg sdramOk

  -- Failure path: flag it in hexReg, log the bad value.
  li tmpReg 4
  or_ hexReg hexReg tmpReg
  uartString "SDRAM ERR got=0x"
  srli tmpReg resultReg 16
  uartHex16 tmpReg
  uartHex16 resultReg
  uartChar 0x0A
  sdramAfter <- labelUnplaced
  j sdramAfter

  placeAt sdramOk
  uartString "SDRAM OK\n"

  placeAt sdramAfter

  -- Combined SRAM/SDRAM summary for LCD + LEDs.
  sramAllOk <- labelUnplaced
  beq hexReg x0 sramAllOk

  -- Any failure: light LEDG[8] and report on LCD.
  ledgSet 0x100
  lcdCmd 0x80
  lcdString "riski5: MEM ERR "
  sramLcdAfter <- labelUnplaced
  j sramLcdAfter

  placeAt sramAllOk
  -- All three memory tests green: light LEDR[17], banner on LCD.
  ledrSet 0x20000
  lcdCmd 0x80
  lcdString "riski5: MEM OK  "

  placeAt sramLcdAfter

  -- Line 2: a fixed status line showing the three test patterns.
  lcdCmd 0xC0
  lcdString "SRAM+SDRAM:CAFE "

  spin <- label
  j spin

helloFirmwareWords :: [BitVector 32]
helloFirmwareWords =
  DE.fromRight
    (P.error "helloFirmware failed to assemble")
    (assemble helloFirmware)

-- * Convenience registers ------------------------------------------

uartReg, lcdReg, gpioReg, sramReg, sdramReg, tmpReg, scratchReg, resultReg, hexReg :: Reg
uartReg = x20
lcdReg = x21
gpioReg = x23
sramReg = x15
sdramReg = x24
tmpReg = x22
scratchReg = x31
resultReg = x14
hexReg = x13

-- * Addressing helper ----------------------------------------------

loadAddr :: Reg -> Int -> Asm ()
loadAddr rd addr = li rd (P.fromIntegral addr)

-- * LCD helpers ----------------------------------------------------

{- | Spin on the LCD controller's busy flag (STATUS bit 0).
The controller runs its own Vcc-settle / wake / init sequence
at reset and enforces per-command timing internally, so this is
the only synchronisation firmware needs.
-}
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

{- | Print the four-character hex representation of the low 16 bits
of @rd@ over the UART. Same nibble-walk structure as 'lcdHex16'.
-}
uartHex16 :: Reg -> Asm ()
uartHex16 rd =
  forM_ [12, 8, 4, 0 :: Int] $ \shift -> do
    if shift P.== 0
      then add hexReg x0 rd
      else srli hexReg rd (P.fromIntegral shift)
    andi hexReg hexReg 0xF
    addi tmpReg x0 10
    isAlpha <- labelUnplaced
    bge hexReg tmpReg isAlpha
    addi hexReg hexReg (P.fromIntegral (P.fromEnum '0') :: Signed 12)
    afterChar <- labelUnplaced
    j afterChar
    placeAt isAlpha
    addi hexReg hexReg (P.fromIntegral (P.fromEnum 'A' P.- 10) :: Signed 12)
    placeAt afterChar
    sw uartReg hexReg 0
