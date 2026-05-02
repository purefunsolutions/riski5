-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : HelloStackStress
Description : SDRAM stack push-pop stress — function prologue/epilogue + canary check.

Companion to 'HelloAmoStress' / 'HelloLrScStress'. Where those
firmwares clear AMO + LR/SC silicon for the Linux panic suspect
list, this firmware probes the third major suspect: SDRAM-resident
stack save / restore.

The kernel panic at PC=0x8002cd98 is in @task_work_add@ — vmlinux
disassembly shows the function prologue:

@
  addi sp, sp, -16
  sw   s0, 8(sp)
  sw   s1, 4(sp)
  sw   ra, 12(sp)
  addi s0, sp, 16     ; frame pointer
@

and the matching epilogue:

@
  lw   ra, 12(sp)
  lw   s0, 8(sp)
  lw   s1, 4(sp)
  addi sp, sp, 16
  ret
@

If any of those @sw@ / @lw@ pairs returns a different value than
was written — even at one specific stack-offset combination, even
under one specific concurrent fetch+data SDRAM bus pattern — the
returned register holds garbage, and on the next function-exit the
stack-canary @lw@ from a related stack slot also returns garbage,
producing the canary-mismatch panic we see.

== This firmware's per-iteration test

In the inner loop (running from SDRAM, with @sp@ pointing into a
different SDRAM bank):

  1. Load 4 unique known values into ra, s0, s1, t0.
  2. @addi sp, sp, -16@ — allocate frame.
  3. @sw ra, 12(sp); sw s0, 8(sp); sw s1, 4(sp); sw t0, 0(sp)@ —
     mirror task_work_add's multi-register save shape.
  4. Clobber ra / s0 / s1 / t0 with garbage (simulates body
     of the function doing other work).
  5. @lw ra, 12(sp); lw s0, 8(sp); lw s1, 4(sp); lw t0, 0(sp)@ —
     pop the saved values.
  6. @addi sp, sp, 16@ — deallocate.
  7. Verify each register equals its pre-push value. Any mismatch
     prints a register-label byte ('R' / 'S' / 'T' / 'U') + 'F'
     + a hex dump of expected/actual.

Per clean iteration: '.'. After @N@ clean: 'D' + return to BRAM.
Re-entry from BRAM[0] runs the test pass again indefinitely.

== Why fetch from SDRAM matters

The two-port SDRAM adapter arbitrates fetch + data internally.
Stack save/restore generates four back-to-back data-port writes
followed by four back-to-back data-port reads. Concurrent fetch
from SDRAM (the inner loop's instructions) means each data
transaction is racing against a fetch transaction. If the
arbitration has a corner case for multi-byte multi-register save
patterns specifically, this firmware will reproduce.

== Why a different SDRAM bank for the stack

Same reasoning as @HelloAmoStress@'s bank-switching: hitting a
different bank for stack ops vs. inner-loop fetch forces the
controller to ACTIVATE alternating banks, which exercises the
chip-side row-buffer flush + ACTIVATE-PRECHARGE path harder than
sequential same-bank accesses would.
-}
module HelloStackStress (
  helloStackStressFirmware,
  helloStackStressFirmwareWords,
  helloStackStressInner,
  helloStackStressInnerWords,
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

{- | Inner loop. Runs entirely from SDRAM bank 0
(@0x80000000+@). Stack lives in SDRAM bank 2 (@0x80400000+@) so
the controller ACTIVATEs alternating banks per access. Per
iteration: 4-register prologue/epilogue save+restore with
verify.
-}
helloStackStressInner :: Asm ()
helloStackStressInner = do
  -- UART
  li tUart 0x10000000
  -- Stack base (SDRAM bank 2, away from code in bank 0).
  -- Initialise sp NEAR the high end of the bank so addi sp, -16
  -- stays well inside SDRAM.
  li tSp 0x80500000

  -- Iteration max
  li tMax 64
  addi tIter x0 0

  -- Pattern base
  li tPat 0x77770000

  -- Pre-baked register-known values (refreshed each iteration).
  -- These are what we push, clobber, then verify after pop.
  -- Use distinct constants (XOR with iter) so a subtle "pop
  -- returns wrong slot's value" bug shows up as a register-vs-
  -- slot mismatch rather than just zero-vs-nonzero.

  failRL <- labelUnplaced
  failSL <- labelUnplaced
  failTL <- labelUnplaced
  failUL <- labelUnplaced
  failL <- labelUnplaced

  loopL <- label

  -- Per-iter register fill: ra=pat^iter, s0=pat^iter+1, s1=pat^iter+2,
  -- t0=pat^iter+3. xor for the iter mix; addi 1/2/3 for register-
  -- specific offsets so a slot-swap bug is detectable.
  xor_ tRaExp tPat tIter
  addi tS0Exp tRaExp 1
  addi tS1Exp tRaExp 2
  addi tT0Exp tRaExp 3

  -- Load the expected values into the actual ABI registers we'll
  -- save (ra=x1, s0=x8, s1=x9, t0=x5).
  addi x1 tRaExp 0
  addi x8 tS0Exp 0
  addi x9 tS1Exp 0
  addi x5 tT0Exp 0

  -- Prologue — exact shape of task_work_add at PC=0x8002ccf8:
  --   addi sp, sp, -16
  --   sw   s0, 8(sp)   -- task_work_add's 0x2ccfc
  --   sw   s1, 4(sp)   -- 0x2cd00
  --   sw   ra, 12(sp)  -- 0x2cd04
  -- Plus an extra t0 save at 0(sp) so we exercise 4 different
  -- offsets.
  addi tSp tSp (-16)
  sw tSp x8 8 -- mem[sp+8] = s0
  sw tSp x9 4 -- mem[sp+4] = s1
  sw tSp x1 12 -- mem[sp+12] = ra
  sw tSp x5 0 -- mem[sp+0] = t0

  -- Function body: clobber the saved regs to simulate work.
  addi x1 x0 0xDE
  addi x8 x0 0xAD
  addi x9 x0 0xBE
  addi x5 x0 0xEF

  -- Epilogue — exact shape of task_work_add at 0x8002cd24:
  --   lw   ra, 12(sp)
  --   lw   s0, 8(sp)
  --   lw   s1, 4(sp)
  --   addi sp, sp, 16
  -- Plus the t0 pop matching its push offset.
  lw x1 tSp 12
  lw x8 tSp 8
  lw x9 tSp 4
  lw x5 tSp 0
  addi tSp tSp 16

  -- Verify each register against its pre-push expected value.
  -- A mismatch on any single register tells us which stack slot
  -- got corrupted (or which register-vs-slot routing is wrong).
  bne x1 tRaExp failRL
  bne x8 tS0Exp failSL
  bne x9 tS1Exp failTL
  bne x5 tT0Exp failUL

  -- Print '.' on clean iteration
  addi tTmp x0 0x2E
  sw tUart tTmp 0

  -- Loop control
  addi tIter tIter 1
  blt tIter tMax loopL

  -- Done — print 'D' and JALR back to BRAM[0]
  addi tTmp x0 0x44 -- 'D'
  sw tUart tTmp 0
  jalr x0 x0 0

  -- Per-register failure landings: each prints its label letter
  -- ('R' for ra / 'S' for s0 / 'T' for s1 / 'U' for t0) then
  -- falls into the common dump.
  placeAt failRL
  addi tTmp x0 0x52 -- 'R' for ra
  sw tUart tTmp 0
  addi tActual x1 0
  addi tExpDump tRaExp 0
  j failL
  placeAt failSL
  addi tTmp x0 0x53 -- 'S' for s0
  sw tUart tTmp 0
  addi tActual x8 0
  addi tExpDump tS0Exp 0
  j failL
  placeAt failTL
  addi tTmp x0 0x54 -- 'T' for s1
  sw tUart tTmp 0
  addi tActual x9 0
  addi tExpDump tS1Exp 0
  j failL
  placeAt failUL
  addi tTmp x0 0x55 -- 'U' for t0
  sw tUart tTmp 0
  addi tActual x5 0
  addi tExpDump tT0Exp 0
  j failL

  placeAt failL
  -- 'F' marker
  addi tTmp x0 0x46
  sw tUart tTmp 0
  -- Dump expected then actual (4 bytes each, LE).
  sw tUart tExpDump 0
  srli tTmp tExpDump 8
  sw tUart tTmp 0
  srli tTmp tExpDump 16
  sw tUart tTmp 0
  srli tTmp tExpDump 24
  sw tUart tTmp 0
  sw tUart tActual 0
  srli tTmp tActual 8
  sw tUart tTmp 0
  srli tTmp tActual 16
  sw tUart tTmp 0
  srli tTmp tActual 24
  sw tUart tTmp 0
  -- Halt
  failHaltL <- label
  j failHaltL
 where
  -- Register allocation. ABI registers ra (x1), s0 (x8), s1 (x9),
  -- t0 (x5) are USED in the prologue/epilogue — they MUST be the
  -- standard ABI-named ones so the test mirrors compiler-generated
  -- code. Other locals use unused ABI registers.
  tUart = x10 -- a0
  tSp = x12 -- a2 (stand-in for sp; we don't touch real sp register)
  tMax = x13 -- a3
  tIter = x14 -- a4
  tPat = x15 -- a5
  tRaExp = x16 -- a6
  tS0Exp = x17 -- a7
  tS1Exp = x18 -- s2
  tT0Exp = x19 -- s3
  tTmp = x20 -- s4
  tActual = x21 -- s5
  tExpDump = x22 -- s6

helloStackStressInnerWords :: [BitVector 32]
helloStackStressInnerWords =
  DE.fromRight
    (P.error "helloStackStressInner failed to assemble")
    (assemble helloStackStressInner)

-- * BRAM bootstrap ---------------------------------------------------

helloStackStressFirmware :: Asm ()
helloStackStressFirmware = do
  li bUart 0x10000000
  li bSdramBase 0x80000000

  -- 'B' — confirms BRAM exec + bus + UART are alive
  addi bTmp x0 0x42
  sw bUart bTmp 0

  -- Stage the inner loop into SDRAM[0]
  forM_ (zip [0 ..] helloStackStressInnerWords) $ \(i, w) -> do
    li bEnc (bvToInt32 w)
    sw bSdramBase bEnc (toInteger (i P.* 4))

  -- Defensive prefetch fill
  let innerLen = P.length helloStackStressInnerWords
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

  haltL <- label
  j haltL
 where
  bUart = x10
  bSdramBase = x12
  bTmp = x13
  bEnc = x14

helloStackStressFirmwareWords :: [BitVector 32]
helloStackStressFirmwareWords =
  DE.fromRight
    (P.error "helloStackStressFirmware failed to assemble")
    (assemble helloStackStressFirmware)

-- * Helpers ----------------------------------------------------------

encodedJalrToZero :: Int32
encodedJalrToZero = 0x0000_0067

bvToInt32 :: BitVector 32 -> Int32
bvToInt32 = fromIntegral
