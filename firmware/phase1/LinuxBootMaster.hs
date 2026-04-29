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

  -- sp = SRAM top (kernel will be in SDRAM, far from this stack).
  li spReg 0x2008_0000

  -- uartR = 0x1000_0000 (JTAG-UART data MMIO).
  li uartR 0x1000_0000

  -- Diagnostic: emit 'M' on entry so we know the boot ROM ran.
  addi tmpReg x0 0x4D            -- 'M'
  sw uartR tmpReg 0

  -- goAddr = 0x807F_FFF0 (last 16 bytes of SDRAM).
  li goAddr 0x807F_FFF0

  -- Spin until SDRAM[goAddr+4] is non-zero — host's "ready" signal.
  pollL <- label
  lw goSlot goAddr 4
  beq goSlot x0 pollL

  -- 'B' = trigger seen, about to JR.
  addi tmpReg x0 0x42            -- 'B'
  sw uartR tmpReg 0

  -- Host has placed kbytes at SDRAM[goAddr+0]. Read it.
  lw kbytes goAddr 0

  -- a1 = 0x8000_0000 + kbytes  (DTB pointer just past the kernel).
  li sdramBaseR 0x8000_0000
  add a1Reg sdramBaseR kbytes

  -- a0 = 0 (hartid).
  addi a0Reg x0 0

  -- mtvec = 0 — match the working JTAG-UART path
  -- (firmware/phase1/LinuxBoot.hs). Pre-trap the kernel installs
  -- its own trap vector in head.S; until then any trap restarts
  -- this boot stub from word 0, which is harmless idempotent and
  -- a clear sign on the JTAG-UART that something diverged
  -- (visible as a repeating @M B M B …@ pattern).
  csrrw x0 x0 csrMtvec

  -- JR to 0x8000_0000. tmpReg as scratch since a0/a1 carry
  -- the boot-ABI args.
  li tmpReg 0x8000_0000
  jalr x0 tmpReg 0

-- * Wiring ---------------------------------------------------------

linuxBootMasterFirmwareWords :: [BitVector 32]
linuxBootMasterFirmwareWords =
  case assemble linuxBootMasterFirmware of
    Left err -> P.error ("LinuxBootMaster: " P.++ P.show err)
    Right ws -> ws
