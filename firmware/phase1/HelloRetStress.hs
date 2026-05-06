-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : HelloRetStress
Description : Minimal isolation of the wake-from-sleep bug (#64).

The full 'HelloSchedStress' firmware produced @BABABABA…@ on Verilator
hwsim (instead of the expected @BAb.Ab.Ab.…@), proving the synthesised
core's @switch_to@-style sequence-of-loads-then-@jalr@ lands at the
wrong PC. This module further narrows the failing pattern.

== Tests, in order of size

1. **simple**: write target_addr to SRAM, read it back into x1, @jalr x0, x1, 0@.
   Expected stream: @BG@ (boot + reach 'G' label after jalr).
   Failure stream: anything else.

2. **chain**: write 14 different values to SRAM (one per offset 0..52),
   read them all back into x1, x2, x8, x9, x18..x27 (mirrors switch_to's
   register set), then @jalr x0, x1, 0@. Same expected stream.

If (1) passes but (2) fails, the bug is specific to the
sequence-of-loads-then-@jalr@-using-the-first-loaded pattern. If both
fail, the bug is in the basic @lw → jalr@ pair.

This firmware's BRAM-only and SRAM-only — no SDRAM, no JTAG-master,
no kernel — so a hang here is unambiguously the core's load /
forwarding / control-flow path.
-}
module HelloRetStress (
  helloRetStressFirmware,
  helloRetStressFirmwareWords,
) where

import Clash.Prelude (BitVector)
import Data.Either qualified as DE
import Riski5.Asm
import Riski5.ISA
import Prelude qualified as P

-- * Firmware -------------------------------------------------------

helloRetStressFirmware :: Asm ()
helloRetStressFirmware = do
  let uartReg = x10

  li uartReg 0x1000_0000

  -- 'B' boot byte.
  li x14 0x42
  sw uartReg x14 0

  -- ----------------------------------------------------------------
  -- Test 0 (super simple): jalr through a register, no memory at all.
  -- jal x14 + jalr x0 x14 0 should jump to the JAL's PC+4.
  -- ----------------------------------------------------------------
  test0OverL <- labelUnplaced
  jal x14 test0OverL
  -- ↓ test 0 target (first instruction). x14 already points HERE.
  li x15 0x30          -- '0' for "test 0 reached via jalr-through-reg"
  sw uartReg x15 0
  test0ToTest1L <- labelUnplaced
  j test0ToTest1L

  placeAt test0OverL
  jalr x0 x14 0        -- jump to x14 directly (no memory roundtrip)

  -- If we get here, test 0 failed.
  li x14 0x46           -- 'F'
  sw uartReg x14 0
  failSpin0L <- label
  li x14 0x46
  sw uartReg x14 0
  j failSpin0L

  -- ----------------------------------------------------------------
  -- Test 1 (with memory): write target_addr to SRAM, lw it back, jalr.
  -- ----------------------------------------------------------------
  placeAt test0ToTest1L
  li x11 0x2000_0000  -- SRAM scratch addr

  -- Capture target1 address into x1 via the jal x14 trick.
  test1OverL <- labelUnplaced
  jal x14 test1OverL
  -- ↓ this is target1 (first instruction)
  li x15 0x47          -- 'G' for "got here via jalr-through-memory"
  sw uartReg x15 0
  -- After printing G, immediately go to test 2 setup.
  test1ToTest2L <- labelUnplaced
  j test1ToTest2L

  placeAt test1OverL
  -- x14 = target1 address
  sw x11 x14 0          -- M[0x2000_0000] = target1 addr
  lw x1 x11 0           -- x1 = M[0x2000_0000]
  jalr x0 x1 0          -- jump to x1

  -- If we get here, test 1 failed.
  li x14 0x46           -- 'F' fail
  sw uartReg x14 0
  failSpinL <- label
  li x14 0x46
  sw uartReg x14 0
  j failSpinL

  -- ----------------------------------------------------------------
  -- Test 2 (chain): 14 sw, 14 lw, jalr — mirrors switch_to.
  -- ----------------------------------------------------------------
  placeAt test1ToTest2L
  -- 'b' marker for "passed test 1, entering test 2"
  li x14 0x62           -- 'b'
  sw uartReg x14 0

  -- Capture target2 address into x14 via jal trick.
  test2OverL <- labelUnplaced
  jal x14 test2OverL
  -- ↓ this is target2 (first instruction)
  li x15 0x68          -- 'h' for "made it through the long lw chain + jalr"
  sw uartReg x15 0
  doneSpinL <- label
  j doneSpinL

  placeAt test2OverL
  -- x14 = target2 address. Save it AND 13 other distinct values
  -- into the 14 ctx slots, then load them back, then jalr.
  --
  -- Layout:
  --   M[0x2000_0000 + 0]  = target2 addr   (will be loaded into x1)
  --   M[0x2000_0000 + 4]  = 0xDEAD0001     (loaded into x2)
  --   M[0x2000_0000 + 8]  = 0xDEAD0002     (loaded into x8)
  --   M[0x2000_0000 + 12] = 0xDEAD0003     (loaded into x9)
  --   M[0x2000_0000 + 16] = 0xDEAD0004     (loaded into x18)
  --   ...
  --   M[0x2000_0000 + 52] = 0xDEAD000D     (loaded into x27)
  sw x11 x14 0          -- ctx[0] = target2

  li x15 0xDEAD0001
  sw x11 x15 4
  li x15 0xDEAD0002
  sw x11 x15 8
  li x15 0xDEAD0003
  sw x11 x15 12
  li x15 0xDEAD0004
  sw x11 x15 16
  li x15 0xDEAD0005
  sw x11 x15 20
  li x15 0xDEAD0006
  sw x11 x15 24
  li x15 0xDEAD0007
  sw x11 x15 28
  li x15 0xDEAD0008
  sw x11 x15 32
  li x15 0xDEAD0009
  sw x11 x15 36
  li x15 0xDEAD000A
  sw x11 x15 40
  li x15 0xDEAD000B
  sw x11 x15 44
  li x15 0xDEAD000C
  sw x11 x15 48
  li x15 0xDEAD000D
  sw x11 x15 52

  -- Now load all 14 back into the same regs switch_to uses
  lw x1 x11 0           -- target2 addr
  lw x2 x11 4
  lw x8 x11 8
  lw x9 x11 12
  lw x18 x11 16
  lw x19 x11 20
  lw x20 x11 24
  lw x21 x11 28
  lw x22 x11 32
  lw x23 x11 36
  lw x24 x11 40
  lw x25 x11 44
  lw x26 x11 48
  lw x27 x11 52

  jalr x0 x1 0          -- ret to target2

  -- If we get here, test 2 failed.
  li x14 0x66           -- 'f' fail (lowercase, distinct from test 1's F)
  sw uartReg x14 0
  fail2SpinL <- label
  li x14 0x66
  sw uartReg x14 0
  j fail2SpinL

helloRetStressFirmwareWords :: [BitVector 32]
helloRetStressFirmwareWords =
  case assemble helloRetStressFirmware of
    DE.Right ws -> ws
    DE.Left e -> P.error ("HelloRetStress assembly failed: " P.++ P.show e)
