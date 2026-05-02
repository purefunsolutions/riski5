-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : HelloTrapStress
Description : Trap-during-stress — fire timer IRQ at high rate while
              running the stack-stress inner loop.

Companion to 'HelloStackStress' / 'HelloAmoStress' / 'HelloLrScStress'.
Where those firmwares ruled out the bare instruction patterns
(amoswap.w 848 k clean ops, lr.w/sc.w.rl 740 k clean ops, multi-reg
prologue/epilogue 1.1 M clean ops on silicon), this firmware probes
the next remaining suspect for the Linux panic at PC=0x8002cd98:
__a timer trap landing in the middle of a critical section__ — between
a @sw ra, 12(sp)@ and the next instruction that clobbers @ra@, or
between an @lr.w@ and its @sc.w.rl@.

If trap entry / exit corrupts a register the inner loop relies on, or
if the trap save/restore disturbs the SDRAM-resident stack frame, the
post-loop verifier will catch a register mismatch and print
@'F'@ + register-letter + dump.

== Trap-handler design

The handler must not perturb the inner-loop's live registers. Linux's
trap handler does this by saving everything to the kernel stack; our
handler uses the same trick at smaller scale via 'mscratch'. Standard
RISC-V M-mode pattern:

@
  csrrw t0, mscratch, t0      ; swap user t0 with handler scratch ptr
  sw    t1, 0(t0)             ; save t1, t2, t3 to SRAM scratch area
  sw    t2, 4(t0)
  sw    t3, 8(t0)
  ...                         ; re-arm mtimecmp using t1/t2/t3
  lw    t1, 0(t0)             ; restore
  lw    t2, 4(t0)
  lw    t3, 8(t0)
  csrrw t0, mscratch, t0      ; swap back
  mret
@

The scratch lives in SRAM (@0x2000_0000@), __not__ SDRAM, so the
trap-save path doesn't add SDRAM contention to the inner loop's
SDRAM contention. Only x5 (t0) / x6 (t1) / x7 (t2) / x28 (t3) are
touched — all unused by the inner loop's verifier registers
(x16..x22) and by all but x5 of the test ABI registers (x1=ra,
x8=s0, x9=s1, x5=t0 are live in the test; x5 is correctly
preserved by the mscratch swap).

== mtimecmp cadence

@mtimecmpIncrement = 256@ cycles ≈ 6.4 µs at 40 MHz. With the inner
loop running ~20 cycles per iteration, the IRQ lands roughly every
~13 iterations — high enough that some IRQs WILL land mid-prologue
and mid-epilogue across the 64-iteration test run.

== BRAM layout

@
  word 0..H1:        boot-head: minimal CSR setup (mtvec, mscratch)
                     + jalr to byte 0x100 (boot-tail). H1 ≤ 32.
  word H1..31:       NOP padding
  word 32..32+Hh:    trap handler. Hh ≈ 12.
  word 32+Hh..63:    NOP padding to byte 0x100
  word 64..N:        boot-tail: SDRAM stage + initial mtimecmp arm
                     + mie/mstatus enable + jalr to SDRAM[0]
@

The "no IRQs during boot" rule is enforced by deferring the
@mie.MTIE@ + @mstatus.MIE@ writes until the boot-tail's last
few instructions, immediately before JALR-ing to SDRAM. From
that point onward IRQs fire at @mtimecmpIncrement@ cadence
through the inner loop.
-}
module HelloTrapStress (
  helloTrapStressFirmware,
  helloTrapStressFirmwareWords,
  helloTrapStressInner,
  helloTrapStressInnerWords,
) where

import Clash.Prelude (BitVector)
import Control.Monad (forM_)
import Data.Either qualified as DE
import Data.Int (Int32)
import Riski5.Asm
import Riski5.ISA
import Prelude qualified as P
import Prelude (fromIntegral, toInteger, zip, ($))

-- | Cycles between successive timer IRQs. Smaller = IRQs land more
-- often, raising the chance one falls in the middle of a critical
-- save/restore sequence. 256 cycles ≈ 6.4 µs at 40 MHz.
mtimecmpIncrement :: P.Int
mtimecmpIncrement = 256

-- * SDRAM-resident inner loop -------------------------------------

{- | Inner loop. Identical pattern to 'HelloStackStress' (4-register
prologue/epilogue mirroring task_work_add) but runs WITH timer
IRQs firing every ~256 cycles. If the trap entry / exit path
corrupts the live registers (x1=ra, x5=t0, x8=s0, x9=s1) or the
SDRAM stack frame, the verifier prints 'F' + register-letter.
-}
helloTrapStressInner :: Asm ()
helloTrapStressInner = do
  -- UART
  li tUart 0x10000000
  -- Stack base — SDRAM bank 2, away from inner-loop code in bank 0.
  li tSp 0x80500000

  -- Iteration max — same scale as HelloStackStress so silicon log
  -- shapes are comparable side-by-side.
  li tMax 64
  addi tIter x0 0

  -- Pattern base
  li tPat 0x77770000

  failRL <- labelUnplaced
  failSL <- labelUnplaced
  failTL <- labelUnplaced
  failUL <- labelUnplaced
  failL <- labelUnplaced

  loopL <- label

  -- Per-iter expected values: ra=pat^iter, s0=+1, s1=+2, t0=+3.
  xor_ tRaExp tPat tIter
  addi tS0Exp tRaExp 1
  addi tS1Exp tRaExp 2
  addi tT0Exp tRaExp 3

  -- Load expected values into the actual ABI registers we save.
  -- task_work_add saves ra/s0/s1; we add t0 for an extra slot.
  addi x1 tRaExp 0
  addi x8 tS0Exp 0
  addi x9 tS1Exp 0
  addi x5 tT0Exp 0

  -- Prologue — task_work_add @ PC=0x8002ccf8 shape.
  addi tSp tSp (-16)
  sw tSp x8 8 -- mem[sp+8] = s0
  sw tSp x9 4 -- mem[sp+4] = s1
  sw tSp x1 12 -- mem[sp+12] = ra
  sw tSp x5 0 -- mem[sp+0] = t0

  -- Function body: clobber the saved regs (simulates work between
  -- prologue and epilogue). A trap landing here is benign — values
  -- are already in SDRAM. The dangerous spots are the prologue
  -- itself (between the four sw's) and the epilogue (between the
  -- four lw's), where the trap handler runs with partially-updated
  -- state.
  addi x1 x0 0xDE
  addi x8 x0 0xAD
  addi x9 x0 0xBE
  addi x5 x0 0xEF

  -- Epilogue — task_work_add @ PC=0x8002cd24 shape.
  lw x1 tSp 12
  lw x8 tSp 8
  lw x9 tSp 4
  lw x5 tSp 0
  addi tSp tSp 16

  -- Verify each register against its pre-push expected value.
  -- A trap-induced corruption shows here: either a saved value
  -- got the trap-handler's clobber, or the lw returned the wrong
  -- slot under arbitration with the trap-entry vector fetch.
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

  -- Per-register failure landings.
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
  addi tTmp x0 0x46 -- 'F'
  sw tUart tTmp 0
  -- Dump expected (4 bytes LE)
  sw tUart tExpDump 0
  srli tTmp tExpDump 8
  sw tUart tTmp 0
  srli tTmp tExpDump 16
  sw tUart tTmp 0
  srli tTmp tExpDump 24
  sw tUart tTmp 0
  -- Dump actual (4 bytes LE)
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
  -- Same allocation as HelloStackStress so the side-by-side
  -- silicon comparison is meaningful.
  tUart = x10
  tSp = x12
  tMax = x13
  tIter = x14
  tPat = x15
  tRaExp = x16
  tS0Exp = x17
  tS1Exp = x18
  tT0Exp = x19
  tTmp = x20
  tActual = x21
  tExpDump = x22

helloTrapStressInnerWords :: [BitVector 32]
helloTrapStressInnerWords =
  DE.fromRight
    (P.error "helloTrapStressInner failed to assemble")
    (assemble helloTrapStressInner)

-- * Boot-head (≤ 32 words) -----------------------------------------

-- | Boot-head: prints 'B', sets mtvec.base = 0x80 + mscratch =
-- SRAM scratch addr, then JALRs to byte 0x100 (boot-tail). Must
-- fit in 32 words; current size ~9 instructions.
helloTrapStressBootHead :: Asm ()
helloTrapStressBootHead = do
  li bUart 0x10000000
  addi bTmp x0 0x42 -- 'B'
  sw bUart bTmp 0

  -- mscratch := SRAM scratch addr (3 words at 0x2000_0000). The
  -- handler swaps t0 with mscratch on entry to grab a scratch ptr
  -- without clobbering user state.
  li bTmp 0x20000000
  csrrw x0 bTmp csrMscratch

  -- mtvec.base := 0x80 (word 32, MODE = 0 = direct).
  addi bTmp x0 0x80
  csrrw x0 bTmp csrMtvec

  -- Jump to boot-tail at byte 0x100 (word 64). Boot-tail handles
  -- SDRAM staging + IRQ enable + JALR to SDRAM[0].
  li bTmp 0x100
  jalr x0 bTmp 0
 where
  bUart = x10
  bTmp = x13

-- * Trap handler at word 32 (byte 0x80) -----------------------------

-- | Trap handler — uses mscratch swap to get a SRAM scratch ptr
-- without clobbering user state. Re-arms mtimecmp = mcycle +
-- @mtimecmpIncrement@ and mret's. Touches only x5 (via mscratch
-- swap), x6, x7, x28 — all preserved across the call.
--
-- Register usage:
--   x5 (t0) — swapped with mscratch on entry; restored on exit.
--   x6 (t1) — saved to scratch[0]; mtimecmp addr.
--   x7 (t2) — saved to scratch[1]; mcycle reading.
--   x28 (t3) — saved to scratch[2]; increment.
helloTrapStressHandler :: Asm ()
helloTrapStressHandler = do
  -- Swap user t0 with mscratch — t0 now holds SRAM scratch addr,
  -- mscratch holds caller's t0 value.
  csrrw x5 x5 csrMscratch

  -- Save the t-regs we'll clobber.
  sw x5 x6 0 -- scratch[0] = t1
  sw x5 x7 4 -- scratch[1] = t2
  sw x5 x28 8 -- scratch[2] = t3

  -- mtimecmp_new := mcycle + INC.
  li x6 0x02004000
  csrrs x7 x0 csrMcycle
  li x28 (P.fromIntegral mtimecmpIncrement)
  add x7 x7 x28
  sw x6 x7 0
  sw x6 x0 4

  -- Restore.
  lw x6 x5 0
  lw x7 x5 4
  lw x28 x5 8

  -- Swap back.
  csrrw x5 x5 csrMscratch

  -- mret restores PC from mepc and re-enables MIE from MPIE.
  mret

-- * Boot-tail (at byte 0x100 = word 64) -----------------------------

-- | Boot-tail: stages the inner loop into SDRAM, arms initial
-- mtimecmp, enables MTIE + MIE, then JALRs to SDRAM[0]. From the
-- JALR onwards, IRQs fire at @mtimecmpIncrement@ cadence.
helloTrapStressBootTail :: Asm ()
helloTrapStressBootTail = do
  li bUart 0x10000000
  li bSdramBase 0x80000000

  -- Stage inner loop into SDRAM[0].
  forM_ (zip [0 ..] helloTrapStressInnerWords) $ \(i, w) -> do
    li bEnc (bvToInt32 w)
    sw bSdramBase bEnc (toInteger (i P.* 4))

  -- Defensive prefetch fill (matches HelloStackStress).
  let innerLen = P.length helloTrapStressInnerWords
      padTarget = 256 :: P.Int
      padCount = padTarget P.- innerLen
  P.mapM_
    ( \i -> do
        li bEnc encodedJalrToZero
        sw bSdramBase bEnc (toInteger ((innerLen P.+ i) P.* 4))
    )
    (P.take (P.max 0 padCount) [0 ..])

  -- Arm initial mtimecmp = mcycle + INC.
  csrrs bTmp x0 csrMcycle
  li bIncReg (P.fromIntegral mtimecmpIncrement)
  add bTmp bTmp bIncReg
  li bMtcReg 0x02004000
  sw bMtcReg bTmp 0
  sw bMtcReg x0 4

  -- mie.MTIE := 1 (bit 7).
  addi bTmp x0 0x80
  csrrs x0 bTmp csrMie

  -- mstatus.MIE := 1 (bit 3).
  addi bTmp x0 0x8
  csrrs x0 bTmp csrMstatus

  -- Jump to SDRAM[0]. From here on, IRQs fire and the inner loop
  -- runs until 64 clean iterations or first 'F'.
  jalr x0 bSdramBase 0

  -- Halt loop in case of fall-through.
  haltL <- label
  j haltL
 where
  bUart = x10
  bSdramBase = x12
  bTmp = x13
  bEnc = x14
  bIncReg = x15
  bMtcReg = x16

-- * Wiring ---------------------------------------------------------

-- Layout: bootHead (≤ 32 words) → NOP pad to word 32 → handler →
-- NOP pad to word 64 → bootTail.
--
-- Both 32 and 64 are hard limits enforced at assemble time. If
-- bootHead grows past 32 words OR handler+32 grows past 64, this
-- module errors out at compile time.

helloTrapStressFirmware :: Asm ()
helloTrapStressFirmware = helloTrapStressBootHead

helloTrapStressFirmwareWords :: [BitVector 32]
helloTrapStressFirmwareWords =
  let bootHeadBytes = case assemble helloTrapStressBootHead of
        DE.Left err -> P.error ("HelloTrapStress bootHead: " P.++ P.show err)
        DE.Right ws -> ws
      handlerBytes = case assemble helloTrapStressHandler of
        DE.Left err -> P.error ("HelloTrapStress handler: " P.++ P.show err)
        DE.Right ws -> ws
      bootTailBytes = case assemble helloTrapStressBootTail of
        DE.Left err -> P.error ("HelloTrapStress bootTail: " P.++ P.show err)
        DE.Right ws -> ws

      headLen = P.length bootHeadBytes
      handlerLen = P.length handlerBytes
      tailLen = P.length bootTailBytes

      gapHead = 32 P.- headLen
      gapHandler = (64 P.- 32) P.- handlerLen
   in if gapHead P.< 0
        then
          P.error
            ( "HelloTrapStress: bootHead grew past word 32 (have "
                P.++ P.show headLen
                P.++ " words); trim or relocate handler"
            )
        else
          if gapHandler P.< 0
            then
              P.error
                ( "HelloTrapStress: handler grew past word 64 (have "
                    P.++ P.show handlerLen
                    P.++ " words after word 32); raise bootTail offset"
                )
            else
              bootHeadBytes
                P.++ P.replicate gapHead 0x0000_0013 -- pad to word 32
                P.++ handlerBytes
                P.++ P.replicate gapHandler 0x0000_0013 -- pad to word 64
                P.++ bootTailBytes
                P.++ ([0x0000_0013 | _ <- [tailLen P.+ 64 .. 4095]]) -- NOP-pad rest of BRAM

-- * Helpers ----------------------------------------------------------

encodedJalrToZero :: Int32
encodedJalrToZero = 0x0000_0067

bvToInt32 :: BitVector 32 -> Int32
bvToInt32 = fromIntegral
