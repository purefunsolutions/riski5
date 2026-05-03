-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : LinuxBootSim
Description : Minimal sim-only Linux boot stub.

Companion to 'LinuxBootMaster' (the silicon boot stub that polls
the JTAG-Avalon-Master trigger record before JALR-ing). This
sim-only variant skips all the trigger-polling, diagnostic dumps,
and kbytes-from-SRAM machinery — the riski5-sim Verilator harness
pre-loads the kernel + DTB into the simulated SDRAM via
@MEM_INIT_*@ pins before reset releases, so we just need the BRAM
boot to set up the standard RISC-V Linux nommu boot ABI and JALR
to @0x80000000@.

Boot ABI we set up before JALR:
  a0  = 0           (single-core hartid)
  a1  = 0x80400000  (DTB pointer — same fixed address the silicon
                     loader uses, well past the kernel's __bss_stop
                     ~0x8036_F258)
  sp  = 0x20080000  (top of SRAM)
  mtvec = 0         (kernel installs its own handler)

UART markers (so harness output is greppable like silicon):
  'M' on boot entry — confirms the BRAM boot ran
  'J' just before JALR — confirms control reached the jump

That's it. ~10 instructions total. Used by @pkgs/riski5-sim@'s
CoreMark.hs overlay so the Verilator-driven sim BRAM contains
this stub instead of MemTest.
-}
module LinuxBootSim (
  linuxBootSimFirmware,
  linuxBootSimFirmwareWords,
) where

import Clash.Prelude (BitVector)
import Data.Either (Either (..))
import Riski5.Asm
import Riski5.ISA
import Prelude qualified as P

linuxBootSimFirmware :: Asm ()
linuxBootSimFirmware = do
  let uartR = x10
      tmpReg = x12
      sdRdReg = x13
      sdAddrReg = x14
      a0Reg = x10 -- aliases — set late, after UART marker
      a1Reg = x11
      spReg = x2

  -- 'M' marker on boot entry.
  li uartR 0x10000000
  addi tmpReg x0 0x4D
  sw uartR tmpReg 0

  -- sp = SRAM top.
  li spReg 0x20080000

  -- Diagnostic: wait for SDRAM controller init to complete (its
  -- @sdrInitNopCycles = 4100@ + 8 refreshes + LMR ≈ 4150 cycles)
  -- by spinning on a counter. Without this delay the JALR's
  -- first SDRAM fetch races against the controller's still-in-
  -- INIT-phase state.
  li tmpReg 8000
  delayL <- label
  addi tmpReg tmpReg (-1)
  bne tmpReg x0 delayL

  -- Diagnostic: read SDRAM[0x80000000] and emit 'K' + 4 LE bytes.
  -- If the harness pre-loaded the kernel correctly, this should
  -- be the kernel's first instruction word (typically a JAL into
  -- head.S). If it's all zero, the SDRAM model isn't returning
  -- the pre-loaded data (or the load address mapping is wrong).
  addi tmpReg x0 0x4B -- 'K'
  sw uartR tmpReg 0
  li sdAddrReg 0x80000000
  lw sdRdReg sdAddrReg 0
  sw uartR sdRdReg 0
  srli tmpReg sdRdReg 8
  sw uartR tmpReg 0
  srli tmpReg sdRdReg 16
  sw uartR tmpReg 0
  srli tmpReg sdRdReg 24
  sw uartR tmpReg 0

  -- 'J' marker just before JALR (helpful when debugging hangs
  -- between the entry marker and the kernel's first printk).
  addi tmpReg x0 0x4A
  sw uartR tmpReg 0

  -- mtvec = 0 (kernel installs its own).
  csrrw x0 x0 csrMtvec

  -- a0 = 0, a1 = 0x80400000 (DTB).
  li a1Reg 0x80400000
  addi a0Reg x0 0

  -- JALR to 0x80000000.
  li tmpReg 0x80000000
  jalr x0 tmpReg 0

linuxBootSimFirmwareWords :: [BitVector 32]
linuxBootSimFirmwareWords =
  case assemble linuxBootSimFirmware of
    Left err -> P.error ("LinuxBootSim: " P.++ P.show err)
    Right ws -> ws
