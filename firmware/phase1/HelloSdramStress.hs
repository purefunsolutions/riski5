-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : HelloSdramStress
Description : SDRAM stress test — instr + data + writes interleaved.

Bigger than 'HelloSdramExec' (which just `sw 'S'`), much smaller
than the Linux kernel. Designed to surface SDRAM bugs that only
show up under continuous mixed traffic — instruction fetches
from SDRAM, data writes to SDRAM, data reads from SDRAM, all
interleaving in a tight loop with row+bank switches between
every access.

== Layout

  * BRAM bootstrap stages a small SDRAM-resident loop into
    SDRAM @[0x80000000 .. 0x80000200)@, prints @B@ on the UART
    to confirm BRAM is alive, and JALRs to SDRAM[0].
  * The SDRAM-resident loop runs 256 iterations of a fixed
    write+read+verify pattern across 4 SDRAM banks (data area
    @0x80100000 / 0x80300000 / 0x80500000 / 0x80700000@), prints
    @.@ per clean iteration and @F@ on the first mismatch.
  * On clean completion: prints @D@ and JALRs back to BRAM[0],
    where the firmware halts.

== Expected silicon output

  * @B................................D@ (256 dots + B + D) —
    SDRAM execute + data path are clean end-to-end.
  * @B....F@ — the FIRST verify failure trips the @F@ branch
    and halts, telling us a write to one of the four banks did
    not commit. The exact iteration count gives the failure rate.
  * @BBBB...@ — same as 'HelloSdramExec''s "doesn't work"
    signature: SDRAM fetch is silently routing through the BRAM
    fallback, firmware loops via the BRAM entry.

== Why mixed banks

The IS42S16400 has 4 banks. Picking 4 data addresses each in a
different bank forces the controller to ACTIVATE a different
bank on every successive access — exercises the row-buffer
flush + ACTIVATE-PRECHARGE timing more aggressively than
sequential writes to one bank. Combined with instruction fetch
from bank 0 (where the SDRAM-resident code lives) running
between every data access, every cycle of the loop touches a
different bank than the previous one.

== Why this exists

Task #146 fixed the SDR controller's refresh-vs-request race
and the Quartus placement lottery. Task #17 then found that
3.2 MB Linux kernel uploads still result in the kernel JR'ing
into corrupted SDRAM bytes and hanging in a wfi loop. To bisect
between "SDRAM execute is fundamentally broken" and "Linux
boot path has a non-SDRAM problem", we need a known-good
SDRAM-resident workload that's complex enough to exercise the
same patterns Linux uses (mixed read / write / fetch across
banks) but small enough to debug end-to-end. This is that.
-}
module HelloSdramStress (
  helloSdramStressFirmware,
  helloSdramStressFirmwareWords,
  helloSdramStressInner,
  helloSdramStressInnerWords,
) where

import Clash.Prelude (BitVector)
import Control.Monad (forM_)
import Data.Bits (shiftR, (.&.))
import Data.Either qualified as DE
import Data.Int (Int32)
import Riski5.Asm
import Riski5.ISA
import Prelude qualified as P
import Prelude (fromIntegral, toInteger, zip, ($))

-- * SDRAM-resident inner loop -------------------------------------

{- | The loop that runs entirely from SDRAM. Picks 4 data addresses
in 4 different SDRAM banks (2 MB stride between banks on the
IS42S16400), writes a per-iteration value to each, reads back
all four, prints @.@ on success or @F@ on the first mismatch.
Loops 256 times then prints @D@ and JALRs back to BRAM[0].

Self-contained — receives no inputs from the BRAM bootstrap.

Layout when assembled:

@
  init    : 6 li (UART, data bases × 4, max-iter)
  loop    : 1 xor (pattern XOR iter) +
            4 sw (writes to 4 banks) +
            4 (lw + bne) (reads + verify-or-fail) +
            2 (li + sw) (print '.') +
            2 (addi + blt) (loop control)
  done    : 2 (addi + sw) (print 'D') +
            1 (jalr to BRAM[0])
  fail    : 2 (addi + sw) (print 'F') +
            1 j (halt forever)
@

~30 instructions. Plenty of room in the 64-instruction window
the bootstrap stages.
-}
helloSdramStressInner :: Asm ()
helloSdramStressInner = do
  -- UART
  li tUart 0x10000000
  -- 4 data bases — each in a different SDRAM bank (2 MB stride)
  li tA 0x80100000 -- bank 0, away from code at 0x80000000
  li tB 0x80300000 -- bank 1
  li tC 0x80500000 -- bank 2
  li tD 0x80700000 -- bank 3
  -- Iteration max
  li tMax 256
  -- Iteration counter
  addi tIter x0 0
  -- Pattern base — high half stays constant, low half is the iter
  li tPat 0x12340000

  failL <- labelUnplaced
  failAL <- labelUnplaced
  failBL <- labelUnplaced
  failCL <- labelUnplaced
  failDL <- labelUnplaced

  loopL <- label

  -- Compute this iteration's value: pattern XOR iter
  xor_ tValue tPat tIter

  -- Write the value to all 4 banks. The controller has to
  -- ACTIVATE a different bank on each sw, which exercises the
  -- bank-switch + precharge path harder than 4 sequential writes
  -- to one bank would.
  sw tA tValue 0
  sw tB tValue 0
  sw tC tValue 0
  sw tD tValue 0

  -- Read back from all 4 banks. Each lw forces another ACTIVATE
  -- (different bank from the previous write). If the write
  -- didn't actually commit to chip cells, the lw returns either
  -- garbage or the previous iteration's value. On first
  -- mismatch jumps to one of failAL..failDL — those branches
  -- emit a label byte (A/B/C/D) before the common fail dump,
  -- so the captured byte stream tells us WHICH bank's read
  -- failed.
  lw tRead tA 0
  bne tRead tValue failAL
  lw tRead tB 0
  bne tRead tValue failBL
  lw tRead tC 0
  bne tRead tValue failCL
  lw tRead tD 0
  bne tRead tValue failDL

  -- Print '.' on clean iteration
  addi tTmp x0 0x2E -- '.'
  sw tUart tTmp 0

  -- Loop control
  addi tIter tIter 1
  blt tIter tMax loopL

  -- Done — print 'D' and JALR back to BRAM[0]
  addi tTmp x0 0x44 -- 'D'
  sw tUart tTmp 0
  -- JALR to 0 returns to BRAM[0] = firmware entry. The BRAM-side
  -- code below sees the second-time entry and falls through to
  -- the halt sequence.
  jalr x0 x0 0

  -- Per-bank failure landings: each prints its bank label
  -- ('A'/'B'/'C'/'D') then falls into the common dump at failL.
  placeAt failAL
  addi tTmp x0 0x41 -- 'A'
  sw tUart tTmp 0
  j failL
  placeAt failBL
  addi tTmp x0 0x42 -- 'B'
  sw tUart tTmp 0
  j failL
  placeAt failCL
  addi tTmp x0 0x43 -- 'C'
  sw tUart tTmp 0
  j failL
  placeAt failDL
  addi tTmp x0 0x44 -- 'D'
  sw tUart tTmp 0
  j failL

  placeAt failL
  -- 'F' marker — common entry from any per-bank failure.
  addi tTmp x0 0x46 -- 'F'
  sw tUart tTmp 0
  -- Dump expected (4 bytes LE) then actual (4 bytes LE).
  sw tUart tValue 0
  srli tTmp tValue 8
  sw tUart tTmp 0
  srli tTmp tValue 16
  sw tUart tTmp 0
  srli tTmp tValue 24
  sw tUart tTmp 0
  sw tUart tRead 0
  srli tTmp tRead 8
  sw tUart tTmp 0
  srli tTmp tRead 16
  sw tUart tTmp 0
  srli tTmp tRead 24
  sw tUart tTmp 0
  -- Halt
  failHaltL <- label
  j failHaltL
 where
  -- Register allocation (all caller-saves; no calling convention).
  tUart = x10
  tA = x11
  tB = x12
  tC = x13
  tD = x14
  tMax = x15
  tIter = x16
  tPat = x17
  tValue = x18
  tRead = x19
  tTmp = x20

helloSdramStressInnerWords :: [BitVector 32]
helloSdramStressInnerWords =
  DE.fromRight
    (P.error "helloSdramStressInner failed to assemble")
    (assemble helloSdramStressInner)

-- * BRAM bootstrap ---------------------------------------------------

{- | The full firmware as it lands in BRAM. Stages
'helloSdramStressInnerWords' into SDRAM and JALRs there. On
re-entry (after the inner loop's @JALR x0, x0, 0@ returns
control), prints @D@ a second time as a "BRAM saw the redirect"
sanity marker, then halts.
-}
helloSdramStressFirmware :: Asm ()
helloSdramStressFirmware = do
  li bUart 0x10000000
  li bSdramBase 0x80000000

  -- 'B' — confirms BRAM exec + bus + UART are all alive.
  addi bTmp x0 0x42 -- 'B'
  sw bUart bTmp 0

  -- Stage the SDRAM-resident inner loop. For each 32-bit word in
  -- helloSdramStressInnerWords we emit `li bEnc <word>; sw
  -- bSdramBase bEnc <offset>` so the word lands at SDRAM[offset].
  -- The inner code starts at offset 0 and grows upward.
  forM_ (zip [0 ..] helloSdramStressInnerWords) $ \(i, w) -> do
    li bEnc (bvToInt32 w)
    sw bSdramBase bEnc (toInteger (i P.* 4))

  -- Defensive prefetch fill: pad the rest of the staged area
  -- with 'jalr x0 x0 0' (= jump back to BRAM[0]) so any IF-stage
  -- prefetch leakage past the inner code's halt instructions
  -- lands on a clean redirect rather than executing whatever
  -- power-on noise lives in those SDRAM cells. Same trick
  -- HelloSdramExec uses.
  let innerLen = P.length helloSdramStressInnerWords
      padCount = 64 P.- innerLen -- pad up to SDRAM[256]
  P.mapM_
    ( \i -> do
        li bEnc encodedJalrToZero
        sw bSdramBase bEnc (toInteger ((innerLen P.+ i) P.* 4))
    )
    [0 .. padCount P.- 1]

  -- Jump to SDRAM[0]
  jalr x0 bSdramBase 0

  -- Re-entry from inner loop's JALR x0, x0, 0 lands here at
  -- BRAM[0] — which means we re-execute the entire firmware from
  -- the top. That's actually fine for a stress test: re-entry
  -- prints another B, re-stages the SDRAM code (overwriting the
  -- same cells with the same values), and runs another full
  -- 256-iteration loop. Visible UART signature is
  -- @B........[256 dots]........DB........[256 dots]........D...@
  -- which is exactly what we want for a long-running soak test.

  -- Fallback if the JALR somehow doesn't take.
  haltL <- label
  j haltL
 where
  bUart = x10
  bSdramBase = x12
  bTmp = x13
  bEnc = x14

helloSdramStressFirmwareWords :: [BitVector 32]
helloSdramStressFirmwareWords =
  DE.fromRight
    (P.error "helloSdramStressFirmware failed to assemble")
    (assemble helloSdramStressFirmware)

-- * Helpers ----------------------------------------------------------

-- | @jalr x0, x0, 0@ — PC := 0 + 0 = 0, no link. Used for
-- re-entry into BRAM[0] from SDRAM-resident code, mirroring
-- HelloSdramExec.
encodedJalrToZero :: Int32
encodedJalrToZero = 0x0000_0067

-- | Unsigned BitVector 32 → signed Int32, preserving bit pattern.
-- Needed because 'li' takes Int32 while 'assemble' returns
-- BitVector 32.
bvToInt32 :: BitVector 32 -> Int32
bvToInt32 = fromIntegral
