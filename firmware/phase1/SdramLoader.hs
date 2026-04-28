-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : SdramLoader
Description : L-3b boot stub — JTAG-UART → SDRAM loader.

Tiny boot stub that reads a length-prefixed binary blob from
JTAG-UART and writes it to SDRAM at @0x8000_0000+@, then jumps
to @0x8000_0000@. The host pipes a kernel image into
@nios2-terminal@'s stdin; this firmware lands the bytes into
SDRAM and starts the kernel.

== Wire-protocol

@
  bytes 0..3  : little-endian word count N
  bytes 4..   : N × 32-bit little-endian words
@

Total byte count = 4 + 4 × N. The firmware reads exactly that
many bytes from the JTAG-UART RX FIFO, writes the words
contiguously starting at @0x8000_0000@, then JALRs to
@0x8000_0000@. Linux (or whatever's at SDRAM[0]) takes over.

== UART script

The firmware emits a one-byte status stream so the host can
verify each phase landed:

@
  L   — loader ready, about to read length prefix
  D   — done loading, about to JALR to SDRAM[0]
@

If the kernel boots cleanly, kernel output continues from there
(typically @"Linux version …\\n"@ via printk → @earlycon=jtag-uart@).

== JTAG-UART RX semantics

The Altera JTAG-UART IP's @DATA@ register read returns:

@
  bits[31:16] : RAVAIL   — bytes still in RX FIFO after this read
  bit [15]    : RVALID   — 1 if a byte was returned in [7:0]
  bits[14:8]  : reserved
  bits[ 7:0]  : byte data (valid only when RVALID = 1)
@

Firmware polls DATA in a tight loop, checks bit 15, extracts
the byte from bits [7:0] when valid, otherwise spins. No need
for IRQs — this is boot-time loading, throughput is bounded by
the JTAG-hub anyway (~100 KB/s).

== Throughput

JTAG-UART IP runs at the JTAG TCK rate; on USB-Blaster that's
roughly ~100 KB/s end-to-end after the host stack overhead.
8 MB Linux image = ~80 s. One-time cost per kernel rebuild;
once the image is in SDRAM, the user can press KEY0 to re-run
it without re-loading (the DE2's reset doesn't clear SDRAM
unless power is cycled).

== Layout

Boot code starts at PC 0. There's no separate trap handler
(the loader doesn't enable interrupts; any trap is a fatal
hang).

Bake into the @riski5-core-sdramload@ Nix variant via the same
@CoreMark.hs@ overlay mechanism @sramExec@ / @sdramExec@ /
@aExtTest@ / @timerIrqTest@ use.
-}
module SdramLoader (
  sdramLoaderFirmware,
  sdramLoaderFirmwareWords,
) where

import Clash.Prelude (BitVector)
import Data.Either (Either (..))
import Riski5.Asm
import Riski5.ISA
import Prelude qualified as P

-- * Firmware -------------------------------------------------------

sdramLoaderFirmware :: Asm ()
sdramLoaderFirmware = do
  -- Constant-register file (kept consistent across read loops):
  --
  --   x10 = uartReg     — JTAG-UART DATA register address
  --                       (= 0x1000_0000)
  --   x11 = sdramReg    — current SDRAM destination, increments
  --                       by 4 each word write. Starts at
  --                       0x8000_0000.
  --   x12 = lenReg      — remaining word count (decremented per
  --                       word). Loaded from the 4-byte length
  --                       prefix.
  --   x13 = shiftReg    — byte-shift counter (0, 8, 16, 24)
  --                       for assembling 4 bytes into one word.
  --   x14 = wordReg     — accumulator for the word currently
  --                       being assembled (or the printed byte
  --                       in the 'L' / 'D' status writes).
  --   x15 = tmpReg      — UART read-data, masked-validity, etc.
  --   x16 = byteReg     — extracted byte (lower 8 bits of UART
  --                       read).
  --   x17 = validMask   — 0x8000 (RVALID bit position).
  --   x18 = limitReg    — 32 (loop terminator for shift count).
  --   x19 = byteShifted — byte << shiftReg.
  --   x20 = jReg        — JALR target (= 0x8000_0000).
  li uartReg 0x1000_0000
  li sdramReg 0x8000_0000

  -- Pre-allocate forward-reference labels.
  doneL <- labelUnplaced

  -- 'L' — loader ready.
  addi wordReg x0 0x4C
  sw uartReg wordReg 0

  -- ----- Read 4-byte length prefix into lenReg ---------------
  addi lenReg x0 0
  addi shiftReg x0 0
  addi limitReg x0 32
  li validMask 0x8000

  readLenL <- label

  -- Inner: poll DATA until RVALID=1.
  pollLenL <- label
  lw tmpReg uartReg 0
  and_ wordReg tmpReg validMask
  beq wordReg x0 pollLenL

  -- byteReg = tmpReg & 0xFF
  andi byteReg tmpReg 0xFF
  -- byteShifted = byteReg << shiftReg
  sll byteShifted byteReg shiftReg
  -- lenReg |= byteShifted
  or_ lenReg lenReg byteShifted

  addi shiftReg shiftReg 8
  blt shiftReg limitReg readLenL

  -- ----- Read N words, write to SDRAM ----------------------
  loopWordL <- label
  beq lenReg x0 doneL

  -- Reset shift counter for this word's 4-byte assembly.
  addi shiftReg x0 0
  addi wordReg x0 0

  readWordL <- label

  pollWordL <- label
  lw tmpReg uartReg 0
  and_ x21 tmpReg validMask
  beq x21 x0 pollWordL

  andi byteReg tmpReg 0xFF
  sll byteShifted byteReg shiftReg
  or_ wordReg wordReg byteShifted

  addi shiftReg shiftReg 8
  blt shiftReg limitReg readWordL

  -- Word assembled; write to SDRAM.
  sw sdramReg wordReg 0
  addi sdramReg sdramReg 4
  addi lenReg lenReg (-1)
  j loopWordL

  -- ----- Done ----------------------------------------------
  placeAt doneL
  -- 'D' — load complete.
  addi wordReg x0 0x44
  sw uartReg wordReg 0

  -- JALR to 0x8000_0000.
  li jReg 0x8000_0000
  jalr x0 jReg 0
 where
  uartReg = x10
  sdramReg = x11
  lenReg = x12
  shiftReg = x13
  wordReg = x14
  tmpReg = x15
  byteReg = x16
  validMask = x17
  limitReg = x18
  byteShifted = x19
  jReg = x20

-- * Wiring ---------------------------------------------------------

sdramLoaderFirmwareWords :: [BitVector 32]
sdramLoaderFirmwareWords =
  case assemble sdramLoaderFirmware of
    Left err -> P.error ("SdramLoader: " P.++ P.show err)
    Right ws -> ws
