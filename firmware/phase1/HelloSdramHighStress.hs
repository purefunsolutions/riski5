-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : HelloSdramHighStress
Description : SDRAM stress focused on the upper-2-MB region (#64 follow-up).

Targeted bisect for the high-SDRAM corruption observed during the
2026-05-08 silicon Linux-to-userspace boot. The kernel's page
allocator placed @/init@'s text at @0x807cc000@ (~24 KB below the
top of the 8 MB SDRAM); reads from that page came back as
@0xffff fddf ffff …@ — the classic uninitialised-SDRAM pattern,
even though the kernel believed it had populated the page seconds
earlier. We worked around it by capping the kernel's @memory@
node to 6 MB in the DTS, but that's a limitation, not a fix.

This firmware narrows the question down to "does our SDRAM
controller / chip stack actually serve writes-then-reads
correctly at addresses above 6 MB?" by running a mixed-pass
walking-pattern stress over the full 8 MB region with the upper
2 MB getting the densest coverage.

== Layout

Code runs entirely from BRAM (no SDRAM exec) so the IF stage is
out of the picture and any fault is purely a data-port bug.

  * Phase 1 — write a per-address pattern across two regions:
      - the LOW-CONTROL region  @[0x80000000 .. 0x80600000)@
        at 4 KB stride (1536 writes), every 64th stride emits a
        @,@ on the UART (24 dots).
      - the HIGH-SUSPECT region @[0x80600000 .. 0x80800000)@
        at 1 KB stride (2048 writes), every 16th stride emits a
        @.@ on the UART (128 dots, much denser).
      The pattern is @addr ^ 0xDEADBEEF@ — every word is unique,
      no aliasing.

  * Phase 2 — read everything back in the same order, compare
    against the expected pattern. Same @,@ / @.@ progress markers.
    On the first mismatch print
      @F<region:1B><addr-LE:4B><expected-LE:4B><actual-LE:4B>@
    and halt. Region byte is @L@ for low-control or @H@ for
    high-suspect.

  * Phase 3 — wait briefly (so any refresh-interval-related decay
    has a chance to happen) then re-read everything one more time.
    Failures here but not in phase 2 indicate a refresh / decay
    bug rather than a write-path bug. Print @r,@ / @r.@ for clean,
    @D@ for failure (with the same @<region><addr><exp><act>@
    payload).

  * On clean completion of all three phases: prints @PASS@ and
    halts.

== Expected silicon outputs

  * @B,,,,,,,,,,,,,,,,,,,,,,,,................................................................................................................,,,,,,,,,,,,,,,,,,,,,,,,................................................................................................................r,r,r,…r.r.…PASS@
    — full clean run, all three phases.
  * @B,,…,..F<H><AA AA 80 80><BE BE AD DE><FF FF FF FF>@
    — high-suspect region failure during phase 2 (write+immediate
    re-read), addr 0x8080AAAA, expected pattern, read back all-FFs.
    Confirms the high-half data-path bug.
  * @B,,…,..PASS,,,…,..D<H>…@ — passes phase 2 but fails phase 3
    re-read; refresh/decay bug rather than a write-path bug.
  * @B,,…,..PASS,,,…,..PASS@ — full pass (highly suggestive that
    the bug is some interaction between the kernel page allocator
    and the controller, not a raw data-path issue).

== Hwsim cross-check

Build also via @nix build .#riski5-sim@ and run inside @verilambda@
the same way 'HelloSdramStress' is run. The
@pkgs/riski5-sim/verilog/riski5_sim_top.v@ @sim_sdram_chip@ is a
clean JEDEC-protocol model with a single @reg [15:0] mem [0:4194303]@
backing array and no per-address pathology, so a hwsim PASS plus
a silicon FAIL definitively pins the bug to the silicon side
(controller timing, chip wiring, or a Quartus inference issue) and
rules out our pure-Clash @Riski5.SdrController@ logic. Conversely,
hwsim FAIL would point at the controller code and is the
follow-up worth hunting first.

== Sizing rationale

  * 1 KB stride in the high-suspect region gives 2048 distinct
    column / row / bank combinations across the upper 2 MB. The
    IS42S16400 has 4 banks × 4096 rows × 256 cols × 16-bit data,
    so 1 KB corresponds to 512 16-bit words = 2 columns of 256
    each = exactly one row at a time on each pass through a bank,
    landing every test address on a different bank-row pair.
  * 4 KB stride in the low-control region keeps the test runtime
    bounded (1536 strides) while still exercising every bank.
  * Total transactions (3 phases × (1536 + 2048)) ≈ 10 k. At
    40 MHz with the controller's ~10 cycles per access, ~2.5 ms
    of SDRAM traffic — finishes in well under a second on
    silicon, fast enough for hwsim too.
-}
module HelloSdramHighStress (
  helloSdramHighStressFirmware,
  helloSdramHighStressFirmwareWords,
) where

import Clash.Prelude (BitVector)
import Data.Either qualified as DE
import Data.Int (Int32)
import Riski5.Asm
import Riski5.ISA
import Prelude qualified as P

-- * Region constants ----------------------------------------------

lowBase, lowEnd, lowStride :: Int32
lowBase   = 0x80000000 :: Int32  -- 0x80000000 wraps to negative as Int32; OK
lowEnd    = 0x80600000 :: Int32  -- (treated as unsigned by bltu later)
lowStride = 0x1000               -- 4 KB

highBase, highEnd, highStride :: Int32
highBase   = 0x80600000 :: Int32
highEnd    = 0x80800000 :: Int32  -- 8 MB top
highStride = 0x400                -- 1 KB

-- Pattern XOR mask. Every test word = (addr ^ patternMask).
-- Distinct per-address so any cross-talk between addresses is
-- visible as a mismatch.
patternMask :: Int32
patternMask = 0xDEADBEEF :: Int32  -- wraps to negative; XOR is bitwise so fine

-- Progress-print sub-divisions: one UART byte every Nth stride.
-- 4 KB stride × 64 = 256 KB per dot in low region (24 commas total).
-- 1 KB stride × 16 = 16 KB per dot in high region (128 dots total).
lowDotEvery, highDotEvery :: Int32
lowDotEvery  = 64
highDotEvery = 16

helloSdramHighStressFirmware :: Asm ()
helloSdramHighStressFirmware = do
  -- Constant register file:
  --   x10 = UART data register pointer  (= 0x10000000)
  --   x11 = pattern XOR mask             (= 0xDEADBEEF)
  --   x12 = current address              (loop var)
  --   x13 = expected value at addr       (addr ^ pattern)
  --   x14 = read-back value              (for diff)
  --   x15 = stride counter (for progress dots)
  --   x16 = scratch
  --   x17 = scratch (region marker byte)
  --   x18 = end-of-region address (loop bound)
  --   x19 = current stride                (4 KB or 1 KB)
  --   x20 = dots-per-print modulus        (64 or 16)
  let uartReg     = x10
      patReg      = x11
      addrReg     = x12
      expReg      = x13
      readReg     = x14
      strideCntR  = x15
      tmpReg      = x16
      regionR     = x17
      endReg      = x18
      strideReg   = x19
      modReg      = x20

  li uartReg 0x10000000
  li patReg  patternMask

  -- 'B' boot byte. Confirms BRAM exec + UART are alive.
  li tmpReg 0x42
  sw uartReg tmpReg 0

  -- Forward-reference labels for the four "skip dot" sites and
  -- the central failure handler. labelUnplaced lets the bne
  -- reference them before placeAt names their target address.
  p1LowWrSkipDot  <- labelUnplaced
  p1HighWrSkipDot <- labelUnplaced
  p2LowRdSkipDot  <- labelUnplaced
  p2HighRdSkipDot <- labelUnplaced
  p3LowRdSkipDot  <- labelUnplaced
  p3HighRdSkipDot <- labelUnplaced
  failL           <- labelUnplaced

  ----------------------------------------------------------------
  -- Phase 1 — WRITE
  ----------------------------------------------------------------

  -- Phase-1 low-region writes
  li regionR (P.fromIntegral (P.fromEnum 'L'))
  li addrReg lowBase
  li endReg  lowEnd
  li strideReg lowStride
  li modReg  lowDotEvery
  li strideCntR 0

  p1LowWrLoop <- label
  -- expected = addr ^ pattern
  xor_ expReg addrReg patReg
  sw addrReg expReg 0
  -- progress dot every modReg strides
  addi strideCntR strideCntR 1
  remu tmpReg strideCntR modReg
  bne tmpReg x0 p1LowWrSkipDot
  li tmpReg (P.fromIntegral (P.fromEnum ','))
  sw uartReg tmpReg 0
  placeAt p1LowWrSkipDot
  add addrReg addrReg strideReg
  bltu addrReg endReg p1LowWrLoop

  -- Phase-1 high-region writes
  li regionR (P.fromIntegral (P.fromEnum 'H'))
  li addrReg highBase
  li endReg  highEnd
  li strideReg highStride
  li modReg  highDotEvery
  li strideCntR 0

  p1HighWrLoop <- label
  xor_ expReg addrReg patReg
  sw addrReg expReg 0
  addi strideCntR strideCntR 1
  remu tmpReg strideCntR modReg
  bne tmpReg x0 p1HighWrSkipDot
  li tmpReg (P.fromIntegral (P.fromEnum '.'))
  sw uartReg tmpReg 0
  placeAt p1HighWrSkipDot
  add addrReg addrReg strideReg
  bltu addrReg endReg p1HighWrLoop

  ----------------------------------------------------------------
  -- Phase 2 — READ-BACK (immediate)
  ----------------------------------------------------------------

  -- Low region readback
  li regionR (P.fromIntegral (P.fromEnum 'L'))
  li addrReg lowBase
  li endReg  lowEnd
  li strideReg lowStride
  li modReg  lowDotEvery
  li strideCntR 0

  p2LowRdLoop <- label
  xor_ expReg addrReg patReg
  lw readReg addrReg 0
  bne readReg expReg failL
  addi strideCntR strideCntR 1
  remu tmpReg strideCntR modReg
  bne tmpReg x0 p2LowRdSkipDot
  li tmpReg (P.fromIntegral (P.fromEnum ','))
  sw uartReg tmpReg 0
  placeAt p2LowRdSkipDot
  add addrReg addrReg strideReg
  bltu addrReg endReg p2LowRdLoop

  -- High region readback
  li regionR (P.fromIntegral (P.fromEnum 'H'))
  li addrReg highBase
  li endReg  highEnd
  li strideReg highStride
  li modReg  highDotEvery
  li strideCntR 0

  p2HighRdLoop <- label
  xor_ expReg addrReg patReg
  lw readReg addrReg 0
  bne readReg expReg failL
  addi strideCntR strideCntR 1
  remu tmpReg strideCntR modReg
  bne tmpReg x0 p2HighRdSkipDot
  li tmpReg (P.fromIntegral (P.fromEnum '.'))
  sw uartReg tmpReg 0
  placeAt p2HighRdSkipDot
  add addrReg addrReg strideReg
  bltu addrReg endReg p2HighRdLoop

  -- Print PASS so the user can see phase-2 succeeded before we
  -- spend extra time on phase-3 refresh-decay testing.
  li tmpReg (P.fromIntegral (P.fromEnum 'P'))
  sw uartReg tmpReg 0
  li tmpReg (P.fromIntegral (P.fromEnum 'A'))
  sw uartReg tmpReg 0
  li tmpReg (P.fromIntegral (P.fromEnum 'S'))
  sw uartReg tmpReg 0
  li tmpReg (P.fromIntegral (P.fromEnum 'S'))
  sw uartReg tmpReg 0
  li tmpReg (P.fromIntegral (P.fromEnum '1'))
  sw uartReg tmpReg 0

  ----------------------------------------------------------------
  -- Phase 3 — DELAY then RE-READ (refresh / decay test)
  ----------------------------------------------------------------

  -- Burn a few million cycles to give SDRAM refresh time to
  -- demonstrate any decay. ~4 M cycles at 40 MHz = 100 ms.
  li tmpReg 4000000
  delayLoop <- label
  addi tmpReg tmpReg (-1)
  bne tmpReg x0 delayLoop

  -- Low region re-read
  li regionR (P.fromIntegral (P.fromEnum 'L'))
  li addrReg lowBase
  li endReg  lowEnd
  li strideReg lowStride
  li modReg  lowDotEvery
  li strideCntR 0

  p3LowRdLoop <- label
  xor_ expReg addrReg patReg
  lw readReg addrReg 0
  bne readReg expReg failL
  addi strideCntR strideCntR 1
  remu tmpReg strideCntR modReg
  bne tmpReg x0 p3LowRdSkipDot
  -- 'r' prefix on phase-3 dots so the operator can tell phases apart.
  li tmpReg (P.fromIntegral (P.fromEnum 'r'))
  sw uartReg tmpReg 0
  li tmpReg (P.fromIntegral (P.fromEnum ','))
  sw uartReg tmpReg 0
  placeAt p3LowRdSkipDot
  add addrReg addrReg strideReg
  bltu addrReg endReg p3LowRdLoop

  -- High region re-read
  li regionR (P.fromIntegral (P.fromEnum 'H'))
  li addrReg highBase
  li endReg  highEnd
  li strideReg highStride
  li modReg  highDotEvery
  li strideCntR 0

  p3HighRdLoop <- label
  xor_ expReg addrReg patReg
  lw readReg addrReg 0
  bne readReg expReg failL
  addi strideCntR strideCntR 1
  remu tmpReg strideCntR modReg
  bne tmpReg x0 p3HighRdSkipDot
  li tmpReg (P.fromIntegral (P.fromEnum 'r'))
  sw uartReg tmpReg 0
  li tmpReg (P.fromIntegral (P.fromEnum '.'))
  sw uartReg tmpReg 0
  placeAt p3HighRdSkipDot
  add addrReg addrReg strideReg
  bltu addrReg endReg p3HighRdLoop

  ----------------------------------------------------------------
  -- All three phases passed.
  ----------------------------------------------------------------
  li tmpReg (P.fromIntegral (P.fromEnum 'P'))
  sw uartReg tmpReg 0
  li tmpReg (P.fromIntegral (P.fromEnum 'A'))
  sw uartReg tmpReg 0
  li tmpReg (P.fromIntegral (P.fromEnum 'S'))
  sw uartReg tmpReg 0
  li tmpReg (P.fromIntegral (P.fromEnum 'S'))
  sw uartReg tmpReg 0
  li tmpReg (P.fromIntegral (P.fromEnum '2'))
  sw uartReg tmpReg 0
  doneL <- label
  j doneL

  ----------------------------------------------------------------
  -- Fail handler — prints F<region:1B><addr:4B><exp:4B><act:4B>
  -- then halts. addrReg / expReg / readReg / regionR are all
  -- live from whichever read loop tripped.
  ----------------------------------------------------------------
  placeAt failL
  li tmpReg (P.fromIntegral (P.fromEnum 'F'))
  sw uartReg tmpReg 0
  -- region byte
  sw uartReg regionR 0
  -- addr (LE)
  sw uartReg addrReg 0
  srli tmpReg addrReg 8
  sw uartReg tmpReg 0
  srli tmpReg addrReg 16
  sw uartReg tmpReg 0
  srli tmpReg addrReg 24
  sw uartReg tmpReg 0
  -- expected (LE)
  sw uartReg expReg 0
  srli tmpReg expReg 8
  sw uartReg tmpReg 0
  srli tmpReg expReg 16
  sw uartReg tmpReg 0
  srli tmpReg expReg 24
  sw uartReg tmpReg 0
  -- actual (LE)
  sw uartReg readReg 0
  srli tmpReg readReg 8
  sw uartReg tmpReg 0
  srli tmpReg readReg 16
  sw uartReg tmpReg 0
  srli tmpReg readReg 24
  sw uartReg tmpReg 0
  failHaltL <- label
  j failHaltL

helloSdramHighStressFirmwareWords :: [BitVector 32]
helloSdramHighStressFirmwareWords =
  DE.fromRight
    (P.error "helloSdramHighStressFirmware failed to assemble")
    (assemble helloSdramHighStressFirmware)
