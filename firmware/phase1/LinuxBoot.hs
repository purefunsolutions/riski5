-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : LinuxBoot
Description : L-9 boot stub — JTAG-UART → SDRAM → Linux entry.

Combined SDRAM-loader + RISC-V Linux boot-protocol jumper. Reads
a kernel image plus device-tree blob from the JTAG-UART RX FIFO,
writes them contiguously into SDRAM, then JALRs into the kernel
with the standard nommu boot ABI (a0 = hartid, a1 = &dtb).

== Wire-protocol

@
  bytes 0..3    : little-endian kernel word count K
  bytes 4..7    : little-endian DTB    word count D
  bytes 8..     : K × 32-bit LE kernel words
  bytes (8+4K)..: D × 32-bit LE DTB    words
@

Total byte count = 8 + 4 × (K + D).

After load:

@
  sp = 0x2008_0000           (top of on-board 512 KB SRAM —
                              boot stub's stack lives here, not
                              in SDRAM, so kernel-zeroed pages
                              don't trample our return address)
  a0 = 0                     (hartid)
  a1 = 0x8000_0000 + 4 × K   (start of DTB, just past the kernel)
  mtvec = 0                  (let the kernel install its own
                              trap vector; Linux nommu does this
                              very early in head.S)
  pc = 0x8000_0000           (kernel entry)
@

== UART status stream

@
  L  — loader ready
  D  — load complete, about to JALR
@

After 'D', kernel printk output streams via the same JTAG-UART
tap (`earlycon=jtag-uart,mmio,0x10000000` in our DTS bootargs).

== Layout

Boot code starts at PC 0. The bake target is the
@riski5-core-linux@ Nix variant which uses the same overlay
mechanism as @sdramExec@ / @aExtTest@ / @sdramLoad@: this
module's @linuxBootFirmwareWords@ replaces
@CoreMark.coreMarkFirmwareWords@ at build time.
-}
module LinuxBoot (
  linuxBootFirmware,
  linuxBootFirmwareWords,
) where

import Clash.Prelude (BitVector)
import Data.Either (Either (..))
import Riski5.Asm
import Riski5.ISA
import Prelude qualified as P

-- * Firmware -------------------------------------------------------

linuxBootFirmware :: Asm ()
linuxBootFirmware = do
  -- ABI:
  --   x10  = uartReg     — JTAG-UART DATA register address
  --   x11  = sdramReg    — current SDRAM destination, increments
  --                         by 4 each word write. Starts at
  --                         0x8000_0000.
  --   x12  = lenReg      — remaining word count (decrements per
  --                         word). Holds K (kernel) then D (DTB).
  --   x13  = shiftReg    — byte-shift counter (0, 8, 16, 24)
  --                         for assembling 4 bytes into one word.
  --   x14  = wordReg     — accumulator for the word currently
  --                         being assembled (or the printed byte
  --                         in the 'L' / 'D' status writes).
  --   x15  = tmpReg      — UART read-data, masked-validity, etc.
  --   x16  = byteReg     — extracted byte (lower 8 bits of UART
  --                         read).
  --   x17  = validMask   — 0x8000 (RVALID bit position).
  --   x18  = limitReg    — 32 (loop terminator for shift count).
  --   x19  = byteShifted — byte << shiftReg.
  --   x20  = scratch / extracted UART RVALID gate.
  --   x21  = kernelLen   — saved kernel word count for a1
  --                         computation after both reads.
  --
  -- After load, a0 / a1 / sp / pc are set up per the RISC-V Linux
  -- boot-ABI:
  --   a0 (x10) = 0                    — hartid
  --   a1 (x11) = 0x8000_0000 + 4 × K  — DTB pointer
  --   sp (x2)  = 0x2008_0000          — top of on-board SRAM
  --   pc       = 0x8000_0000          — kernel entry
  li uartReg 0x1000_0000
  li sdramReg 0x8000_0000

  -- 'L' — loader ready.
  addi wordReg x0 0x4C
  sw uartReg wordReg 0

  -- Pre-allocate forward-reference labels.
  jumpToKernelL <- labelUnplaced

  -- ----- Read 4-byte kernel-length prefix into kernelLen ----
  addi kernelLen x0 0
  addi shiftReg x0 0
  addi limitReg x0 32
  li validMask 0x8000

  readKLenL <- label
  pollKLenL <- label
  lw tmpReg uartReg 0
  and_ wordReg tmpReg validMask
  beq wordReg x0 pollKLenL
  andi byteReg tmpReg 0xFF
  sll byteShifted byteReg shiftReg
  or_ kernelLen kernelLen byteShifted
  addi shiftReg shiftReg 8
  blt shiftReg limitReg readKLenL

  -- ----- Read 4-byte DTB-length prefix into lenReg --------
  -- (We'll overload lenReg with the running counter; we keep
  -- kernelLen in x21 so a1 can be computed at the end.)
  addi lenReg x0 0
  addi shiftReg x0 0

  readDLenL <- label
  pollDLenL <- label
  lw tmpReg uartReg 0
  and_ wordReg tmpReg validMask
  beq wordReg x0 pollDLenL
  andi byteReg tmpReg 0xFF
  sll byteShifted byteReg shiftReg
  or_ lenReg lenReg byteShifted
  addi shiftReg shiftReg 8
  blt shiftReg limitReg readDLenL

  -- ----- Add kernelLen + dtbLen → total word count -------
  -- (We'll just decrement total over the unified payload loop.)
  add lenReg lenReg kernelLen

  -- ----- Read N=K+D words, write contiguously to SDRAM ---
  loopWordL <- label
  beq lenReg x0 jumpToKernelL

  addi shiftReg x0 0
  addi wordReg x0 0

  readWordL <- label

  pollWordL <- label
  lw tmpReg uartReg 0
  and_ x20 tmpReg validMask
  beq x20 x0 pollWordL

  andi byteReg tmpReg 0xFF
  sll byteShifted byteReg shiftReg
  or_ wordReg wordReg byteShifted

  addi shiftReg shiftReg 8
  blt shiftReg limitReg readWordL

  sw sdramReg wordReg 0
  addi sdramReg sdramReg 4
  addi lenReg lenReg (-1)
  j loopWordL

  -- ----- Done. Set up Linux boot ABI and jump. ----------
  placeAt jumpToKernelL

  -- 'D' — load complete.
  addi wordReg x0 0x44
  sw uartReg wordReg 0

  -- a1 = 0x8000_0000 + (kernelLen << 2) — start of DTB.
  -- (kernelLen is in word units; bytes = words × 4 = words << 2.)
  li tmpReg 0x8000_0000
  slli kernelLen kernelLen 2
  add a1Reg tmpReg kernelLen

  -- a0 = 0 (hartid).
  addi a0Reg x0 0

  -- sp = 0x2008_0000 (top of SRAM).
  li spReg 0x2008_0000

  -- mtvec = 0 — let the kernel install its own.
  csrrw x0 x0 csrMtvec

  -- JALR to 0x8000_0000. Use x5 as scratch base register so we
  -- don't clobber a0 / a1.
  li x5 0x8000_0000
  jalr x0 x5 0
 where
  -- Boot-protocol register aliases (RISC-V Linux ABI).
  a0Reg = x10  -- hartid
  a1Reg = x11  -- DTB pointer
  spReg = x2   -- stack pointer

  -- Loader register aliases (same as SdramLoader; kept distinct
  -- here so the boot-ABI section above can override x10 / x11
  -- meaningfully). uartReg / sdramReg overlap a0 / a1 — harmless
  -- since the loader runs before the ABI-setup section.
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
  kernelLen = x21

-- * Wiring ---------------------------------------------------------

linuxBootFirmwareWords :: [BitVector 32]
linuxBootFirmwareWords =
  case assemble linuxBootFirmware of
    Left err -> P.error ("LinuxBoot: " P.++ P.show err)
    Right ws -> ws
