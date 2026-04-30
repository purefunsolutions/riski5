-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : LinuxBootMaster
Description : Poll-only boot stub for the JTAG-to-Avalon-Master path.

Companion to L-3b option A. This boot stub is the BRAM-resident
program for the @riski5-core-linux-master@ variant. The payload
(kernel + DTB) reaches SDRAM via the Avalon-MM-master JTAG bridge
(@Riski5.JtagAvalonMaster@ + sticky arbiter @Riski5.Soc.JtagMuxOwner@,
commits @dcb225d@ … @a6df51b@). The host writes a trigger record
at the top of SDRAM as the last step of the upload, and this stub
polls for it.

== Workflow

@
  nix run .#boot-linux-master                    -- single-shot
@

== Wire-protocol — host → SDRAM trampoline

The L-3a JTAG-load mux only routes JTAG-Avalon-Master writes to
SDRAM (see 'jtagMuxedSdram' in 'Riski5.Soc'). SRAM is reachable
only from the core's data port, so the trigger record cannot live
at SRAM addresses — it lives at the very top of SDRAM:

@
  SDRAM[0x807F_FFF0] : kernel byte count (u32 LE)
  SDRAM[0x807F_FFF4] : magic "go" sentinel (any non-zero u32)
@

Boot stub polls @SDRAM[0x807F_FFF4]@; once non-zero it computes
@a1 = 0x8000_0000 + kbytes@ (DTB pointer just past kernel),
sets @a0 = 0@, @sp = 0x2008_0000@ (SRAM top, well clear of
kernel pages), clears @mtvec@, and JALRs to @0x8000_0000@.

== Why poll-only (no scrub, no sentinel)

Earlier versions of this file ran a core-side SDRAM scrub +
0xCAFEBABE sentinel writes alongside the poll loop. The scrub
hammered the same SDRAM rows the host's first kernel chunk would
touch a few hundred milliseconds later; with both core SW and
JTAG-Master writes hitting overlapping rows, the SDRAM
controller's row-buffer state got muddled and a small fraction
of cells (e.g. @0x8000_0040@, @0x8000_0400@ — both row 0)
silently retained pre-upload data even after both stages
"committed" at the bus level. The bus-level sticky arbiter
('Riski5.Soc.JtagMuxOwner') prevents core/JTAG mid-transaction
mux flips but cannot reach into the IP's row buffer to
serialize writes there.

This rewrite eliminates ALL core-side SW to SDRAM during the
upload window. The boot stub does only LWs (the poll loop and
the post-trigger kbytes read), which never touch the IP's row-
buffer write pipeline. The host's master_write_32 stream lands
in a contention-free SDRAM, and the kernel image that ends up
at @0x8000_0000+@ is bit-identical to the bytes the host sent.

== Trap re-entry

@mtvec@ is cleared just before JALR; if the kernel takes a trap
before installing its own handler, control returns to PC=0 and
this same stub runs again. mscratch is not used as a first-entry
gate — the stub is idempotent (no destructive ops on SDRAM), so
re-running just polls again. If the trigger is still set the
stub will JR straight to the kernel a second time. If the kernel
has overwritten the trigger record the stub spins in the poll
loop until external help arrives — preferable to silently
re-doing destructive work.

The Asm-eDSL @LinuxBoot.hs@ stays in-tree as the JTAG-UART
fallback path.
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
  -- nommu boot ABI.
  let goAddr = x5     -- pointer into SDRAM at 0x807F_FFF0
      goSlot = x6     -- 1-word value at goAddr+4 — the "go" sentinel
      kbytes = x7     -- 1-word value at goAddr+0 — kernel byte count
      uartR  = x9     -- 0x1000_0000 (JTAG-UART data reg)
      a0Reg  = x10
      a1Reg  = x11
      spReg  = x2
      tmpReg = x12

  -- sp = SRAM top (kernel will be in SDRAM, far from this stack).
  li spReg 0x2008_0000

  -- uartR = 0x1000_0000 (JTAG-UART data MMIO).
  li uartR 0x1000_0000

  -- 'M' marker on entry — confirms the boot ROM ran (and, on a
  -- kernel-trap re-entry, that mtvec=0 routed back here).
  addi tmpReg x0 0x4D
  sw uartR tmpReg 0

  -- == INVALIDATE STALE TRIGGER ==
  -- FPGA reset clears the SDRAM IP but the chip keeps refreshing
  -- across reflashes, so the trigger record at 0x807F_FFF4 may
  -- still hold "1" from a previous boot. Without this clear, the
  -- poll loop below sees the stale 1 immediately and JRs to
  -- whatever stale kernel bytes the previous session left at
  -- 0x80000000 — diagnosed by observing kbytes dump = previous
  -- run's value when uploading a new image.
  --
  -- Uses a core-side SW which the sticky JTAG-mux arbiter
  -- (Riski5.Soc.JtagMuxOwner) keeps separate from any host
  -- JTAG-Master upload that happens to start near the same time.
  -- Followed by a row sweep to force the IP to commit the SW
  -- to the chip (otherwise the buffered SW could get clobbered
  -- by the host's later trigger write).
  li goAddr 0x807F_FFF0
  sw goAddr x0 4                  -- SDRAM[0x807F_FFF4] = 0
  -- Quick row sweep to flush the SW commit to chip.
  li tmpReg 0x80000000
  lw tmpReg tmpReg 0
  li tmpReg 0x80100000
  lw tmpReg tmpReg 0

  -- == POLL FOR HOST TRIGGER ==
  --
  -- Spin reading @SDRAM[0x807F_FFF4]@ until it becomes non-zero.
  -- The host's `boot-linux-master.tcl` writes 1 there as the last
  -- step of the upload, so seeing non-zero means kernel + DTB +
  -- kbytes are all in place.
  --
  -- The poll is a pure LW — no SDRAM SW from the core anywhere in
  -- this stub. This is the load-bearing change vs. the old
  -- scrub+sentinel boot stub: avoiding core-side writes during
  -- the upload window prevents the SDRAM controller's row buffer
  -- from getting confused when both core SW and JTAG-Master writes
  -- target overlapping rows. The sticky arbiter
  -- ('Riski5.Soc.JtagMuxOwner') already serializes the bus mux at
  -- transaction granularity; combining that with poll-only on the
  -- core side means the SDRAM IP only ever sees one kind of writer
  -- (JTAG-Master) for the duration of the upload.
  li goAddr 0x807F_FFF0
  pollL <- label
  lw goSlot goAddr 4
  beq goSlot x0 pollL

  -- 'J' marker — trigger seen, registers about to be set up.
  addi tmpReg x0 0x4A
  sw uartR tmpReg 0

  -- == DIAGNOSTIC: read kbytes from SDRAM[0x807F_FFF0] ==
  -- This is in row 4095 (the same row as the trigger). If the
  -- core can read this back as the host-written kbytes value,
  -- it confirms host master_write to high SDRAM rows commits to
  -- the chip and core lw can see it. Then we know any low-row
  -- read failures are row-specific.
  -- Format: 'K' marker, then 4 raw bytes (LE) of kbytes value.
  addi tmpReg x0 0x4B             -- 'K'
  sw uartR tmpReg 0
  lw kbytes goAddr 0              -- kbytes := SDRAM[0x807F_FFF0]
  sw uartR kbytes 0               -- emit byte 0
  srli tmpReg kbytes 8
  sw uartR tmpReg 0               -- byte 1
  srli tmpReg kbytes 16
  sw uartR tmpReg 0               -- byte 2
  srli tmpReg kbytes 24
  sw uartR tmpReg 0               -- byte 3

  -- == ROW SWEEP ==
  -- Force the SDRAM controller to ACTIVATE many different rows
  -- before the diagnostic dump. Hypothesis: the IP buffers writes
  -- in a row-data register and only commits to chip cells on
  -- PRECHARGE (row switch). If the host's writes land in the
  -- buffer but never get flushed, reads of the SAME row hit the
  -- buffer (correct data), reads of OTHER rows force ACTIVATE
  -- which brings stale chip cells into a fresh buffer.
  --
  -- By sweeping reads across many rows post-trigger (and BEFORE
  -- the diagnostic dump), each row gets its buffer flushed via
  -- PRECHARGE-on-next-ACTIVATE. The dump then sees committed
  -- chip data, which should match what the host uploaded.
  --
  -- 'S' marker after sweep so we can time it on the UART.
  let sweepAddr = goAddr            -- reuse — overwrite below
      sweepDummy = goSlot
  -- Read from row 0, row 1, row 2 (each ~512 bytes apart at 16-bit data)
  -- Ensure we hit different physical rows: SDRAM is 4 banks × 4096 rows
  -- × 256 cols × 16 bits = 8 MB. Row stride = 512 bytes.
  li sweepAddr 0x80000000
  lw sweepDummy sweepAddr 0
  lw sweepDummy sweepAddr 0x200    -- row stride 512 = 0x200
  lw sweepDummy sweepAddr 0x400
  lw sweepDummy sweepAddr 0x600
  li sweepAddr 0x80100000
  lw sweepDummy sweepAddr 0
  li sweepAddr 0x80200000
  lw sweepDummy sweepAddr 0
  li sweepAddr 0x80400000
  lw sweepDummy sweepAddr 0
  li sweepAddr 0x807F0000
  lw sweepDummy sweepAddr 0
  addi tmpReg x0 0x53             -- 'S' (sweep done)
  sw uartR tmpReg 0

  -- Restore goAddr for the dump.
  li goAddr 0x807F_FFF0

  -- == DIAGNOSTIC: kernel-early-path cells ==
  -- Dump 4 kernel cells the early init path touches: JAL header,
  -- csrw mtvec, the AMO at +0x100 (hart_lottery), and the .data
  -- start at +0x200. If any of these isn't its expected on-disk
  -- value, the JTAG-Master upload corrupted that cell and the
  -- kernel will hang silently when it executes that instruction.
  --
  -- Format: 'D' marker, then for each address: '@' + hex digit (0/1/2/3)
  -- + 4 raw bytes (LE) + '|' separator.
  addi tmpReg x0 0x44             -- 'D'
  sw uartR tmpReg 0

  -- We've already used kbytes/goAddr/etc.; reuse them as scratch.
  let dumpAddr = goAddr           -- holds 0x807F_FFF0 currently
      dumpVal = kbytes
      dumpIdx = goSlot

  li dumpAddr 0x80000000

  -- @0 SDRAM[0x80000000] (kernel JAL).
  addi dumpIdx x0 0x40            -- '@'
  sw uartR dumpIdx 0
  addi dumpIdx x0 0x30            -- '0'
  sw uartR dumpIdx 0
  lw dumpVal dumpAddr 0
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  addi dumpIdx x0 0x7C            -- '|'
  sw uartR dumpIdx 0

  -- @1 SDRAM[0x800000A4] (csrrw mtvec=0).
  addi dumpIdx x0 0x40
  sw uartR dumpIdx 0
  addi dumpIdx x0 0x31
  sw uartR dumpIdx 0
  lw dumpVal dumpAddr 0xA4
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  addi dumpIdx x0 0x7C
  sw uartR dumpIdx 0

  -- @2 SDRAM[0x80000100] (amoadd.w hart_lottery).
  addi dumpIdx x0 0x40
  sw uartR dumpIdx 0
  addi dumpIdx x0 0x32
  sw uartR dumpIdx 0
  lw dumpVal dumpAddr 0x100
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  addi dumpIdx x0 0x7C
  sw uartR dumpIdx 0

  -- @3 SDRAM[0x80000200] (early data section).
  addi dumpIdx x0 0x40
  sw uartR dumpIdx 0
  addi dumpIdx x0 0x33
  sw uartR dumpIdx 0
  lw dumpVal dumpAddr 0x200
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  srli dumpVal dumpVal 8
  sw uartR dumpVal 0
  addi dumpIdx x0 0x7C
  sw uartR dumpIdx 0

  -- == BSS SCRUB ==
  --
  -- Zero everything from (0x8000_0000 + kbytes) up to but not
  -- including the trigger record at 0x807F_FFF0. Why: the kernel
  -- runs an @amoadd.w hart_lottery@ at offset +0x100 (well before
  -- its own BSS-clear loop at +0x11c), and branches to
  -- @.Lsecondary_start@ if the pre-add value is non-zero — i.e.
  -- if @hart_lottery@ holds residual SDRAM data from a prior
  -- session, the boot core mistakes itself for a secondary core
  -- and waits forever, no matter how perfectly the kernel image
  -- uploaded.
  --
  -- The host's master_write_32 only writes the kernel image
  -- (offsets 0..@kbytes@) plus the DTB and the trigger record;
  -- everything between kernel_end and the trigger is whatever
  -- the SDRAM chip held last. Doing the scrub HERE (after the
  -- upload completes, before JR) keeps it within the contention-
  -- free window: host has finished, JTAG-Master is idle, the
  -- core has the bus to itself.
  --
  -- Re-load @goAddr@ first because the dump above clobbered it
  -- to 0x8000_0000, then re-fetch @kbytes@ from the trigger
  -- record (the dump used @kbytes@ as a scratch register too).
  li goAddr 0x807F_FFF0
  lw kbytes goAddr 0

  let scrubAddr = a0Reg            -- reuse — set to its real value below
      scrubEnd  = a1Reg            -- reuse — set to its real value below
  li tmpReg 0x80000000
  add scrubAddr tmpReg kbytes      -- scrubAddr = 0x8000_0000 + kbytes
  li scrubEnd 0x80400000           -- stop short of the DTB at 0x8040_0000
  scrubL <- label
  sw scrubAddr x0 0
  addi scrubAddr scrubAddr 4
  blt scrubAddr scrubEnd scrubL

  -- 'Z' marker — BSS scrub completed. If the test hangs after
  -- @3 but never sees Z, the SDRAM SW loop above is the culprit
  -- (silicon-only — pure-Haskell sim boots fine). If it sees Z
  -- but no kernel printk, the kernel itself is hanging early.
  addi tmpReg x0 0x5A             -- 'Z'
  sw uartR tmpReg 0

  -- == AMO RD-VALUE PROBE (task #144) ==
  -- Diagnostic: replicate the kernel's amoadd.w pattern at a
  -- known-clean SDRAM address and emit both the rd value and
  -- the post-AMO memory value over UART. Pure-Haskell sim
  -- already shows rd=OLD (=0) for this sequence; if silicon
  -- shows rd=NEW (=1) we've reproduced the kernel's bnez bug
  -- in isolation, away from any kernel-fetch contention.
  --
  -- Test address 0x803F_FFE8: in the BSS-scrubbed range above
  -- (kbytes is < 0x40_0000 in practice), well clear of trigger
  -- record at 0x807F_FFF0 and the DTB at 0x8040_0000. Already
  -- zeroed by the scrub loop, so MEM[testAddr] == 0 entering
  -- the AMO.
  --
  -- We mirror the kernel's exact instruction shape:
  --   amoadd.w rd, rs1, rs2  -- rd ← MEM[rs1]; MEM[rs1] ← rd + rs2
  -- with rs1=&testAddr, rs2=1, rd=t3.
  --
  -- Output sequence (reading UART byte-stream):
  --   'O' 0xZZ 0xZZ 0xZZ 0xZZ      -- rd value LE
  --   'P' 0xZZ 0xZZ 0xZZ 0xZZ      -- MEM[testAddr] post-AMO LE
  -- Expected (correct):  O 00 00 00 00 P 01 00 00 00
  -- Bug fingerprint:     O 01 00 00 00 P 01 00 00 00
  let testAddr = a0Reg            -- reuse — restore later
      amoIncr  = a1Reg            -- reuse — restore later
      rdReg    = x28              -- t3, matches kernel's a3 alias size
  li testAddr 0x803F_FFE8
  -- Belt-and-braces: explicitly zero the cell (scrub already did
  -- this but a fresh SW + row-flush guarantees the read starts
  -- from 0 regardless of any stale buffer state).
  sw testAddr x0 0
  -- Row sweep to flush the SW commit, mirroring the trigger-clear
  -- pattern earlier in this stub.
  li tmpReg 0x80000000
  lw tmpReg tmpReg 0
  li tmpReg 0x80100000
  lw tmpReg tmpReg 0
  -- The AMO itself.
  addi amoIncr x0 1
  amoadd_w rdReg testAddr amoIncr 0
  -- Emit 'O' + rd value (4 LE bytes).
  addi tmpReg x0 0x4F             -- 'O'
  sw uartR tmpReg 0
  sw uartR rdReg 0                -- byte 0
  srli tmpReg rdReg 8
  sw uartR tmpReg 0               -- byte 1
  srli tmpReg rdReg 16
  sw uartR tmpReg 0               -- byte 2
  srli tmpReg rdReg 24
  sw uartR tmpReg 0               -- byte 3
  -- Emit 'P' + MEM[testAddr] (4 LE bytes).
  addi tmpReg x0 0x50             -- 'P'
  sw uartR tmpReg 0
  lw rdReg testAddr 0
  sw uartR rdReg 0
  srli tmpReg rdReg 8
  sw uartR tmpReg 0
  srli tmpReg rdReg 16
  sw uartR tmpReg 0
  srli tmpReg rdReg 24
  sw uartR tmpReg 0

  -- == HART_LOTTERY PRE-LOAD (task #144 disambiguation) ==
  -- Pre-write *hart_lottery = 0xFFFF_FFFF (= -1) before the kernel
  -- runs its amoadd.w at PC=0x80000108. Two outcomes possible:
  --
  --   AMO returns OLD value (correct):
  --     a3 ← 0xFFFF_FFFF, *hart_lottery ← 0   (-1 + 1 = 0).
  --     bnez(a3 != 0) TAKEN → .Lsecondary_start → park (current
  --     symptom — silicon behaves correctly).
  --
  --   AMO returns NEW value (bug):
  --     a3 ← 0, *hart_lottery ← 0.
  --     bnez(0) NOT TAKEN → kernel falls through to .Lgood_cores
  --     and continues to start_kernel → kernel banner appears!
  --
  -- This disambiguates "AMO bug fetched-from-SDRAM" from "kernel
  -- hangs for some other reason". If the kernel boots after this
  -- pre-load, we've definitively pinned the bug to the AMO FU
  -- and we can post-mortem it via JTAG-Master read of *hart_lottery
  -- after the run (should be 0 in either case).
  --
  -- Address: hart_lottery = 0x802FD380 (per riski5-linux-rv32-nommu
  -- ELF symbol table; verified in the @2 dump above where
  -- SDRAM[0x80000100] = 0x00C6A6AF = the AMO with operands
  -- pointing at this offset).
  li tmpReg 0x802F_D380
  addi rdReg x0 (-1)
  sw tmpReg rdReg 0
  -- Row sweep to flush the SW commit so the kernel's AMO sees
  -- the new value, not buffered residue.
  li rdReg 0x80000000
  lw rdReg rdReg 0
  li rdReg 0x80100000
  lw rdReg rdReg 0
  -- 'L' marker confirms the pre-load executed.
  addi tmpReg x0 0x4C             -- 'L'
  sw uartR tmpReg 0

  -- == LINUX nommu BOOT ABI ==
  --   a0 = 0           (single-core hartid)
  --   a1 = 0x8040_0000 (DTB pointer — well past the kernel's
  --                     __bss_stop at ~0x8036_F258. Placing the
  --                     DTB immediately after the kernel image
  --                     overlaps the BSS-clear range, and the
  --                     kernel zeroes the trailing part of the
  --                     DTB before @setup_arch@ parses it. The
  --                     host's `boot-linux-master.tcl` writes
  --                     the DTB to the same fixed address —
  --                     keep them in sync.)
  --   sp = 0x2008_0000 (SRAM top — kernel pivots to its own
  --                     stack early in boot, but a valid sp on
  --                     entry is good hygiene).
  --   mtvec = 0        (kernel installs its own trap handler).
  li a1Reg 0x80400000
  addi a0Reg x0 0
  csrrw x0 x0 csrMtvec

  -- JALR to 0x8000_0000 — kernel entry.
  li tmpReg 0x80000000
  jalr x0 tmpReg 0

-- * Wiring ---------------------------------------------------------

linuxBootMasterFirmwareWords :: [BitVector 32]
linuxBootMasterFirmwareWords =
  case assemble linuxBootMasterFirmware of
    Left err -> P.error ("LinuxBootMaster: " P.++ P.show err)
    Right ws -> ws
