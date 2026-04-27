-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : HelloAExt
Description : Debug firmware — exercise the RV32A AMO FU on real silicon.

Probes whether the new 'Riski5.Core.FU.Amo' multi-cycle FSM works
end-to-end on the DE2: against the actual SRAM controller (not the
single-word sim stub), through the actual JtagUartAdapter
backpressure, with the actual stall composition the SoC gives the
core today.

== Per-iteration UART script

Each iteration emits a fixed 5-byte stream so the host can match
silicon output against the architectural contract:

@
  B  — boot byte. BRAM exec + bus + UART are alive. Always first.
  L  — LR.W ran. We just latched the seed value at SRAM[0x100].
  S  — SC.W with matching reservation succeeded. mem[0x100] is
       now the post-SC value; rd was 0.
  A  — AMOSWAP.W ran. We swapped a fresh value in; rd holds the
       previous (post-SC) word, which we throw away. mem[0x100]
       is now the AMOSWAP-set value.
  X  — AMOADD.W ran. We added a known operand to mem[0x100] and
       checked the returned old value matches what AMOSWAP just
       wrote. If we reach this byte, the FU's full Read / compute
       / Write cycle is observable.
@

Expected silicon output: @BLSAX BLSAX BLSAX …@ (with a space
between iterations only conceptually — bytes stream contiguously
in practice). Any deviation pinpoints which AMO sub-path failed.

== Why SRAM (not BRAM)

The phase-2 SoC's BRAM bus port is __read-only__ (CM-3 silently
drops writes). SRAM is the cheapest writable target on the data
side. Silicon SRAM access is multi-cycle, so this firmware also
exercises the AmoFU's slave-ready gating that landed alongside
this firmware module — without that gate the FSM would advance on
every clock regardless of slave state, capturing stale data and
issuing untimely writes.

== Layout

The firmware fits well inside the 4096-word imem the SoC reserves
for @firmware/phase1/CoreMark.hs@. The Nix build's
@aExtTest = true@ flag overlays this module's output as
@CoreMark.coreMarkFirmwareWords@ — same scheme @sramExec@ and
@sdramExec@ use, keeping Top.hs bit-identical across variants and
preserving the CoreMark Quartus placement.
-}
module HelloAExt (
  helloAExtFirmware,
  helloAExtFirmwareWords,
) where

import Clash.Prelude (BitVector, Signed)
import Data.Either qualified as DE
import Riski5.Asm
import Riski5.ISA
import Prelude qualified as P

-- * Firmware -------------------------------------------------------

helloAExtFirmware :: Asm ()
helloAExtFirmware = do
  -- Set up the constant register file.
  --
  -- x10 = UART DATA = 0x1000_0000
  -- x12 = SRAM scratch addr = 0x2000_0100 (well inside SRAM, away
  --       from the lower bytes some other firmware variants poke)
  -- x14 = 'B' / 'L' / 'S' / 'A' / 'X' character bytes — re-loaded
  --       per byte (Asm can't easily address a printf-style table)
  li uartReg 0x1000_0000
  li sramAddr 0x2000_0100

  -- Top of the loop. Falls through after each AMOADD.
  loopL <- label

  -- ---------------- B ----------------
  -- Print 'B'. Confirms BRAM exec + bus + UART are working.
  addi x14 x0 (0x42 :: Signed 12)
  sw uartReg x14 0

  -- Seed mem[0x100] := 0x11111111 with a plain SW so the LR.W has
  -- a known value to latch. Uses x15 as the seed value.
  li seedR 0x1111_1111
  sw sramAddr seedR 0

  -- ---------------- L ----------------
  -- LR.W: latch mem[0x100] into x16; reservation := Just 0x100.
  -- The LR.W instruction is encoded by 'Riski5.Asm.lr_w' as
  -- (opcode 0b010_1111, funct3 0b010, funct5 0b00010, rs2 = 0).
  -- aqrl = 0 (relaxed).
  lr_w lrR sramAddr 0
  -- Print 'L' — proves the LR.W decoded and retired (didn't trap).
  addi x14 x0 (0x4C :: Signed 12)
  sw uartReg x14 0

  -- ---------------- S ----------------
  -- SC.W: with the reservation live and matching, write
  -- 0x2222_2222 to mem[0x100]; rd = 0 on success.
  li scValR 0x2222_2222
  sc_w scRdR sramAddr scValR 0
  -- Print 'S' regardless — the test stream stays a fixed length so
  -- the host can pattern-match without conditional branches in
  -- firmware.
  addi x14 x0 (0x53 :: Signed 12)
  sw uartReg x14 0

  -- ---------------- A ----------------
  -- AMOSWAP.W: swap 0x33333333 into mem[0x100]; rd captures the
  -- post-SC value (0x2222_2222). Issues a Read phase + Write phase
  -- against SRAM so the slave-ready gating is exercised.
  li swapValR 0x3333_3333
  amoswap_w swapRdR sramAddr swapValR 0
  addi x14 x0 (0x41 :: Signed 12) -- 'A'
  sw uartReg x14 0

  -- ---------------- X ----------------
  -- AMOADD.W: mem[0x100] += 0x100; rd captures the pre-add value
  -- (0x33333333 from AMOSWAP). Demonstrates a binary-op AMO,
  -- not just a swap.
  addi addOpR x0 0x100
  amoadd_w addRdR sramAddr addOpR 0
  addi x14 x0 (0x58 :: Signed 12) -- 'X'
  sw uartReg x14 0

  -- Loop back for another iteration. The host sees a periodic
  -- @BLSAX BLSAX …@ byte stream as long as the FU keeps working.
  j loopL
 where
  uartReg = x10
  sramAddr = x12
  seedR = x13
  lrR = x16
  scValR = x17
  scRdR = x18
  swapValR = x19
  swapRdR = x20
  addOpR = x21
  addRdR = x22

helloAExtFirmwareWords :: [BitVector 32]
helloAExtFirmwareWords =
  DE.fromRight
    (P.error "helloAExtFirmware failed to assemble")
    (assemble helloAExtFirmware)
