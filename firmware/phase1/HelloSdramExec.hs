-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : HelloSdramExec
Description : Debug firmware — execute code from SDRAM.

The SDRAM-execution counterpart to 'HelloSramExec'. Answers the
question: does the core fetch correctly when the PC is in the
SDRAM address range (@0x8000_0000..0x807F_FFFF@)? Phase 1D closed
end-to-end SDRAM __data__ access (T39, @0xCAFEBABE@ round-trip
through the Altera @altera_avalon_new_sdram_controller@ IP);
phase 1's last architectural piece is making the same chip
fetchable so a Linux kernel image (which lives in SDRAM) can
actually execute.

Flow:

  1. UART-print @B@ — confirms BRAM execution + bus + UART.

  2. Write two pre-assembled instructions into SDRAM via the
     bus:

       SDRAM[0x8000_0000] = @sw x14, 0(x10)@   ; 0x00E5_2023
       SDRAM[0x8000_0004] = @ebreak@           ; 0x0010_0073

     @x10@ holds the UART DATA address, @x14@ holds the
     constant 'S'. The @sw@ prints 'S'; the @ebreak@ triggers
     a breakpoint trap so we don't fall off the end of what we
     wrote.

  3. @jalr x0, x12, 0@ where @x12 = 0x8000_0000@ — jump to
     SDRAM's first instruction.

Observable outcomes on the UART:

  * __@BSBSBS…@__ (one @B@ + one @S@ per iteration, looping)
      — SDRAM execution __works__. The core fetched
        SDRAM[0x8000_0000], ran the @sw@ (prints 'S'), then
        fetched SDRAM[0x8000_0004] (ebreak) and trapped to
        @mtvec.base@ which (in this firmware) sits on BRAM[0],
        restarting the firmware from the top.

  * __@BBBB...@__ (infinite @B@ stream)
      — SDRAM execution __does not work__. The @jalr@ set PC
        to @0x8000_0000@, but the SoC's @addrToImemIdx@ hashes
        that @\`mod\` 4096@ and returns a word of BRAM —
        firmware restarts via the BRAM image.

  * Anything else
      — interesting surprise; note the exact byte stream and
        trace from there.

The pattern mirrors 'HelloSramExec' so the Nix overlay machinery
(the @riski5-core-sdramexec@ variant in @pkgs/riski5-core@) can
drop this firmware in via the same @firmware/phase1/CoreMark.hs@
re-export trick that @riski5-core-sramexec@ uses, and the
@altsource_probe@-based diagnostic harness in @riski5_top.v@ is
already wired in every variant — so if SDRAM execution doesn't
work the first time, @quartus_stp -t@ + the PCFE / DBGF probe
indices give a no-SignalTap path to root-cause exactly which
stall signal latches in the wrong place.
-}
module HelloSdramExec (
  helloSdramExecFirmware,
  helloSdramExecFirmwareWords,
) where

import Clash.Prelude (BitVector, Signed)
import Data.Either qualified as DE
import Data.Int (Int32)
import Riski5.Asm
import Riski5.ISA
import Prelude qualified as P

-- | Pre-computed instruction encodings — the same two opcodes
-- 'HelloSramExec' writes into SRAM, just landing in SDRAM here.
-- Verify by hand (or with @riscv32-none-elf-as@) if touched.
--
-- Encoding breakdown:
--
--   sw x14, 0(x10)   = S-type
--     opcode = 0100011, funct3 = 010,
--     rs1 = 01010 (x10), rs2 = 01110 (x14), imm = 0
--     ⇒ 0b0000000_01110_01010_010_00000_0100011 = 0x00E5_2023
--
--   ebreak           = I-type immediate in funct12 slot
--     opcode = 1110011, funct3 = 000,
--     rd = 0, rs1 = 0, imm = 0x001
--     ⇒ 0b000000000001_00000_000_00000_1110011 = 0x0010_0073
encodedSw_x14_0_x10 :: Int32
encodedSw_x14_0_x10 = 0x00E5_2023

encodedEbreak :: Int32
encodedEbreak = 0x0010_0073

-- * Firmware -------------------------------------------------------

helloSdramExecFirmware :: Asm ()
helloSdramExecFirmware = do
  -- UART DATA register = 0x1000_0000.
  li uartReg 0x1000_0000

  -- Print 'B' — first byte on the wire confirms BRAM exec +
  -- bus + UART all work.
  addi tmpReg x0 (0x42 :: Signed 12) -- 'B'
  sw uartReg tmpReg 0

  -- Pin 'S' into x14 so the SDRAM routine can use it as rs2 of
  -- the SW it's about to execute.
  addi sdramChar x0 (0x53 :: Signed 12) -- 'S'

  -- SDRAM base.
  li sdramAddrR 0x8000_0000

  -- Write SDRAM[0] = `sw x14, 0(x10)`.
  li encReg encodedSw_x14_0_x10
  sw sdramAddrR encReg 0

  -- Write SDRAM[4] = `ebreak`.
  li encReg encodedEbreak
  sw sdramAddrR encReg 4

  -- Jump to SDRAM[0] — the moment of truth.
  jalr x0 sdramAddrR 0

  -- Fallback: only reached if the JALR somehow doesn't take
  -- (shouldn't happen). Spin.
  halt <- label
  j halt
 where
  uartReg = x10 -- a0
  tmpReg = x11 -- a1
  sdramChar = x14 -- a4: carries 'S' to the SDRAM routine
  sdramAddrR = x12 -- a2
  encReg = x13 -- a3

helloSdramExecFirmwareWords :: [BitVector 32]
helloSdramExecFirmwareWords =
  DE.fromRight
    (P.error "helloSdramExecFirmware failed to assemble")
    (assemble helloSdramExecFirmware)
