-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : HelloTimerIrq
Description : Debug firmware — fire a CLINT timer interrupt on silicon.

Probes the end-to-end machine-timer-interrupt path: CLINT's
@mtipS@ strobe → @mip.MTIP@ → core's @interruptPending@ predicate
→ trap to @mtvec.base@ → handler → @mret@ → back to main. Same
shape as the @TimerIrqSpec@ sim test, but running on real hardware
through the real CLINT hardware block at @0x1000_0060@.

== UART script

The boot stub prints 'B' once at boot. The handler prints 'T'
(timer interrupt) every time it fires. Main loop prints '.'
between handler entries, slowly enough that '.' is visible
between every pair of 'T's.

Expected silicon output: @B......T......T......T…@ — a startup
'B', then a steady cadence of '.'-runs separated by 'T's. The
spacing is determined by the @MTIMECMP_INCREMENT@ constant
below: each handler entry pushes @mtimecmp@ forward by
this many ticks before @mret@-ing, so the next interrupt
arrives @MTIMECMP_INCREMENT / clock-rate@ later.

The handler is intentionally __very small__: it bumps
@mtimecmp@, prints 'T', and returns. No saved-context dance —
the spec lets us clobber caller-saved registers because the
test loop doesn't rely on them across iterations. A full RTOS
trap-handler would save / restore but that's out of scope for
this probe.

== Layout

Boot lives at PC 0; the trap handler lives at byte offset
@0x80@ (word 32) inside the imem so that setting
@mtvec.base = 0x80@ is straightforward. The 'stitch' helper
pads the gap with NOPs so the boot stub stays under 32 words.
Firmware fits comfortably inside the 4096-word imem the SoC
reserves for @firmware/phase1/CoreMark.hs@.

The Nix build's @timerIrqTest = true@ flag overlays this
module's output as @CoreMark.coreMarkFirmwareWords@, mirroring
the @sramExec@ / @sdramExec@ / @aExtTest@ pattern.
-}
module HelloTimerIrq (
  helloTimerIrqFirmware,
  helloTimerIrqFirmwareWords,
) where

import Clash.Prelude (BitVector, Signed)
import Data.Either (Either (..))
import Riski5.Asm
import Riski5.ISA
import Prelude qualified as P

-- | How far past current 'mtime' the handler pushes 'mtimecmp'
-- before returning. At a 40 MHz core clock, 4M ticks ≈ 100 ms,
-- which is comfortable for human-eye verification when watching
-- the 'T'-cadence on a JTAG-UART terminal.
mtimecmpIncrement :: P.Int
mtimecmpIncrement = 4_000_000

-- * Firmware -------------------------------------------------------

helloTimerIrqFirmware :: Asm ()
helloTimerIrqFirmware = do
  -- Boot stub: words 0..31. Sets mtvec, enables MTIE + MIE,
  -- arms an initial mtimecmp, then spins printing '.'.
  --
  -- Register allocation:
  --   x10 — UART DATA address    (0x1000_0000)
  --   x11 — CLINT base           (0x1000_0060)
  --   x12 — scratch / ABI a2
  --   x13 — scratch / ABI a3
  --   x14 — character byte
  --   x18 — periodic '.' delay counter
  li uartReg 0x1000_0000
  li clintReg 0x1000_0060

  -- Print 'B' so the host sees boot completed before timer fires.
  addi x14 x0 (0x42 :: Signed 12) -- 'B'
  sw uartReg x14 0

  -- mtvec.base := 0x80 (word 32, MODE = 0 = direct).
  addi x12 x0 0x80
  csrrw x0 x12 csrMtvec

  -- Arm initial mtimecmp = mtime + initial increment. The handler
  -- re-arms each subsequent firing.
  csrrs x12 x0 csrMcycle -- read current mcycle as a stand-in for mtime
  -- mtime is also live at clintReg + 0x00; using mcycle here keeps
  -- the boot path fenceless and one CSR read.
  li x13 (P.fromIntegral mtimecmpIncrement)
  add x12 x12 x13
  -- Write mtimecmp low half = computed value; mtimecmp high = 0.
  sw clintReg x12 8
  sw clintReg x0 12

  -- mie.MTIE := 1 (bit 7).
  addi x12 x0 (0x80 :: Signed 12)
  csrrs x0 x12 csrMie

  -- mstatus.MIE := 1 (bit 3).
  addi x12 x0 (0x8 :: Signed 12)
  csrrs x0 x12 csrMstatus

  -- Main loop: print a '.' every ~16K cycles so the host sees a
  -- background dot stream punctuated by 'T's from the handler.
  loopL <- label
  addi x18 x18 1
  -- Mask off all but a chunky bit so the SW only fires every
  -- ~16K iterations: branch if (counter & 0x3FFF) /= 0 back to top.
  -- We don't have a fast and-with-mask path, so just decrement and
  -- branch — equivalent inner cadence.
  andi x12 x18 0x3FF -- low 10 bits
  bne x12 x0 loopL -- 1023 of every 1024 iterations, skip the dot

  addi x14 x0 (0x2E :: Signed 12) -- '.'
  sw uartReg x14 0
  j loopL

  -- Pad up to word 32 with NOPs. The .pad helper would be nice,
  -- but Asm doesn't have one — we rely on the Nix build's
  -- @stitchAt32@ wrapper to pad with NOPs before stitching the
  -- handler in. (See helloTimerIrqFirmwareWords below.)

helloTimerIrqHandler :: Asm ()
helloTimerIrqHandler = do
  -- Handler: re-arm mtimecmp, print 'T', mret.
  -- We use callee-saved-via-clobber semantics — the main loop
  -- doesn't rely on x12/x13/x14 across iterations.

  li uartReg 0x1000_0000
  li clintReg 0x1000_0060

  -- mtimecmp_new := current mtime + increment.
  csrrs x12 x0 csrMcycle
  li x13 (P.fromIntegral mtimecmpIncrement)
  add x12 x12 x13
  sw clintReg x12 8
  sw clintReg x0 12

  -- Print 'T'.
  addi x14 x0 (0x54 :: Signed 12)
  sw uartReg x14 0

  -- Return to interrupted instruction (mret restores MIE from MPIE).
  mret

-- * Wiring ---------------------------------------------------------
--
-- The boot stub goes at word 0; the handler goes at word 32 (byte
-- offset 0x80). 'stitchAt32' pads with NOPs so the handler always
-- lands exactly at word 32. If the boot stub grows past 32 words,
-- assembly errors at compile time.

helloTimerIrqFirmwareWords :: [BitVector 32]
helloTimerIrqFirmwareWords =
  let bootBytes = case assemble helloTimerIrqFirmware of
        Left err -> P.error ("HelloTimerIrq boot: " P.++ P.show err)
        Right ws -> ws
      handlerBytes = case assemble helloTimerIrqHandler of
        Left err -> P.error ("HelloTimerIrq handler: " P.++ P.show err)
        Right ws -> ws
      bootLen = P.length bootBytes
      gapLen = 32 P.- bootLen
   in if gapLen P.< 0
        then P.error "HelloTimerIrq: boot stub grew past word 32; trim or relocate handler"
        else
          bootBytes
            P.++ P.replicate gapLen 0x0000_0013
            P.++ handlerBytes

uartReg, clintReg :: Reg
uartReg = x10
clintReg = x11
