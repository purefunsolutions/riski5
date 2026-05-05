-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : HelloMdStress
Description : Silicon stress test for the M-extension MUL/DIV FU (task #58).

Probes whether 'Riski5.Core.FU.MulDiv.mulDivFUIterative' works
end-to-end on the DE2. Companion to 'HelloAExt' / 'HelloAmoStress'
/ 'HelloLrScStress' — closes the silicon-coverage gap CLAUDE.md
calls out (every RV32 instruction must pass on hwsim AND on real
silicon, but no silicon stress firmware existed for the
M-extension before today).

The Linux silicon hang at PC 0x801E2F10 (task #58) appeared right
after a `mul a1, a5, a2` in `put_dec_trunc8`, with the iterative
MUL/DIV FSM the prime suspect. The hybrid `mulDivFUMulComb` build
moves MUL onto a combinational/DSP path and lets Linux boot past
the BogoMIPS print, but DIV/REM still ride the iterative FSM. This
firmware tests both branches in isolation so the bug surfaces at
the byte level instead of through Linux's noise.

== Per-iteration UART script

Each iteration emits a fixed 7-byte stream so the host can match
silicon output against the architectural contract:

@
  M  — MUL    : `mul x3, x1, x2`        with x1=0x1234_5678, x2=0x100 → x3 should be 0x4567_8000
  U  — MULHU  : `mulhu x3, x1, x2`      with x1=0xFFFF_FFFF, x2=0xFFFF_FFFF → x3 should be 0xFFFF_FFFE
  H  — MULH   : `mulh x3, x1, x2`       with x1=-1, x2=2 → x3 should be -1 (= 0xFFFF_FFFF)
  D  — DIVU   : `divu x3, x1, x2`       with x1=0x1000_0000, x2=0x100 → x3 should be 0x0010_0000
  S  — DIV    : `div x3, x1, x2`        with x1=-100, x2=7 → x3 should be -14
  R  — REMU   : `remu x3, x1, x2`       with x1=0x1000_0007, x2=0x100 → x3 should be 0x7
  .  — full iteration completed cleanly. End-of-iteration marker.
@

Expected silicon output: @BMUHDSR.MUHDSR.MUHDSR.…@ (with the 'B'
boot byte once at the start).

Any failed check JALRs to a per-op label that emits 'F' followed by
the op letter, then loops forever printing 'F' so the host sees a
sustained 'F' stream.

== Why BRAM-only

This firmware deliberately avoids SRAM / SDRAM — the M-FU lives
entirely in the core, and we want to isolate its behaviour from
the bus / bridge / external-memory paths. BRAM fetch is the
shortest, most-deterministic instruction-supply path the SoC
offers, so a hang here is unambiguously the M-FU's fault and not
a bridge or controller issue.

== Layout

The firmware fits well inside the 4096-word imem the SoC reserves
for @firmware/phase1/CoreMark.hs@. The Nix build's
@mdStress = true@ flag overlays this module's output as
@CoreMark.coreMarkFirmwareWords@ — same scheme used by the other
stress variants, keeping Top.hs bit-identical across variants.
-}
module HelloMdStress (
  helloMdStressFirmware,
  helloMdStressFirmwareWords,
) where

import Clash.Prelude (BitVector)
import Data.Either qualified as DE
import Riski5.Asm
import Riski5.ISA
import Prelude qualified as P

-- * Firmware -------------------------------------------------------

helloMdStressFirmware :: Asm ()
helloMdStressFirmware = do
  -- Constant register file:
  --   x10 = UART DATA = 0x1000_0000
  --   x14 = scratch / per-byte char
  --   x1 / x2 / x3 = M-op operands and result (re-loaded per op)
  --   x5 / x6 / x7 = expected-value scratch
  li uartReg 0x1000_0000

  -- 'B' boot byte. Confirms BRAM exec + UART are alive.
  addi x14 x0 0x42
  sw uartReg x14 0

  -- ----------------------------------------------------------------
  -- Top of the loop — each iteration emits 7 bytes: M U H D S R '.'
  -- ----------------------------------------------------------------
  loopL <- label

  -- ============================================================
  -- M : MUL  x3 = x1 * x2  with x1=0x1234_5678, x2=0x100
  --     Expected (low 32):  0x4567_8000
  -- ============================================================
  li x1 0x1234_5678
  li x2 0x100
  mul x3 x1 x2
  li x5 0x4567_8000
  -- If x3 != x5, jump to mulFailL; otherwise fall through and emit 'M'.
  mulFailL <- labelUnplaced
  bne x3 x5 mulFailL
  addi x14 x0 0x4D -- 'M'
  sw uartReg x14 0

  -- ============================================================
  -- U : MULHU  x3 = high32(x1 * x2)  with x1=0xFFFF_FFFF, x2=0xFFFF_FFFF
  --     Expected: 0xFFFF_FFFE
  -- ============================================================
  li x1 0xFFFF_FFFF
  li x2 0xFFFF_FFFF
  mulhu x3 x1 x2
  li x5 0xFFFF_FFFE
  mulhuFailL <- labelUnplaced
  bne x3 x5 mulhuFailL
  addi x14 x0 0x55 -- 'U'
  sw uartReg x14 0

  -- ============================================================
  -- H : MULH  x3 = high32(signed × signed)  with x1=-1, x2=2
  --     Expected: -1 (= 0xFFFF_FFFF)  -- because (-1) * 2 = -2,
  --     high32 of the sign-extended 64-bit product is 0xFFFF_FFFF.
  -- ============================================================
  li x1 0xFFFF_FFFF -- = -1 as Signed32
  li x2 0x2
  mulh x3 x1 x2
  li x5 0xFFFF_FFFF
  mulhFailL <- labelUnplaced
  bne x3 x5 mulhFailL
  addi x14 x0 0x48 -- 'H'
  sw uartReg x14 0

  -- ============================================================
  -- D : DIVU  x3 = x1 / x2 (unsigned)  with x1=0x1000_0000, x2=0x100
  --     Expected: 0x0010_0000
  -- ============================================================
  li x1 0x1000_0000
  li x2 0x100
  divu x3 x1 x2
  li x5 0x0010_0000
  divuFailL <- labelUnplaced
  bne x3 x5 divuFailL
  addi x14 x0 0x44 -- 'D'
  sw uartReg x14 0

  -- ============================================================
  -- S : DIV (signed)  x3 = x1 / x2  with x1=-100, x2=7
  --     Expected: -14  (RV32M truncates toward zero: -100 / 7 = -14)
  -- ============================================================
  li x1 0xFFFF_FF9C -- -100 as Signed32
  li x2 0x7
  div_ x3 x1 x2
  li x5 0xFFFF_FFF2 -- -14 as Signed32
  divFailL <- labelUnplaced
  bne x3 x5 divFailL
  addi x14 x0 0x53 -- 'S'
  sw uartReg x14 0

  -- ============================================================
  -- R : REMU  x3 = x1 % x2 (unsigned)  with x1=0x1000_0007, x2=0x100
  --     Expected: 0x7
  -- ============================================================
  li x1 0x1000_0007
  li x2 0x100
  remu x3 x1 x2
  li x5 0x7
  remuFailL <- labelUnplaced
  bne x3 x5 remuFailL
  addi x14 x0 0x52 -- 'R'
  sw uartReg x14 0

  -- ============================================================
  -- '.' end-of-iteration marker.
  -- ============================================================
  addi x14 x0 0x2E -- '.'
  sw uartReg x14 0

  j loopL

  -- ----------------------------------------------------------------
  -- Failure paths — emit 'F' + the failed op's letter, then loop.
  -- ----------------------------------------------------------------
  emitFailL <- label -- helper: x14 already loaded with the op letter
  addi x15 x0 0x46 -- 'F'
  sw uartReg x15 0
  sw uartReg x14 0
  -- Spin emitting 'F' so the host sees a sustained marker stream.
  -- (No conditional needed; the failure path never returns.)
  failSpinL <- label
  addi x15 x0 0x46 -- 'F'
  sw uartReg x15 0
  j failSpinL

  placeAt mulFailL
  addi x14 x0 0x4D -- 'M'
  j emitFailL
  placeAt mulhuFailL
  addi x14 x0 0x55 -- 'U'
  j emitFailL
  placeAt mulhFailL
  addi x14 x0 0x48 -- 'H'
  j emitFailL
  placeAt divuFailL
  addi x14 x0 0x44 -- 'D'
  j emitFailL
  placeAt divFailL
  addi x14 x0 0x53 -- 'S'
  j emitFailL
  placeAt remuFailL
  addi x14 x0 0x52 -- 'R'
  j emitFailL
 where
  uartReg = x10

helloMdStressFirmwareWords :: [BitVector 32]
helloMdStressFirmwareWords =
  DE.fromRight
    (P.error "helloMdStressFirmware failed to assemble")
    (assemble helloMdStressFirmware)
