-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : JalrStackSpec
Description : JAL / JALR + stack push-pop pattern — the key CoreMark ↔ MemTest gap.

Observed silicon asymmetry: with phase-2B applied, the MemTest
bitstream runs end-to-end while the CoreMark bitstream hangs
before any UART byte. Key code-generation difference:

  * __MemTest__ is hand-written Asm. __Zero__ uses of JAL / JALR —
    all control flow is straight-line plus backward @j@ jumps.
    No stack push / pop.
  * __CoreMark__ is GCC-compiled C. Uses JAL + JALR heavily for
    function call / return, with the standard RISC-V calling
    convention pattern: push @ra@ to the stack at function
    entry, pop + JALR-to-ra at function exit. The stack lives
    at the top of SRAM (@sp = 0x2008_0000@), so every push /
    pop is a multi-cycle SRAM transaction.

Concrete hypothesis: the @lw ra, 0(sp)@ immediately before
@jalr x0, ra, 0@ — function epilogue's "pop ra, return" pair — has
a RAW dependency that must forward through the regfileSync's
read-first gap. If phase-2B's W-1→X (@wbHoldS@) or EX→X / MEM→X
forwarding tiers miss this specific window, @jalr@ reads a stale
@ra@ and jumps to the wrong address, effectively hanging the
firmware off in the weeds.

Test firmware mirrors the epilogue structure in the simplest
way that still exercises the pattern. All three tests run against
'Riski5.Soc.socSimFull' (full SoC + Altera UART + closed-loop
SRAM chip model) so the multi-cycle SRAM stall is realistic.
-}
module JalrStackSpec (
  tests,
) where

import Clash.Prelude (
  BitVector,
  HiddenClockResetEnable,
  Signal,
  System,
  Vec,
  clockGen,
  enableGen,
  fromList,
  resetGen,
  sampleN,
  withClockResetEnable,
 )
import Clash.Prelude qualified as CP
import Clash.Sized.Vector qualified as V
import Riski5.Asm
import Riski5.ISA
import Riski5.Soc (SocInFull (..), SocOutSim (..), socSimFull)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, testCase)
import Prelude (Either (..), Int, Maybe (..), error, ($), (++))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "JAL / JALR + stack (CoreMark epilogue pattern)"
    [ testCase "JAL forward, JALR back — 'A' + 'B' arrive" case_jalrSimple
    , testCase "JAL + stack push ra + pop ra + JALR-return — 'F'" case_stackCallOnce
    , testCase "two back-to-back calls with stack — 'FF'" case_stackCallTwice
    ]

-- * Layout ---------------------------------------------------------

-- | SRAM base (from MemMap.sramBase = 0x2000_0000). @lui sp, sramTop@
-- gives sp = SRAM top = 0x2008_0000.
sramTop :: P.Integer
sramTop = 0x20080

uartBase :: P.Integer
uartBase = 0x10000

progVecOf :: [CP.BitVector 32] -> Vec 512 (CP.BitVector 32)
progVecOf codeWords =
  V.unsafeFromList
    (P.take 512 (codeWords ++ P.repeat 0x0000_0013))

assembleOrFail :: P.String -> Asm () -> [BitVector 32]
assembleOrFail nm prog = case assemble prog of
  Left err -> error (nm ++ " failed to assemble: " ++ P.show err)
  Right ws -> ws

-- * Firmware 1: minimal JAL + JALR, no stack --------------------------

{- | Simplest call: @main@ writes 'A' to UART, calls a subroutine
that writes 'B' and returns via JALR, then @main@ halts. No stack
yet — tests just that JAL sets @ra@ correctly and JALR reads @ra@
correctly with the forwarded value.

Sequence:
  * lui a0, uart
  * addi a1, x0, 'A'
  * sw a0, a1         ; 'A' → UART
  * jal ra, sub       ; call: ra := pc+4
  * addi a2, x0, 'X'  ; marker after return — shouldn't run if JALR fails
  * sw a0, a2         ; 'X' → UART (means we got back here)
  * j halt

  sub:
  * addi a1, x0, 'B'
  * sw a0, a1         ; 'B' → UART
  * jalr x0, ra, 0    ; return
-}
jalrSimpleProg :: Asm ()
jalrSimpleProg = do
  lui x10 uartBase -- a0 = UART
  addi x11 x0 0x41 -- a1 = 'A'
  emit (Sw x10 x11 0) -- UART <- 'A'
  subLbl <- labelUnplaced
  jal x1 subLbl -- call sub (ra = pc+4)
  addi x11 x0 0x58 -- 'X' — marker after return
  emit (Sw x10 x11 0) -- UART <- 'X' if we're back
  haltLbl <- label
  j haltLbl
  placeAt subLbl
  addi x11 x0 0x42 -- 'B'
  emit (Sw x10 x11 0) -- UART <- 'B'
  jalr x0 x1 0 -- return

case_jalrSimple :: Assertion
case_jalrSimple = do
  let bytes = runSoc (assembleOrFail "jalrSimpleProg" jalrSimpleProg) 400
  assertEqual "A then B then X arrive in order" [0x41, 0x42, 0x58] bytes

-- * Firmware 2: JAL + stack push ra + pop + JALR-return ---------------

{- | Full function-call pattern:

@
main:
  lui sp, sramTop           ; sp = top of SRAM
  jal ra, foo                 ; call foo (ra := pc+4)
  addi a2, x0, 'K'            ; 'K' for "got back OK"
  sw a0, a2                   ; UART <- 'K'
  j halt

foo:
  addi sp, sp, -4             ; allocate frame
  sw sp, ra                   ; push ra to SRAM (MULTI-CYCLE STALL)
  addi a1, x0, 'F'            ; 'F' inside foo
  sw a0, a1                   ; UART <- 'F'
  lw ra, 0(sp)                ; pop ra from SRAM (MULTI-CYCLE STALL)
  addi sp, sp, 4              ; deallocate
  jalr x0, ra, 0              ; return — reads ra just loaded (THE pattern)
@

The last two instructions (@lw ra; jalr x0, ra, 0@) are exactly
CoreMark's function epilogue. With phase-2B's regfileSync +
multi-tier forwarding, @jalr@ must receive @ra@ forwarded from
either EX/MEM (lw's result) or the downstream pipe.
-}
stackCallOnceProg :: Asm ()
stackCallOnceProg = do
  lui x10 uartBase
  lui x2 sramTop -- sp = 0x2008_0000
  fooLbl <- labelUnplaced
  jal x1 fooLbl -- call foo
  addi x11 x0 0x4B -- 'K' — we got back
  emit (Sw x10 x11 0)
  haltLbl <- label
  j haltLbl
  placeAt fooLbl
  addi x2 x2 (-4) -- sp -= 4
  emit (Sw x2 x1 0) -- [sp] = ra
  addi x11 x0 0x46 -- 'F'
  emit (Sw x10 x11 0) -- UART <- 'F'
  emit (Lw x1 x2 0) -- ra = [sp]    ← KEY: lw into ra
  addi x2 x2 4 -- sp += 4
  jalr x0 x1 0 -- ret           ← KEY: jalr reads ra

case_stackCallOnce :: Assertion
case_stackCallOnce = do
  let bytes = runSoc (assembleOrFail "stackCallOnceProg" stackCallOnceProg) 800
  assertEqual "F from inside foo, then K after return" [0x46, 0x4B] bytes

-- * Firmware 3: two back-to-back function calls with stack -----------

{- | Same as 'stackCallOnceProg' but calls @foo@ twice, so the
sp / ra dance repeats and the 'F' byte arrives twice.

This catches regressions where the first call works but the
second sees a stale @ra@ or corrupt @sp@ because the forwarding /
wbHoldS state doesn't reset cleanly between calls.
-}
stackCallTwiceProg :: Asm ()
stackCallTwiceProg = do
  lui x10 uartBase
  lui x2 sramTop
  fooLbl <- labelUnplaced
  jal x1 fooLbl
  jal x1 fooLbl
  addi x11 x0 0x4B -- 'K' at the end
  emit (Sw x10 x11 0)
  haltLbl <- label
  j haltLbl
  placeAt fooLbl
  addi x2 x2 (-4)
  emit (Sw x2 x1 0)
  addi x11 x0 0x46 -- 'F'
  emit (Sw x10 x11 0)
  emit (Lw x1 x2 0)
  addi x2 x2 4
  jalr x0 x1 0

case_stackCallTwice :: Assertion
case_stackCallTwice = do
  let bytes = runSoc (assembleOrFail "stackCallTwiceProg" stackCallTwiceProg) 1200
  assertEqual "F twice, then K at the end" [0x46, 0x46, 0x4B] bytes

-- * Harness --------------------------------------------------------

runSoc :: [BitVector 32] -> Int -> [CP.BitVector 8]
runSoc codeWords nCycles =
  let dataVec :: Vec 64 (BitVector 32)
      dataVec = CP.repeat 0
      sramInit :: Vec 262144 (BitVector 16)
      sramInit = CP.repeat 0
      inputSig =
        fromList (P.repeat SocInFull {sifSwitches = 0, sifKeys = 0xF})
      go ::
        (HiddenClockResetEnable System) =>
        Signal System SocOutSim
      go = socSimFull (progVecOf codeWords) dataVec sramInit inputSig
      trace =
        sampleN @System nCycles $
          withClockResetEnable @System clockGen resetGen enableGen go
   in [b | SocOutSim {sosUartTx = Just b} <- trace]
