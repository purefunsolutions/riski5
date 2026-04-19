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
import Data.Bits ((.|.))
import Data.Either qualified as DE
import Data.Int (Int32)
import Riski5.Asm
import Riski5.ISA
import Prelude (Int, ($), (.))
import Prelude qualified as P

-- * Top-level program ----------------------------------------------

-- | The full firmware program.
helloFirmware :: Asm ()
helloFirmware = do
  -- Load the UART, LCD, and GPIO base addresses into dedicated
  -- registers so the subsequent store sequences are one instr each.
  loadAddr uartReg 0x1000_0000 -- UART DATA
  loadAddr lcdReg 0x1000_0040 -- LCD DATA (offset 0 within window)
  loadAddr gpioReg 0x1000_0020 -- GPIO LEDR (offset 0 within window)

  -- LEDR proof-of-life: bit 0 set as soon as the CPU starts so the
  -- board makes it obvious whether fetch + decode + store + GPIO
  -- MMIO are all working — independent of the LCD path.
  ledrSet 0x01

  -- HD44780 power-on wake sequence (datasheet "Initialization by
  -- instruction" path). Without this, the chip can be left in
  -- 4-bit mode or some other unknown state from whatever previous
  -- design was loaded over JTAG, and our 8-bit Function Set won't
  -- take effect.
  --
  --   wait > 15 ms after Vcc → 1 000 000 cycles at 50 MHz
  --   write 0x30  ;  wait > 4.1 ms → 250 000 cycles
  --   write 0x30  ;  wait > 100 µs → 5 000 cycles
  --   write 0x30  ;  wait > 100 µs → 5 000 cycles
  --   then proceed with the normal busy-polled init.
  delayCycles 1_000_000 -- power-on margin
  lcdCmdRaw 0x30
  delayCycles 250_000
  lcdCmdRaw 0x30
  delayCycles 5_000
  lcdCmdRaw 0x30
  delayCycles 5_000

  -- HD44780 normal init: function-set → display-on → entry-mode →
  -- clear. Each command goes through the busy-polled path.
  lcdCmd 0x38 -- function set: 8-bit, 2-line, 5x8 font
  lcdCmd 0x0C -- display on, cursor off, blink off
  lcdCmd 0x06 -- entry mode: increment, no display shift
  lcdCmd 0x01 -- clear display
  -- Clear needs 1.52 ms inside the chip, but our controller's busy
  -- only covers 40 µs. Insert the missing time here so the next
  -- character write doesn't land on a still-clearing chip. 200 000
  -- cycles ≈ 4 ms gives plenty of margin (the first hardware run
  -- with 80 000 dropped the leading 'H').
  delayCycles 200_000

  -- LEDR bit 1 = LCD init completed.
  ledrSet 0x03

  -- Top line, left-aligned at DDRAM 0x00 (the cursor home after
  -- Clear).
  lcdString "Hello from"

  -- Move the cursor to line 2, position 9 (DDRAM 0x49) so the
  -- 7-char "Riski5!" right-aligns inside a 16-wide row.
  lcdSetAddr 0x49

  lcdString "Riski5!"

  -- LEDR bit 2 = LCD string written.
  ledrSet 0x07

  -- JTAG UART banner.
  uartString "hello, world\n"

  -- After the one-shot LCD + UART writes, run a free-running 24-bit
  -- counter on the LEDs as a \"core is alive\" indicator:
  --   * counter[7:0]   → LEDG[7:0]
  --   * counter[23:8]  → LEDR[15:0]
  -- Each loop iteration is 4 instructions (≈ 4 cycles on the
  -- single-cycle core), so counter[0] toggles at ~6 MHz — too fast
  -- for the eye, so the lower LEDs look half-bright. The upper bits
  -- visibly count: LEDG[7] flickers a few times a second, LEDR[15]
  -- changes once every several seconds.
  addi countReg x0 0

  spin <- label
  addi countReg countReg 1
  -- Lower 8 bits → LEDG (offset 4 inside the GPIO MMIO window;
  -- the GPIO module truncates the write data to its 9-bit width).
  sw gpioReg countReg 4
  -- Upper 16 bits → LEDR (offset 0; truncated to 18 bits).
  srli ledTmpReg countReg 8
  sw gpioReg ledTmpReg 0
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

uartReg, lcdReg, gpioReg, tmpReg, delayReg, countReg, ledTmpReg :: Reg
uartReg = x20
lcdReg = x21
gpioReg = x23
tmpReg = x22
delayReg = x24
countReg = x25
ledTmpReg = x26

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

{- | Same as 'lcdCmd' but skips the busy poll — used for the wake
sequence at boot, when the chip's busy flag is not yet meaningful
and our controller's own busy state is gated by a software delay.
-}
lcdCmdRaw :: Int -> Asm ()
lcdCmdRaw cmdByte = do
  addi tmpReg x0 (P.fromIntegral cmdByte :: Signed 12)
  sw lcdReg tmpReg 4

-- | HD44780 \"Set DDRAM Address\" command (opcode @0x80 | addr@).
lcdSetAddr :: Int -> Asm ()
lcdSetAddr addr = lcdCmd (0x80 .|. addr)

-- | Write one character (RS=1, DATA register at offset 0).
lcdChar :: Int -> Asm ()
lcdChar ch = do
  lcdWait
  addi tmpReg x0 (P.fromIntegral ch :: Signed 12)
  sw lcdReg tmpReg 0

-- | Emit LCD writes for an entire string.
lcdString :: P.String -> Asm ()
lcdString = P.mapM_ (lcdChar . P.fromEnum)

-- * Delay helper --------------------------------------------------

{- | Spin-loop delay measured in core clock cycles, approximately.
The loop body is 2 instructions (addi + bne); each takes one cycle
on this single-cycle core, so we divide @n@ by 2 to get the
iteration count. Padding for the @li@ setup is small enough to
ignore at the millisecond scale.
-}
delayCycles :: Int -> Asm ()
delayCycles n = do
  li delayReg (P.fromIntegral (n `P.div` 2) :: Int32)
  loop <- label
  addi delayReg delayReg (-1 :: Signed 12)
  bne delayReg x0 loop

-- * GPIO helpers ---------------------------------------------------

-- | Set the LEDR register to a small immediate (≤ 11-bit) value.
ledrSet :: Int -> Asm ()
ledrSet bits = do
  addi tmpReg x0 (P.fromIntegral bits :: Signed 12)
  sw gpioReg tmpReg 0

-- * UART helpers ---------------------------------------------------

-- | Write a character to the JTAG UART DATA register.
uartChar :: Int -> Asm ()
uartChar ch = do
  addi tmpReg x0 (P.fromIntegral ch :: Signed 12)
  sw uartReg tmpReg 0

-- | Emit UART writes for an entire string.
uartString :: P.String -> Asm ()
uartString = P.mapM_ (uartChar . P.fromEnum)
