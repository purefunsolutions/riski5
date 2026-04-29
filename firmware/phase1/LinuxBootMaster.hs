-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : LinuxBootMaster
Description : Minimal boot stub for the JTAG-to-Avalon-Master path.

Companion to L-3b option A (commit 57a9d88). This boot stub is
designed to be the BRAM-resident program for a riski5-core-linux
variant whose payload is delivered straight into SDRAM via the
Avalon-MM-master JTAG bridge instead of the JTAG-UART RX FIFO.
The stub does ZERO upload work — the host has already populated
SDRAM by the time we run.

== Workflow

@
  nix run .#boot-linux-master                    -- single-shot
@

== Wire-protocol — host → SDRAM trampoline

The L-3a JTAG-load mux only routes JTAG-Avalon-Master writes to
SDRAM (see 'jtagMuxedSdram' in 'Riski5.Soc'). SRAM is reachable
only from the core's data port, so the trigger record cannot live
at the SRAM addresses 0x2000_0000 / 0x2000_0004 — it must live
inside SDRAM. The host therefore parks the trigger at the very
top of SDRAM (8 MB, last 16 bytes), where no plausible kernel
image will overlap during the upload phase:

@
  SDRAM[0x807F_FFF0] : kernel byte count (u32 LE)
  SDRAM[0x807F_FFF4] : magic "go" sentinel (any non-zero u32)
@

Boot stub polls @SDRAM[0x807F_FFF4]@; once non-zero, it computes
@a1 = 0x8000_0000 + kbytes@ (DTB pointer just past kernel),
sets @a0 = 0@, @sp = 0x2008_0000@ (SRAM top, well clear of
kernel pages), and JALRs to @0x8000_0000@. Because the trigger
sits in SDRAM the kernel may overwrite it after boot — that's
fine, the stub never re-reads it.

== SDRAM scrub on entry

Before polling the trigger, the boot stub zeros every word in
@0x80000000..0x807F_FFE0@ from the core data port. This works
around an asymmetric write quirk: empirically (probe-Y test), the
__JTAG-Avalon-Master path__ silently coalesces writes when their
target cells already hold non-zero data from a prior FPGA
session, while __core-side data-port writes__ commit reliably to
the same cells. The Altera SDRAM Controller IP keeps refreshing
the chip across FPGA reprograms, so without a power-cycle SDRAM
contents survive — and a fresh kernel upload via JTAG-Master
would land back-to-back drops at every previously-touched
address. Running a quick core-side scrub first puts every cell
into a state from which the JTAG-Master path can write cleanly.

The scrub runs @blt@-bounded, ~2 Mi words × ~30 cycles @ 30 MHz
≈ 2 s. Boot stub emits @C@ when done; the host's existing
post-flash @jtagd@ recycle + @system-console@ JVM startup
(combined ~6 s) covers that. The trigger record's last 32 B is
deliberately left unscrubbed so a deliberate host-supplied
trigger always lands on cells already in scrub-clean state.

== Why a separate variant

The L-9 / B-2..B-6 boot ROMs were designed to ALSO upload via
JTAG-UART. With the master path landing, those state machines
become wasted instructions on the BRAM-resident image. A slim
\"wait-for-go\" stub keeps the BRAM small (~12 instructions) and
removes any risk of the state machine reading stale JTAG-UART
bytes mid-upload.

The Asm-eDSL @LinuxBoot.hs@ stays in-tree as the
JTAG-UART-fallback path.
-}
module LinuxBootMaster (
  linuxBootMasterFirmware,
  linuxBootMasterFirmwareWords,
) where

import Clash.Prelude (BitVector)
import Data.Either (Either (..))
import Riski5.Asm
import Riski5.ISA
import Prelude qualified as P

-- * Firmware -------------------------------------------------------

linuxBootMasterFirmware :: Asm ()
linuxBootMasterFirmware = do
  -- Register aliases.
  -- After the JR, the kernel sees a0/a1/sp per the RISC-V Linux
  -- nommu boot ABI. Until then we're free to clobber x5..x18.
  let goAddr  = x5    -- pointer into SDRAM at 0x807F_FFF0
      goSlot  = x6    -- 1-word value at goAddr+4 — the "go" sentinel
      kbytes  = x7    -- 1-word value at goAddr+0 — kernel size in bytes
      sdramBaseR = x8 -- 0x8000_0000 in a register
      uartR = x9      -- 0x1000_0000 (JTAG-UART data reg)
      a0Reg = x10
      a1Reg = x11
      spReg = x2
      tmpReg = x12

  -- Forward-reference labels for the first-entry gate (see below).
  skipFirstL <- labelUnplaced
  pollEntryL <- labelUnplaced

  -- sp = SRAM top (kernel will be in SDRAM, far from this stack).
  li spReg 0x2008_0000

  -- uartR = 0x1000_0000 (JTAG-UART data MMIO).
  li uartR 0x1000_0000

  -- Diagnostic: emit 'M' on entry so we know the boot ROM ran.
  addi tmpReg x0 0x4D            -- 'M'
  sw uartR tmpReg 0

  -- == FIRST-ENTRY GATE (mscratch flag) ==
  --
  -- The kernel may trap during boot; @mtvec = 0@ routes the trap
  -- back here. Without a gate, every re-entry would re-scrub the
  -- kernel image we just uploaded. So: use @mscratch@ (preserved
  -- across traps) as a "first-entry done" flag.
  --   First entry  : mscratch=0 → invalidate stale trigger, scrub
  --                   SDRAM, set mscratch=1, emit 'C', poll, JR.
  --   Re-entry     : mscratch=1 → skip scrub, emit 'R', poll, JR.
  csrrs tmpReg x0 csrMscratch
  bne tmpReg x0 skipFirstL

  -- == FIRST-ENTRY PATH ==

  -- Invalidate any "go" sentinel left over from a prior session.
  -- Without this the stub would JR before the host's upload starts.
  li goAddr 0x807F_FFF0
  sw goAddr x0 4

  -- == SDRAM SCRUB ==
  --
  -- Empirically (probe-Y test, see commit log), core-side SW
  -- commits to stale SDRAM cells reliably, while JTAG-Avalon-
  -- Master writes do not. So before the host's master_write_32
  -- kernel upload starts, we run a core-side scrub: zero every
  -- word in 0x80000000..0x807FFFE0. (Stops 32 B short of the
  -- trigger record at 0x807FFFF0 — the host rewrites the trigger
  -- anyway, but leaving it untouched eliminates one timing edge.)
  --
  -- The host's existing post-flash jtagd-recycle + system-console
  -- JVM startup (~6 s) is plenty of time for the scrub to finish
  -- before the first master_write_32 hits.
  let scrubAddr = goAddr   -- reuse the trigger-pointer register
      scrubEnd  = kbytes
  li scrubAddr 0x8000_0000
  li scrubEnd  0x807F_FFE0
  scrubL <- label
  sw scrubAddr x0 0
  addi scrubAddr scrubAddr 4
  blt scrubAddr scrubEnd scrubL

  -- Mark first-entry complete (mscratch <- 1).
  addi tmpReg x0 1
  csrrw x0 tmpReg csrMscratch

  -- == DIAGNOSTIC: SELF-WRITE READBACK CONSISTENCY ==
  --
  -- Prove that core-side SW + LW agree at the same SDRAM address.
  -- Write 0xDEADBEEF to 0x80000004 from the core data port, then
  -- read it back and dump the bytes. If the dump shows EF BE AD DE,
  -- the core's data port is self-consistent — and any zero readings
  -- of host-uploaded data below mean those uploads truly didn't
  -- commit. Runs regardless of host trigger so it always emits.
  let dumpAddr       = sdramBaseR
      dumpVal        = kbytes
      dumpScratchTmp = a0Reg
  addi dumpScratchTmp x0 0x53   -- 'S'
  sw uartR dumpScratchTmp 0
  li dumpAddr 0xDEADBEEF
  li dumpVal  0x80000004
  sw dumpVal dumpAddr 0          -- *(0x80000004) = 0xDEADBEEF
  lw dumpAddr dumpVal 0          -- dumpAddr = *(0x80000004)
  sw uartR dumpAddr 0
  srli dumpAddr dumpAddr 8
  sw uartR dumpAddr 0
  srli dumpAddr dumpAddr 8
  sw uartR dumpAddr 0
  srli dumpAddr dumpAddr 8
  sw uartR dumpAddr 0
  addi dumpScratchTmp x0 0x7C
  sw uartR dumpScratchTmp 0

  -- == SENTINEL WRITES ==
  --
  -- Write a sentinel value (0xCAFEBABE) at every address the
  -- post-trigger dump samples. After this, host's master_write_32
  -- upload starts. If JTAG-Master commits to a sample address,
  -- the upload's kernel byte will overwrite our sentinel; the
  -- dump will show the kernel byte. If JTAG-Master fails to
  -- commit, our sentinel persists and the dump shows CAFEBABE —
  -- proving the upload genuinely didn't write that cell (vs.
  -- our previous "saw a kernel byte at 0x80000040" which could
  -- have been a leftover from a prior session's commit).
  li dumpAddr  0xCAFEBABE
  li dumpVal   0x80000000
  sw dumpVal dumpAddr 0          -- 0x80000000
  sw dumpVal dumpAddr 0x10       -- 0x80000010
  sw dumpVal dumpAddr 0x40       -- 0x80000040
  sw dumpVal dumpAddr 0xA4       -- 0x800000A4
  li dumpVal   0x80000400
  sw dumpVal dumpAddr 0          -- 0x80000400
  li dumpVal   0x80001000
  sw dumpVal dumpAddr 0          -- 0x80001000
  li dumpVal   0x80100000
  sw dumpVal dumpAddr 0          -- 0x80100000

  -- 'C' = scrub + self-test + sentinel-writes complete.
  addi tmpReg x0 0x43            -- 'C'
  sw uartR tmpReg 0

  -- Fall through to the poll path below.
  -- (No explicit jump — placeAt skipFirstL drops us into poll.)
  beq x0 x0 pollEntryL

  placeAt skipFirstL

  -- == RE-ENTRY PATH (after kernel trap) ==

  addi tmpReg x0 0x52            -- 'R'
  sw uartR tmpReg 0

  placeAt pollEntryL

  -- goAddr = 0x807F_FFF0 (last 16 bytes of SDRAM).
  li goAddr 0x807F_FFF0

  -- Spin until SDRAM[goAddr+4] is non-zero — host's "ready" signal.
  pollL <- label
  lw goSlot goAddr 4
  beq goSlot x0 pollL

  -- 'B' = trigger seen, about to dump.
  addi tmpReg x0 0x42            -- 'B'
  sw uartR tmpReg 0

  -- == WIDE-SWEEP DUMP ==
  --
  -- After host trigger, dump several addresses to characterize
  -- which JTAG-Master writes commit. Frames each 4-byte dump
  -- between '|' separators preceded by a single-digit ASCII index.
  --
  -- Indexed addresses (kernel image bytes from on-disk):
  --   0  0x80000000  expected 0x0a40006f  (kernel JAL — first word)
  --   1  0x80000004  was overwritten by self-test to 0xDEADBEEF
  --   2  0x80000010  expected 0x0036f258
  --   3  0x80000040  expected 0x43534952  ('RISC' magic)
  --   4  0x800000a4  expected 0x30401073  (CSRRW mtvec=0)
  --   5  0x80000400  expected non-zero    (first word of chunk 1)
  --   6  0x80001000  expected non-zero    (4 KB into kernel)
  --   7  0x80100000  expected non-zero    (1 MB into kernel)

  -- 0
  addi dumpScratchTmp x0 0x30
  sw uartR dumpScratchTmp 0
  li dumpAddr 0x80000000
  lw dumpVal dumpAddr 0
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  addi dumpScratchTmp x0 0x7C   -- '|'
  sw uartR dumpScratchTmp 0

  -- 1
  addi dumpScratchTmp x0 0x31
  sw uartR dumpScratchTmp 0
  lw dumpVal dumpAddr 4         -- SDRAM[0x80000004]
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  addi dumpScratchTmp x0 0x7C
  sw uartR dumpScratchTmp 0

  -- 2: SDRAM[0x80000010] = dumpAddr + 0x10
  addi dumpScratchTmp x0 0x32
  sw uartR dumpScratchTmp 0
  lw dumpVal dumpAddr 0x10
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  addi dumpScratchTmp x0 0x7C
  sw uartR dumpScratchTmp 0

  -- 3: SDRAM[0x80000040]
  addi dumpScratchTmp x0 0x33
  sw uartR dumpScratchTmp 0
  lw dumpVal dumpAddr 0x40
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  addi dumpScratchTmp x0 0x7C
  sw uartR dumpScratchTmp 0

  -- 4: SDRAM[0x800000A4] — sw imm range is ±2048 so this fits as offset
  addi dumpScratchTmp x0 0x34
  sw uartR dumpScratchTmp 0
  lw dumpVal dumpAddr 0xA4
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  addi dumpScratchTmp x0 0x7C
  sw uartR dumpScratchTmp 0

  -- 5: SDRAM[0x80000400] (first word of chunk 1; reload base)
  addi dumpScratchTmp x0 0x35
  sw uartR dumpScratchTmp 0
  li dumpAddr 0x80000400
  lw dumpVal dumpAddr 0
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  addi dumpScratchTmp x0 0x7C
  sw uartR dumpScratchTmp 0

  -- 6: SDRAM[0x80001000]
  addi dumpScratchTmp x0 0x36
  sw uartR dumpScratchTmp 0
  li dumpAddr 0x80001000
  lw dumpVal dumpAddr 0
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  addi dumpScratchTmp x0 0x7C
  sw uartR dumpScratchTmp 0

  -- 7: SDRAM[0x80100000]
  addi dumpScratchTmp x0 0x37
  sw uartR dumpScratchTmp 0
  li dumpAddr 0x80100000
  lw dumpVal dumpAddr 0
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  addi dumpScratchTmp x0 0x7C
  sw uartR dumpScratchTmp 0

  -- Halt with '.' loop.
  addi tmpReg x0 0x2E
  haltL <- label
  sw uartR tmpReg 0
  beq x0 x0 haltL

-- * Wiring ---------------------------------------------------------

linuxBootMasterFirmwareWords :: [BitVector 32]
linuxBootMasterFirmwareWords =
  case assemble linuxBootMasterFirmware of
    Left err -> P.error ("LinuxBootMaster: " P.++ P.show err)
    Right ws -> ws
