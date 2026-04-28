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
  nix run .#flash-riski5-linux-master            -- 1. flash bitstream
  nix run .#load-sdram-master -- kernel.bin 0x80000000
  nix run .#load-sdram-master -- dtb.bin     0x807FF000
  # then trigger:
  quartus_stp ... master_write_32 0x20000000 [kbytes_le, 1]
@

== Wire-protocol — host → SRAM trampoline

The host writes a small "go record" into SRAM at @0x2000_0000@:

@
  SRAM[0x2000_0000] : kernel byte count (u32 LE)
  SRAM[0x2000_0004] : magic "go" sentinel (any non-zero u32)
@

Boot stub polls @SRAM[0x2000_0004]@; once non-zero, it computes
@a1 = 0x8000_0000 + kbytes@ (DTB pointer just past kernel),
sets @a0 = 0@, @sp = 0x2008_0000@ (SRAM top, far from kernel
pages), and JALRs to @0x8000_0000@.

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
  let goAddr  = x5    -- pointer into SRAM at 0x2000_0000
      goSlot  = x6    -- 1-word value at SRAM[+4] — the "go" sentinel
      kbytes  = x7    -- 1-word value at SRAM[+0] — kernel size in bytes
      sdramBaseR = x8 -- 0x8000_0000 in a register
      a0Reg = x10
      a1Reg = x11
      spReg = x2
      tmpReg = x12

  -- sp = SRAM top (kernel will be in SDRAM, far from this stack).
  li spReg 0x2008_0000

  -- goAddr = 0x2000_0000.
  li goAddr 0x2000_0000

  -- Spin until SRAM[+4] is non-zero — the host's "ready" signal.
  pollL <- label
  lw goSlot goAddr 4
  beq goSlot x0 pollL

  -- Host has placed kbytes at SRAM[+0]. Read it.
  lw kbytes goAddr 0

  -- a1 = 0x8000_0000 + kbytes  (DTB pointer just past the kernel).
  li sdramBaseR 0x8000_0000
  add a1Reg sdramBaseR kbytes

  -- a0 = 0 (hartid).
  addi a0Reg x0 0

  -- mtvec = 0 — let the kernel install its own.
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
