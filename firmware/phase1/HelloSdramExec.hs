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

Flow per iteration:

  1. BRAM bootstrap. @sw x11, 0(x10)@ writes @B@ to the UART
     (one byte per iteration confirms BRAM exec + bus + UART
     are alive).

  2. Pre-assembled instructions are written into SDRAM via the
     bus. The architecturally meaningful pair is:

       SDRAM[0x8000_0000] = @sw x14, 0(x10)@   ; 0x00E5_2023
       SDRAM[0x8000_0004] = @jalr x0, x0, 0@   ; 0x0000_0067

     The @sw@ at SDRAM[0] prints @S@; the @jalr@ at SDRAM[4]
     redirects PC to BRAM[0] for the next iteration. Because
     the IF stage prefetches past the architectural terminator
     before its X-stage redirect actually fires, the rest of
     the @SDRAM[8..60]@ window is __defensively filled__ with
     the same @jalr x0, x0, 0@ encoding — so any prefetch
     leakage past the architectural @jalr@ also lands on a
     clean redirect rather than executing whatever
     power-on-noise happens to live in those SDRAM cells. (See
     the @docs/perf/sdram-exec@ writeup if it exists; the
     diagnostic that uncovered this — replacing SDRAM[4] with
     a second SW writing @?@ to the UART — confirmed pipeline
     retirement of __both__ SDRAM[0] AND SDRAM[4] before any
     redirect from SDRAM[8] could flush them.)

  3. @jalr x0, x12, 0@ in BRAM where @x12 = 0x8000_0000@ jumps
     to the SDRAM-resident routine.

Observable outcomes on the UART:

  * __@BSBSBS…@__ (one @B@ + one @S@ per iteration, looping)
      — SDRAM execution __works__. This is the architectural
        contract; the simulator (sdramIpSim) reproduces it
        cleanly, and silicon hits this for the first ~30
        iterations before any FIFO-backpressure pattern kicks
        in.

  * __@BBBB...@__ (infinite @B@ stream)
      — SDRAM execution __does not work__. The @jalr@ set PC
        to @0x8000_0000@, but the SoC's @addrToImemIdx@ hashes
        that @\`mod\` 4096@ and returns a word of BRAM —
        firmware restarts via the BRAM image. This was the
        pre-SX-1..SX-6 baseline.

  * __@BSS…BSS…@__ — silicon-only artefact under sustained
        FIFO backpressure: the SDRAM[0] @sw@ commits 1.5–2.7
        bytes per iteration on average instead of 1.0. The
        BRAM B-side and the SDRAM[4] redirect side both stay
        clean (≈ 1 byte each), so the multi-byte is localised
        to the SDRAM-resident @sw@. Likely a pipeline +
        IF-stage-prefetch interaction with the JTAG-UART IP's
        @av_waitrequest@ toggle protocol. Tracked under the
        SDRAM-execution follow-ups in TODO.md; SignalTap II
        (now reachable through the alterade2-flake debug
        wrapper) is the right next investigation step.

  * Anything else
      — interesting surprise; note the exact byte stream and
        trace from there.

The pattern mirrors 'HelloSramExec' so the Nix overlay machinery
(the @riski5-core-sdramexec@ variant in @pkgs/riski5-core@) can
drop this firmware in via the same @firmware/phase1/CoreMark.hs@
re-export trick that @riski5-core-sramexec@ uses. The
@altsource_probe@-based diagnostic harness in @riski5_top.v@
is wired in every variant — so if silicon misbehaves,
@quartus_stp -t@ + the PCFE / DBGF probe indices give a
no-SignalTap path to peek at @pcFetchS@ and the packed
stall / ready / accepted flags at any moment.
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

-- | Encoded @jalr x0, x0, 0@ → PC := x0 + 0 = 0. A direct redirect
-- back to BRAM[0] without going through the trap path. Used to fill
-- the post-@sw@ window in SDRAM so any IF-stage prefetch past the
-- intended terminator hits a clean branch back to the firmware
-- entry point — no @ebreak@ trap, no mepc / mcause sequence, just
-- one cycle of pipeline-flushing branch resolution.
--
-- Encoding:
--
--   jalr x0, x0, 0   = I-type
--     opcode = 1100111, funct3 = 000,
--     rd = 0, rs1 = 0, imm = 0
--     ⇒ 0b000000000000_00000_000_00000_1100111 = 0x0000_0067
encodedJalrToZero :: Int32
encodedJalrToZero = 0x0000_0067

-- * Firmware -------------------------------------------------------

helloSdramExecFirmware :: Asm ()
helloSdramExecFirmware = do
  -- UART DATA register = 0x1000_0000.
  li uartReg 0x1000_0000

  -- Print 'B' — first byte on the wire confirms BRAM exec +
  -- bus + UART all work.
  addi tmpReg x0 (0x42 :: Signed 12) -- 'B'
  sw uartReg tmpReg 0

  -- Pin 'S' into x14 so the SDRAM-resident @sw x14, 0(x10)@ at
  -- SDRAM[0] has the right rs2 value when it retires.
  addi sdramChar x0 (0x53 :: Signed 12) -- 'S'

  -- SDRAM base.
  li sdramAddrR 0x8000_0000

  -- Write SDRAM[0] = `sw x14, 0(x10)` (architectural — prints @S@).
  li encReg encodedSw_x14_0_x10
  sw sdramAddrR encReg 0

  -- Write SDRAM[4..60] = `jalr x0, x0, 0`. SDRAM[4] is the
  -- architectural redirect terminator (@jalr@ to PC = 0); the
  -- rest of the window is a defensive fill for IF-stage prefetch
  -- leakage.
  --
  -- Earlier revisions used @ebreak@ here; @ebreak@ traps to
  -- @mtvec.base@ via the M-mode trap path. A diagnostic sweep
  -- that put a second @sw x15, 0(x10)@ writing @?@ at SDRAM[4]
  -- showed the IF stage retires both SDRAM[0] AND SDRAM[4]
  -- before any redirect from SDRAM[8]'s JALR can flush — i.e.
  -- multi-byte clusters in the silicon byte stream are real
  -- pipeline-execution, not IP-side noise. Switching SDRAM[4]
  -- to a plain @jalr x0, x0, 0@ skips the trap path entirely
  -- and just redirects PC to 0 (the BRAM firmware entry) on a
  -- single cycle of branch resolution in X.
  --
  -- The fill extends to SDRAM[60] because pipeline depth + the
  -- multi-cycle SDRAM fetch combine to let the IF stage prefetch
  -- ~3-5 instructions past the architectural terminator before
  -- the X-stage redirect actually settles.
  li encReg encodedJalrToZero
  sw sdramAddrR encReg 4
  sw sdramAddrR encReg 8
  sw sdramAddrR encReg 12
  sw sdramAddrR encReg 16
  sw sdramAddrR encReg 20
  sw sdramAddrR encReg 24
  sw sdramAddrR encReg 28
  sw sdramAddrR encReg 32
  sw sdramAddrR encReg 36
  sw sdramAddrR encReg 40
  sw sdramAddrR encReg 44
  sw sdramAddrR encReg 48
  sw sdramAddrR encReg 52
  sw sdramAddrR encReg 56
  sw sdramAddrR encReg 60

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
