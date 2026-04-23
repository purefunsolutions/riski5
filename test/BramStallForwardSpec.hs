-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : BramStallForwardSpec
Description : BRAM-load-stall + RAW-forwarding integration coverage.

CoreMark's startup path hammers on a pattern the existing test
suite doesn't cover: a @.rodata@ load from the @SlaveBram@ address
range (which stalls for one cycle — see 'Riski5.Soc' @bramReadyS@)
immediately consumed by the next instruction. The RAW-through-
stall sequence is exactly where the phase-2B regfile swap broke
on silicon (see @docs/perf/phase-2b-attempt-2026-04-24.patch@)
while the existing 149 tests stayed green.

This module runs whole-SoC sim over 'Riski5.Soc.socSimAlteraUart'
firmware patterns that:

  1. LW a constant from the imem bus-read port (a @progInit@ word
     at a known offset) — exercises the 1-cycle 'bramReadyS' stall.
  2. Immediately consume the loaded register (EX/MEM forwarding
     into the next X-stage).
  3. Re-exercise it back-to-back — a small loop that reads, uses,
     writes the result to the UART FIFO.

The catalog asserts that the UART output matches a precomputed
expected stream. If the pipeline's stall-handling or forwarding
mis-feeds the loaded value, the output either diverges or (in the
worst case) the sim deadlocks waiting for UART bytes that never
land. 'sosUartTx' goes through 'jtagUartAlteraSim' so UART
back-pressure is realistic, not the infinite-FIFO default.

The payoff: if phase-2B's swap reintroduces the silicon bug, this
test — or a close variant — should fail __in cabal test__ rather
than silently pass the 149-test suite and only flare up on the DE2.
-}
module BramStallForwardSpec (
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
import Control.Monad (replicateM_)
import Riski5.Asm
import Riski5.ISA
import Riski5.Soc (SocInSim (..), SocOutSim (..), socSimAlteraUart)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, testCase)
import Prelude (Either (..), Int, Maybe (..), error, ($), (++))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "BRAM load-stall + forwarding"
    [ testCase "LW from SlaveBram → ADDI → SW to UART writes the right byte" case_simpleForward
    , testCase "4 back-to-back BRAM loads interleaved with UART writes stream correctly" case_loadBurst
    , testCase "csrr mcycle → ALU → SW: mcycle-read path makes it through the pipe" case_mcycleUart
    , testCase "BRAM-load → mcycle → UART: combined pattern mirroring CoreMark startup" case_bramMcycleUart
    ]

-- * Firmware layout ------------------------------------------------

-- | Where we park the 'dataBytes' so firmware can LW from them.
-- Code goes at 0, data at 0x100 (word 64), comfortably past the
-- code we emit.
dataOffsetWords :: Int
dataOffsetWords = 64

dataOffsetBytes :: CP.Signed 12
dataOffsetBytes = 0x100

-- | Four constants the firmware will LW and ferry to the UART.
dataBytes :: [CP.BitVector 8]
dataBytes = [0x41, 0x42, 0x43, 0x44] -- 'A', 'B', 'C', 'D'

-- | The full @progInit@ vector: assembled code, NOP pad, then the
-- four data words at 'dataOffsetWords'.
progVecOf :: [CP.BitVector 32] -> Vec 256 (CP.BitVector 32)
progVecOf codeWords =
  V.unsafeFromList (P.take 256 (layout ++ P.repeat 0x0000_0013))
 where
  layout =
    P.take dataOffsetWords (codeWords ++ P.repeat 0x0000_0013)
      ++ P.map (CP.zeroExtend :: CP.BitVector 8 -> CP.BitVector 32) dataBytes

-- * Assembly helpers -----------------------------------------------

assembleOrFail :: P.String -> Asm () -> [BitVector 32]
assembleOrFail nm prog = case assemble prog of
  Left err -> error (nm ++ " failed to assemble: " ++ P.show err)
  Right ws -> ws

-- * Firmware 1: single LW + ADDI + SW ------------------------------

{- | @t0 = mem[0x100]; t1 = t0 + 0; uart <- t1@. The ADDI between
the LW and the SW isn't strictly necessary — it's there because a
pipelined core's forwarding is slightly different for the
EX→X-after-stall shape vs the MEM→X shape (the LW sits in EX/MEM
for only the cycle after the stall clears). Verifying both at
once via a catalog of progressively longer LW→use distances lets
one broken path show up against the others.
-}
simpleForwardProg :: Asm ()
simpleForwardProg = do
  lui x10 0x10000 -- a0 = UART DATA = 0x1000_0000
  -- BRAM is addressed from 0; x11 = 0x100 (points at dataBytes[0]).
  addi x11 x0 dataOffsetBytes
  emit (Lw x12 x11 0) -- a2 = mem[0x100] = 0x41
  addi x13 x12 0 -- a3 = a2 (forward from EX/MEM through ADDI)
  emit (Sw x10 x13 0) -- UART <- 0x41
  spin <- label
  j spin

case_simpleForward :: Assertion
case_simpleForward = do
  let bytes = runSoc (assembleOrFail "simpleForwardProg" simpleForwardProg) 400
  assertEqual "single byte 'A' reaches the UART" [0x41] bytes

-- * Firmware 2: burst of LW + immediate SW -------------------------

{- | Loop unrolled: @mem[0x100]..mem[0x10C]@ → UART, one byte per
iteration. Each LW stalls one cycle, the immediate SW forwards
from EX/MEM. Exactly the .data-init pattern from CoreMark's
startup, minus the SRAM store (we go directly to UART to check
the load data end-to-end).
-}
loadBurstProg :: Asm ()
loadBurstProg = do
  lui x10 0x10000 -- a0 = UART DATA
  addi x11 x0 dataOffsetBytes -- a1 = 0x100 (data base)
  replicateM_ 4 $ do
    emit (Lw x12 x11 0) -- a2 = mem[a1]
    emit (Sw x10 x12 0) -- UART <- a2
    addi x11 x11 4 -- a1 += 4
  spin <- label
  j spin

case_loadBurst :: Assertion
case_loadBurst = do
  let bytes = runSoc (assembleOrFail "loadBurstProg" loadBurstProg) 600
  assertEqual "four constants arrive in order A, B, C, D" dataBytes bytes

-- * Firmware 3: mcycle CSR read + UART write -----------------------

{- | Mirrors the core of CoreMark's @read_mcycle_lo@ inline-asm
pattern: @csrr t0, mcycle@ then use the value. We don't care about
the actual cycle count — just that the CSR read fires, the
regfile write lands, and the subsequent instruction can forward
from it. The SW to UART writes a deterministic byte ('Z') that
depends only on the CSR value's low 5 bits being zeroed —
@andi tN, tN, 0@ forces that regardless of what mcycle was.
-}
mcycleProg :: Asm ()
mcycleProg = do
  lui x10 0x10000 -- a0 = UART DATA
  -- csrr t0, mcycle  → Csrrs rd=t0 rs1=x0 csr=0xB00
  emit (Csrrs x5 x0 (Csr 0xB00))
  -- and t1, t0, 0     → t1 = 0  (force the "character" deterministic)
  emit (Andi x6 x5 0)
  -- addi t1, t1, 'Z'
  addi x6 x6 (0x5A :: CP.Signed 12)
  emit (Sw x10 x6 0)
  spin <- label
  j spin

case_mcycleUart :: Assertion
case_mcycleUart = do
  let bytes = runSoc (assembleOrFail "mcycleProg" mcycleProg) 400
  assertEqual "one byte 'Z' arrives" [0x5A] bytes

-- * Firmware 4: BRAM load + mcycle read + UART ---------------------

{- | Composed of the three patterns that CoreMark's startup mixes:
a BRAM load from @.rodata@ (1-cycle stall), an mcycle CSR read,
and a UART write. RAW dependencies chain through the whole thing
so EX→X forwarding fires at every step. If any tier of the
forwarding fabric miscompiles this in sim, one of the asserted
bytes will come out wrong.
-}
bramMcycleProg :: Asm ()
bramMcycleProg = do
  lui x10 0x10000 -- a0 = UART
  addi x11 x0 dataOffsetBytes -- a1 = 0x100 (BRAM .rodata base)
  emit (Lw x12 x11 0) -- a2 = mem[0x100] = 'A'
  emit (Csrrs x5 x0 (Csr 0xB00)) -- t0 = mcycle
  emit (Andi x5 x5 0) -- t0 = 0
  emit (Sll x13 x12 x5) -- a3 = a2 << t0 = 'A' << 0 = 'A'
  emit (Sw x10 x13 0) -- UART <- 'A'
  -- Now a second burst: mcycle dependency on LW's shift
  emit (Csrrs x6 x0 (Csr 0xB00)) -- t1 = mcycle
  emit (Andi x6 x6 0) -- t1 = 0
  emit (Sll x14 x13 x6) -- a4 = a3 << t1 = 'A'
  emit (Sw x10 x14 0) -- UART <- 'A'
  spin <- label
  j spin

case_bramMcycleUart :: Assertion
case_bramMcycleUart = do
  let bytes = runSoc (assembleOrFail "bramMcycleProg" bramMcycleProg) 600
  assertEqual "two bytes 'A' arrive (BRAM→mcycle→UART twice)" [0x41, 0x41] bytes

-- * Harness --------------------------------------------------------

runSoc :: [BitVector 32] -> Int -> [CP.BitVector 8]
runSoc codeWords nCycles =
  let dataVec :: Vec 64 (BitVector 32)
      dataVec = CP.repeat 0
      inputSig =
        fromList (P.repeat SocInSim {sisSwitches = 0, sisKeys = 0xF, sisSramDqIn = 0})
      go ::
        (HiddenClockResetEnable System) =>
        Signal System SocOutSim
      go = socSimAlteraUart (progVecOf codeWords) dataVec inputSig
      trace =
        sampleN @System nCycles $
          withClockResetEnable @System clockGen resetGen enableGen go
   in [b | SocOutSim {sosUartTx = Just b} <- trace]
