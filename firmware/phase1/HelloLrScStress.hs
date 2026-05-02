-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : HelloLrScStress
Description : SDRAM LR/SC cmpxchg stress test — atomic CAS loops + fetch contention.

Companion to 'HelloAmoStress'. Where that firmware exercises the
AMO* family (amoswap.w specifically — Read+Write Mealy phases),
this one exercises the LR.W + SC.W pair as the kernel uses them:
in a back-to-back compare-and-swap retry loop. Targeted at the
Linux stack-protector panic at PC=0x8002cd98, which lands inside
@task_work_add@'s @.L15@ branch — an @lr.w → bne → sc.w.rl →
bnez retry@ cmpxchg loop followed by a computed-jump-table
dispatch. If the LR/SC pair has a reservation-tracking bug (e.g.
reservation prematurely cleared, SC.W spuriously failing, or
Write completion not committing under fetch contention), the
cmpxchg either loops forever or stores the wrong value and the
post-CAS jump-table dispatch jumps off the rails.

== Cmpxchg pattern (mirrors the kernel's @arch_cmpxchg32_relaxed@)

@
  retry:
    lr.w    rdOld, [addr]            # latch + register reservation
    bne     rdOld, rExpected, mismatch  # value changed → fail
    sc.w.rl rdSc,  [addr], rNew       # try to commit new value
    bnez    rdSc, retry               # SC failed (reservation lost) → retry
  mismatch:
    # rdOld holds the value we read (= what was actually in mem)
@

In the kernel: if the loop succeeds, the cmpxchg returns 0 and
@rdOld == rExpected@. If it fails (value changed under us), the
loop exits and @rdOld != rExpected@.

== This firmware's per-iteration test

For each of 4 SDRAM banks:

  1. @sw [bank], expected@ — pre-seed a known value.
  2. Run the cmpxchg retry loop above with @rExpected = expected@,
     @rNew = expected + bankIdx@.
  3. After the loop exits: @rdOld@ MUST equal @expected@. If not,
     the LR/SC pair returned a stale or wrong value during the
     read — fail the iteration.
  4. Verify-read the bank: @lw verify, [bank]@. @verify@ MUST
     equal @expected + bankIdx@. If not, the SC.W spuriously
     failed (no commit) or wrote the wrong value.
  5. (Optional bonus): a second cmpxchg with a DIFFERENT expected
     should see the real new value and succeed-or-fail based on
     match. Skipped here to keep the firmware compact — the basic
     loop is the discriminating signal.

== Failure shapes

  * @B......F...@ — first @F@ + bank label tells which bank's
    LR/SC misbehaved. The 8 trailing bytes dump expected/actual.
  * Long pause with no output then watchdog → SC.W never
    succeeds (cmpxchg loops forever).

== Layout

Same shape as @HelloAmoStress@: BRAM bootstrap stages an
SDRAM-resident inner loop, JALRs to SDRAM[0]. After 64 clean
iterations: prints @D@ and JALRs back to BRAM[0].
-}
module HelloLrScStress (
  helloLrScStressFirmware,
  helloLrScStressFirmwareWords,
  helloLrScStressInner,
  helloLrScStressInnerWords,
) where

import Clash.Prelude (BitVector)
import Control.Monad (forM_)
import Data.Either qualified as DE
import Data.Int (Int32)
import Riski5.Asm
import Riski5.ISA
import Prelude qualified as P
import Prelude (fromIntegral, toInteger, zip, ($))

-- * SDRAM-resident inner loop -------------------------------------

{- | Inner loop. Runs entirely from SDRAM. Exercises @lr.w + sc.w@
across 4 SDRAM banks per iteration via the cmpxchg retry pattern.
-}
helloLrScStressInner :: Asm ()
helloLrScStressInner = do
  -- UART
  li tUart 0x10000000
  -- 4 data bases — each in a different SDRAM bank (2 MB stride)
  li tA 0x80100000 -- bank 0
  li tB 0x80300000 -- bank 1
  li tC 0x80500000 -- bank 2
  li tD 0x80700000 -- bank 3
  -- Iteration max
  li tMax 64
  -- Iteration counter
  addi tIter x0 0
  -- Pattern base
  li tPat 0x55550000

  failAL <- labelUnplaced
  failBL <- labelUnplaced
  failCL <- labelUnplaced
  failDL <- labelUnplaced
  failL <- labelUnplaced

  loopL <- label

  -- Compute this iteration's expected value
  xor_ tExpected tPat tIter

  -- Per bank: pre-seed, cmpxchg, verify
  -- Bank A
  sw tA tExpected 0
  addi tNew tExpected 1
  retryAL <- label
  lr_w tOld tA 0
  bne tOld tExpected failAL -- if mem != expected, the seed didn't take (can't happen here)
  sc_w tSc tA tNew 2 -- aqrl=0b10 = .rl (release semantics, like kernel)
  bne tSc x0 retryAL -- if SC failed, retry the cmpxchg
  -- Verify bank A holds the new value
  lw tOld tA 0
  bne tOld tNew failAL

  -- Bank B
  sw tB tExpected 0
  addi tNew tExpected 2
  retryBL <- label
  lr_w tOld tB 0
  bne tOld tExpected failBL
  sc_w tSc tB tNew 2
  bne tSc x0 retryBL
  lw tOld tB 0
  bne tOld tNew failBL

  -- Bank C
  sw tC tExpected 0
  addi tNew tExpected 3
  retryCL <- label
  lr_w tOld tC 0
  bne tOld tExpected failCL
  sc_w tSc tC tNew 2
  bne tSc x0 retryCL
  lw tOld tC 0
  bne tOld tNew failCL

  -- Bank D
  sw tD tExpected 0
  addi tNew tExpected 4
  retryDL <- label
  lr_w tOld tD 0
  bne tOld tExpected failDL
  sc_w tSc tD tNew 2
  bne tSc x0 retryDL
  lw tOld tD 0
  bne tOld tNew failDL

  -- Print '.' on clean iteration
  addi tTmp x0 0x2E -- '.'
  sw tUart tTmp 0

  -- Loop control
  addi tIter tIter 1
  blt tIter tMax loopL

  -- Done — print 'D' and JALR back to BRAM[0]
  addi tTmp x0 0x44 -- 'D'
  sw tUart tTmp 0
  jalr x0 x0 0

  -- Per-bank failure landings
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
  -- 'F' marker
  addi tTmp x0 0x46 -- 'F'
  sw tUart tTmp 0
  -- Dump expected (= what we wanted), actual (= tOld, what LR or LW returned)
  sw tUart tNew 0
  srli tTmp tNew 8
  sw tUart tTmp 0
  srli tTmp tNew 16
  sw tUart tTmp 0
  srli tTmp tNew 24
  sw tUart tTmp 0
  sw tUart tOld 0
  srli tTmp tOld 8
  sw tUart tTmp 0
  srli tTmp tOld 16
  sw tUart tTmp 0
  srli tTmp tOld 24
  sw tUart tTmp 0
  -- Halt
  failHaltL <- label
  j failHaltL
 where
  -- Register allocation
  tUart = x10
  tA = x11
  tB = x12
  tC = x13
  tD = x14
  tMax = x15
  tIter = x16
  tPat = x17
  tExpected = x18
  tNew = x19
  tOld = x20
  tSc = x21
  tTmp = x22

helloLrScStressInnerWords :: [BitVector 32]
helloLrScStressInnerWords =
  DE.fromRight
    (P.error "helloLrScStressInner failed to assemble")
    (assemble helloLrScStressInner)

-- * BRAM bootstrap ---------------------------------------------------

helloLrScStressFirmware :: Asm ()
helloLrScStressFirmware = do
  li bUart 0x10000000
  li bSdramBase 0x80000000

  -- 'B' — confirms BRAM exec + bus + UART are alive
  addi bTmp x0 0x42 -- 'B'
  sw bUart bTmp 0

  -- Stage the SDRAM-resident inner loop
  forM_ (zip [0 ..] helloLrScStressInnerWords) $ \(i, w) -> do
    li bEnc (bvToInt32 w)
    sw bSdramBase bEnc (toInteger (i P.* 4))

  -- Defensive prefetch fill
  let innerLen = P.length helloLrScStressInnerWords
      padTarget = 256 :: P.Int
      padCount = padTarget P.- innerLen
  P.mapM_
    ( \i -> do
        li bEnc encodedJalrToZero
        sw bSdramBase bEnc (toInteger ((innerLen P.+ i) P.* 4))
    )
    (P.take (P.max 0 padCount) [0 ..])

  -- Jump to SDRAM[0]
  jalr x0 bSdramBase 0

  -- Fallback halt
  haltL <- label
  j haltL
 where
  bUart = x10
  bSdramBase = x12
  bTmp = x13
  bEnc = x14

helloLrScStressFirmwareWords :: [BitVector 32]
helloLrScStressFirmwareWords =
  DE.fromRight
    (P.error "helloLrScStressFirmware failed to assemble")
    (assemble helloLrScStressFirmware)

-- * Helpers ----------------------------------------------------------

encodedJalrToZero :: Int32
encodedJalrToZero = 0x0000_0067

bvToInt32 :: BitVector 32 -> Int32
bvToInt32 = fromIntegral
