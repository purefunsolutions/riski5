-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : HelloAmoStress
Description : SDRAM AMO stress test — atomic ops + fetch contention.

Companion to 'HelloSdramStress'. Where that firmware proves the
SDRAM data path survives mixed read / write / fetch traffic, this
firmware proves the same for ATOMIC read-modify-write traffic
(@amoswap.w@ + @amoadd.w@). The AMO functional unit drives the
data port through Read → Write phases back-to-back against the
same address — a transaction shape neither @HelloSdramStress@ nor
the unit-level @SdramTwoPortSpec@ covers in isolation, and the
top suspect for the Linux stack-protector panic at PC=0x8002cd98
(both panic sites — @alloc_workqueue@ and CLINT/IRQ-domain init
— heavily use atomic refcounts).

== Layout (mirrors HelloSdramStress)

  * BRAM bootstrap stages a small SDRAM-resident loop into
    SDRAM @[0x80000000 .. 0x80000200)@, prints @B@ on the UART
    to confirm BRAM is alive, and JALRs to SDRAM[0].
  * The SDRAM-resident loop runs N iterations of a fixed
    @amoswap.w@ + verify pattern across 4 SDRAM banks (data
    area @0x80100000 / 0x80300000 / 0x80500000 / 0x80700000@),
    prints @.@ per clean iteration and a per-bank label
    (@A@ / @B@ / @C@ / @D@) followed by @F@ on the first
    mismatch.
  * On clean completion: prints @D@ and JALRs back to BRAM[0],
    where the firmware halts.

== What each iteration does

For each of 4 banks:

  1. @sw mem[bank], expected@ — pre-seed a known value.
  2. @amoswap.w rd, mem[bank], (expected + bankIdx)@ — atomic
     swap. RD must equal @expected@ (the pre-seed); MEM becomes
     @expected + bankIdx@.
  3. Verify rd via @bne rd, expected, failBank@.

Then verify-pass: read each bank back via plain @lw@ and check
the value equals @expected + bankIdx@.

== Failure shapes

  * @B......F...@ — first @F@ + the per-bank label tells which
    @amoswap.w@ misbehaved. The 8 trailing bytes dump expected /
    actual.
  * @B...F...@ in the verify-read phase points at "amoswap
    returned the right old value but the new value never
    actually committed to memory" — a different bug than
    failure during the amoswap itself.

== Why the same 4-bank pattern as HelloSdramStress

The IS42S16400 SDRAM chip has 4 banks. Hitting all 4 forces the
controller to ACTIVATE a different bank on every successive
access — the per-cycle bank-switching that exposed the original
arbiter race in task #21 also stresses the AMO FU's read-then-
write transition harder than 4 sequential ops to one bank
would.
-}
module HelloAmoStress (
  helloAmoStressFirmware,
  helloAmoStressFirmwareWords,
  helloAmoStressInner,
  helloAmoStressInnerWords,
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

{- | Inner loop. Runs entirely from SDRAM. Uses @amoswap.w@ across
4 SDRAM banks per iteration, verifies the returned old value AND
the post-swap memory value match the architectural contract, then
loops.
-}
helloAmoStressInner :: Asm ()
helloAmoStressInner = do
  -- UART
  li tUart 0x10000000
  -- 4 data bases — each in a different SDRAM bank (2 MB stride)
  li tA 0x80100000 -- bank 0, away from code at 0x80000000
  li tB 0x80300000 -- bank 1
  li tC 0x80500000 -- bank 2
  li tD 0x80700000 -- bank 3
  -- Iteration max — 64 is enough to surface a per-bank race
  -- without padding the firmware footprint into 2 KB.
  li tMax 64
  -- Iteration counter
  addi tIter x0 0
  -- Pattern base — high half stays constant, low half is the iter
  li tPat 0x42420000

  failAL <- labelUnplaced
  failBL <- labelUnplaced
  failCL <- labelUnplaced
  failDL <- labelUnplaced
  failL <- labelUnplaced

  loopL <- label

  -- Compute this iteration's expected old-value:
  --   tExpected = tPat XOR tIter
  xor_ tExpected tPat tIter

  -- Pre-seed all 4 banks with the same expected value.
  sw tA tExpected 0
  sw tB tExpected 0
  sw tC tExpected 0
  sw tD tExpected 0

  -- AMOSWAP each bank with a per-bank value
  -- (tExpected + 1 / +2 / +3 / +4) and verify that the FU returns
  -- the pre-seeded tExpected as the old value.
  addi tValue tExpected 1
  amoswap_w tRd tA tValue 0
  bne tRd tExpected failAL
  addi tValue tExpected 2
  amoswap_w tRd tB tValue 0
  bne tRd tExpected failBL
  addi tValue tExpected 3
  amoswap_w tRd tC tValue 0
  bne tRd tExpected failCL
  addi tValue tExpected 4
  amoswap_w tRd tD tValue 0
  bne tRd tExpected failDL

  -- Verify-read pass: each bank should now hold the post-swap
  -- value (tExpected + bankIdx). Any mismatch here means the AMO
  -- write didn't commit even though the AMO returned the right
  -- old value — a distinct failure mode.
  addi tValue tExpected 1
  lw tRd tA 0
  bne tRd tValue failAL
  addi tValue tExpected 2
  lw tRd tB 0
  bne tRd tValue failBL
  addi tValue tExpected 3
  lw tRd tC 0
  bne tRd tValue failCL
  addi tValue tExpected 4
  lw tRd tD 0
  bne tRd tValue failDL

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
  sw tUart tRd 0
  srli tTmp tRd 8
  sw tUart tTmp 0
  srli tTmp tRd 16
  sw tUart tTmp 0
  srli tTmp tRd 24
  sw tUart tTmp 0
  -- Halt
  failHaltL <- label
  j failHaltL
 where
  -- Register allocation (caller-saves; no calling convention).
  tUart = x10
  tA = x11
  tB = x12
  tC = x13
  tD = x14
  tMax = x15
  tIter = x16
  tPat = x17
  tExpected = x18
  tValue = x19
  tRd = x20
  tTmp = x21

helloAmoStressInnerWords :: [BitVector 32]
helloAmoStressInnerWords =
  DE.fromRight
    (P.error "helloAmoStressInner failed to assemble")
    (assemble helloAmoStressInner)

-- * BRAM bootstrap ---------------------------------------------------

{- | Full firmware as it lands in BRAM. Stages
'helloAmoStressInnerWords' into SDRAM and JALRs there. Mirrors
'HelloSdramStress.helloSdramStressFirmware' line-for-line — only
the inner loop differs.
-}
helloAmoStressFirmware :: Asm ()
helloAmoStressFirmware = do
  li bUart 0x10000000
  li bSdramBase 0x80000000

  -- 'B' — confirms BRAM exec + bus + UART are all alive.
  addi bTmp x0 0x42 -- 'B'
  sw bUart bTmp 0

  -- Stage the SDRAM-resident inner loop. For each 32-bit word in
  -- helloAmoStressInnerWords we emit `li bEnc <word>; sw
  -- bSdramBase bEnc <offset>` so the word lands at SDRAM[offset].
  forM_ (zip [0 ..] helloAmoStressInnerWords) $ \(i, w) -> do
    li bEnc (bvToInt32 w)
    sw bSdramBase bEnc (toInteger (i P.* 4))

  -- Defensive prefetch fill: pad the rest of the staged area
  -- with `jalr x0 x0 0` (= jump back to BRAM[0]) so any IF-stage
  -- prefetch leakage past the inner code's halt instructions
  -- lands on a clean redirect rather than executing whatever
  -- power-on noise lives in those SDRAM cells.
  let innerLen = P.length helloAmoStressInnerWords
      padTarget = 256 :: P.Int -- pad up to SDRAM[1024 bytes]
      padCount = padTarget P.- innerLen
  P.mapM_
    ( \i -> do
        li bEnc encodedJalrToZero
        sw bSdramBase bEnc (toInteger ((innerLen P.+ i) P.* 4))
    )
    (P.take (P.max 0 padCount) [0 ..])

  -- Jump to SDRAM[0]
  jalr x0 bSdramBase 0

  -- Re-entry from inner loop's JALR x0, x0, 0 lands back at
  -- BRAM[0]; runs another full pass. Visible UART signature is
  -- @B........[64 dots].........DB........[64 dots]........D...@.

  -- Fallback if the JALR somehow doesn't take.
  haltL <- label
  j haltL
 where
  bUart = x10
  bSdramBase = x12
  bTmp = x13
  bEnc = x14

helloAmoStressFirmwareWords :: [BitVector 32]
helloAmoStressFirmwareWords =
  DE.fromRight
    (P.error "helloAmoStressFirmware failed to assemble")
    (assemble helloAmoStressFirmware)

-- * Helpers ----------------------------------------------------------

-- | @jalr x0, x0, 0@ — PC := 0 + 0 = 0, no link.
encodedJalrToZero :: Int32
encodedJalrToZero = 0x0000_0067

-- | Unsigned BitVector 32 → signed Int32, preserving bit pattern.
bvToInt32 :: BitVector 32 -> Int32
bvToInt32 = fromIntegral
