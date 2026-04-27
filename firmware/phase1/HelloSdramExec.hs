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

-- * SDRAM-resident WSPACE-poll preamble ----------------------------
-- The Altera JTAG-UART IP commits one byte per master assertion
-- regardless of FIFO state — bytes that arrive when the FIFO is
-- full are silently dropped (the @woverflow@ flag is set but the
-- byte is gone). On silicon, nios2-terminal drains at ~100 KB/s
-- while this firmware commits at ~2.2 MB/s, so ~96 % of writes
-- overflow. The visible byte stream becomes a lottery between
-- @B@-drops and @S@-drops, with a slight @S@-bias because
-- @S@ writes happen ~150 cycles after @B@ in each iteration —
-- enough time for one byte to drain, leaving @S@ slightly more
-- likely to find FIFO space than @B@.
--
-- The fix is the same one CoreMark applies: poll the @WSPACE@
-- bits in the JTAG-UART CONTROL register before each write, and
-- only commit when @WSPACE > 0@. The 3-instruction polling
-- preamble is hand-encoded for the SDRAM-resident routine
-- (which sits at byte addresses we choose explicitly):
--
-- @
--   lw   x11, 4(x10)      ; CTRL = MEM[uartBase + 4]
--   srli x11, x11, 16     ; WSPACE = CTRL >> 16
--   beq  x11, x0, -8      ; if WSPACE == 0, retry from lw
-- @
--
-- Encoding breakdown:
--
--   lw x11, 4(x10):       I-type, opcode 0000011, funct3 010,
--                          rs1=01010, rd=01011, imm=4
--                          ⇒ 0x00452583
--   srli x11, x11, 16:    I-type immediate, opcode 0010011,
--                          funct3 101, rs1=01011, rd=01011,
--                          shamt=10000
--                          ⇒ 0x01055593
--   beq x11, x0, -8:      B-type, opcode 1100011, funct3 000,
--                          rs1=01011, rs2=00000, imm=-8
--                          ⇒ 0xFE058CE3

encodedLwX11_4_X10 :: Int32
encodedLwX11_4_X10 = 0x0045_2583

encodedSrliX11_X11_16 :: Int32
encodedSrliX11_X11_16 = 0x0105_5593

encodedBeqX11_X0_minus8 :: Int32
encodedBeqX11_X0_minus8 = 0xFE05_8CE3 :: Int32

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
  -- bus + UART all work. The @WSPACE@-poll preamble below
  -- ensures the byte actually lands in the JTAG-UART FIFO
  -- rather than being silently dropped via overflow when the
  -- FIFO is full (which is the steady-state condition because
  -- the firmware loops faster than nios2-terminal drains).
  --
  -- Sequence:
  --
  --   pollB:
  --     lw   t1, 4(uartReg)   ; CTRL = uart[CONTROL]
  --     srli t1, t1, 16       ; WSPACE = CTRL >> 16
  --     beq  t1, x0, pollB    ; if WSPACE == 0, retry
  --     addi tmpReg, x0, 'B'
  --     sw   uartReg, tmpReg, 0
  pollB <- label
  lw spaceReg uartReg 4
  srli spaceReg spaceReg 16
  beq spaceReg x0 pollB
  addi tmpReg x0 (0x42 :: Signed 12) -- 'B'
  sw uartReg tmpReg 0

  -- Pin 'S' into x14 so the SDRAM-resident @sw x14, 0(x10)@ at
  -- SDRAM[0] has the right rs2 value when it retires.
  addi sdramChar x0 (0x53 :: Signed 12) -- 'S'

  -- SDRAM base.
  li sdramAddrR 0x8000_0000

  -- The SDRAM-resident routine is now 5 architectural instructions
  -- (the WSPACE poll for @S@, the @sw@, and the @jalr@-to-0
  -- redirect) plus the defensive prefetch fill out to
  -- @SDRAM[60]@. Layout:
  --
  --   SDRAM[ 0] = lw   x11, 4(x10)       ; pollS: read CTRL
  --   SDRAM[ 4] = srli x11, x11, 16      ; WSPACE = CTRL >> 16
  --   SDRAM[ 8] = beq  x11, x0, -8       ; if WSPACE == 0, retry
  --   SDRAM[12] = sw   x10, x14, 0       ; commit @S@
  --   SDRAM[16] = jalr x0, x0, 0         ; redirect to BRAM[0]
  --   SDRAM[20..60] = jalr x0, x0, 0     ; defensive prefetch fill
  --
  -- The WSPACE-poll preamble ensures the @S@ byte actually
  -- lands in the FIFO (matching the @B@ side's polling), so the
  -- visible byte stream becomes a clean @BSBSBS…@ regardless of
  -- nios2-terminal's drain rate.
  li encReg encodedLwX11_4_X10
  sw sdramAddrR encReg 0
  li encReg encodedSrliX11_X11_16
  sw sdramAddrR encReg 4
  li encReg encodedBeqX11_X0_minus8
  sw sdramAddrR encReg 8
  li encReg encodedSw_x14_0_x10
  sw sdramAddrR encReg 12
  li encReg encodedJalrToZero
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
  tmpReg = x11 -- a1: scratch (also used as @t1@ for WSPACE poll)
  spaceReg = x11 -- a1: aliased to tmpReg — WSPACE polling target.
  -- (Both names use the same register — the BRAM-side @B@ polling
  -- writes to @x11@, then the @addi@ reloads @x11@ with @0x42@
  -- before the @sw@ commits, so there's no aliasing conflict.)
  sdramChar = x14 -- a4: carries 'S' to the SDRAM routine
  sdramAddrR = x12 -- a2
  encReg = x13 -- a3

helloSdramExecFirmwareWords :: [BitVector 32]
helloSdramExecFirmwareWords =
  DE.fromRight
    (P.error "helloSdramExecFirmware failed to assemble")
    (assemble helloSdramExecFirmware)
