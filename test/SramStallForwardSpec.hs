-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : SramStallForwardSpec
Description : BRAM-load → SRAM-store forwarding + multi-cycle-stall coverage.

Runs whole-SoC sim over 'Riski5.Soc.socSimFull' (which plumbs both
the Altera-IP-faithful UART __and__ a closed-loop 'sramChipSim'
for the off-chip SRAM) on firmware patterns that mirror CoreMark's
pre-@ee_printf@ startup path — the code that hung on silicon
under phase 2-B's regfile-swap attempt (see
@docs/perf/phase-2b-attempt-2026-04-24.patch@).

Coverage deltas over existing tests:

  * __SRAM multi-cycle stall__ — @sram@'s controller takes 3
    cycles for a @LW@ and 4 cycles for an @SW@. The pipeline
    stalls for the duration; any forwarding path that drifts
    during a multi-cycle freeze would corrupt the stalling
    instruction's operands.
  * __BRAM-load → SRAM-store chain__ — exactly CoreMark's
    @.data@-init pattern (@lw t0, 0(a0); sw t0, 0(a1); ...@): a
    1-cycle BRAM stall followed immediately by a multi-cycle
    SRAM stall with an RAW dependency through the forwarding
    muxes.
  * __BSS-zero-init loop + taken branches__ — exactly CoreMark's
    first real loop: @beq/sw/addi/j@, with @sw@ hitting SRAM.
-}
module SramStallForwardSpec (
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
import Riski5.Soc (SocInFull (..), SocOutSim (..), socSimFull)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, testCase)
import Prelude (Either (..), Int, Maybe (..), error, ($), (++))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "SRAM stall + forwarding (full SoC sim)"
    [ testCase "SW to SRAM → LW from SRAM → UART writes: multi-cycle stalls + forwarding" case_sramRoundtrip
    , testCase "BRAM-load → SRAM-store → UART: CoreMark .data-init pattern" case_dataInitPattern
    , testCase "BSS-zero-init loop: beq / sw-to-SRAM / addi / j" case_bssZeroInit
    ]

-- * Layout constants -----------------------------------------------

-- | SRAM base. Must match 'Riski5.MemMap.sramBase' = 0x2000_0000.
sramBase :: CP.BitVector 20
sramBase = 0x20000

-- | BRAM data area offset — we bake 'dataBytes' here so the
-- firmware can LW from address @dataOffsetBytes@.
dataOffsetWords :: Int
dataOffsetWords = 64

dataOffsetBytes :: CP.Signed 12
dataOffsetBytes = 0x100

-- | Four constants the firmware ferries through BRAM → SRAM → UART.
dataBytes :: [CP.BitVector 8]
dataBytes = [0x41, 0x42, 0x43, 0x44]

progVecOf :: [CP.BitVector 32] -> Vec 512 (CP.BitVector 32)
progVecOf codeWords =
  V.unsafeFromList (P.take 512 (layout ++ P.repeat 0x0000_0013))
 where
  layout =
    P.take dataOffsetWords (codeWords ++ P.repeat 0x0000_0013)
      ++ P.map (CP.zeroExtend :: CP.BitVector 8 -> CP.BitVector 32) dataBytes

assembleOrFail :: P.String -> Asm () -> [BitVector 32]
assembleOrFail nm prog = case assemble prog of
  Left err -> error (nm ++ " failed to assemble: " ++ P.show err)
  Right ws -> ws

-- * Firmware: SRAM SW then LW, ferry to UART -----------------------

{- | Basic SRAM round-trip: store a constant to SRAM, load it back,
write it to UART. Exercises both the SW multi-cycle stall and the
LW multi-cycle stall, with a RAW dependency on the load result
feeding UART.
-}
sramRoundtripProg :: Asm ()
sramRoundtripProg = do
  lui x10 0x10000 -- a0 = UART DATA
  lui x11 sramBase -- a1 = SRAM base = 0x2000_0000
  addi x12 x0 0x41 -- a2 = 'A'
  emit (Sw x11 x12 0) -- SRAM[0x2000_0000] = 'A'  (multi-cycle stall)
  emit (Lw x13 x11 0) -- a3 = SRAM[0x2000_0000]   (multi-cycle stall)
  emit (Sw x10 x13 0) -- UART <- a3               (single-cycle stall)
  spin <- label
  j spin

case_sramRoundtrip :: Assertion
case_sramRoundtrip = do
  -- SRAM ops are 3-4 cycles each, plus pipeline warm-up. 800 cycles
  -- gives plenty of headroom to finish before the asserted spin loop.
  let bytes = runSoc (assembleOrFail "sramRoundtripProg" sramRoundtripProg) 800
  assertEqual "the byte survived the SRAM round-trip" [0x41] bytes

-- * Firmware: BRAM-load → SRAM-store pattern (CoreMark .data init) --

{- | Exactly CoreMark's @.data@-init loop unrolled by 4: each
iteration reads one byte from BRAM (@.rodata@ at 0x100), stores it
to SRAM (0x2000_0000+), then (once all 4 bytes are stored) reads
them back and ships them to the UART. This puts the 1-cycle BRAM
stall and the multi-cycle SRAM stall back-to-back with an RAW
dependency through the forwarding mux.
-}
dataInitPatternProg :: Asm ()
dataInitPatternProg = do
  lui x10 0x10000 -- a0 = UART
  addi x11 x0 dataOffsetBytes -- a1 = BRAM data base = 0x100
  lui x12 sramBase -- a2 = SRAM base = 0x2000_0000
  -- Ferry 4 bytes: BRAM → SRAM
  replicateM_ 4 $ do
    emit (Lw x13 x11 0) -- a3 = BRAM[a1] (1-cycle stall)
    emit (Sw x12 x13 0) -- SRAM[a2] = a3 (multi-cycle stall, RAW on a3)
    addi x11 x11 4
    addi x12 x12 4
  -- Read back + UART write
  lui x12 sramBase -- reset a2 = SRAM base
  replicateM_ 4 $ do
    emit (Lw x13 x12 0) -- a3 = SRAM[a2] (multi-cycle stall)
    emit (Sw x10 x13 0) -- UART <- a3
    addi x12 x12 4
  spin <- label
  j spin

case_dataInitPattern :: Assertion
case_dataInitPattern = do
  -- Each BRAM LW: ~2 cycles. Each SRAM SW: ~4 cycles. Each SRAM LW:
  -- ~3 cycles. Each ADDI: 1 cycle. Total per byte per half ≈ 8
  -- cycles × 4 bytes × 2 halves ≈ 64 cycles. Plus pipeline warm-up +
  -- UART back-pressure. 2000 cycles is very safe.
  let bytes = runSoc (assembleOrFail "dataInitPatternProg" dataInitPatternProg) 2000
  assertEqual "all four bytes round-trip through SRAM" dataBytes bytes

-- * Firmware: BSS-zero-init loop -----------------------------------

{- | CoreMark's BSS-zero-init loop literally:

@
  addi a0, x0, sram_start
  addi a1, x0, sram_end
loop:
  beq a0, a1, done
  sw zero, 0(a0)         ; SRAM store, multi-cycle stall
  addi a0, a0, 4
  j loop
done:
  ...
@

Terminates after a small number of words, then writes a sentinel
byte to UART. If the stall / flush / forwarding path breaks under
the tight branch + SRAM-store pattern, the sentinel never arrives.
-}
bssZeroInitProg :: Asm ()
bssZeroInitProg = do
  lui x10 0x10000 -- a0 = UART
  addi x11 x0 0x41 -- a1 = 'A' sentinel
  -- Diagnostic: 'S' (0x53) before the loop to prove we got here.
  addi x14 x0 0x53
  emit (Sw x10 x14 0)
  bssDone <- labelUnplaced
  -- BSS base + end: SRAM[0 .. 16] (4 words).
  lui x12 sramBase -- a2 = SRAM[0]
  lui x13 sramBase
  addi x13 x13 16 -- a3 = SRAM[0] + 16 (4 words × 4 bytes)
  bssLoop <- label
  beq x12 x13 bssDone
  emit (Sw x12 x0 0) -- SRAM[a2] = 0 (multi-cycle stall)
  addi x12 x12 4
  j bssLoop
  placeAt bssDone
  -- Diagnostic: 'E' (0x45) after loop termination.
  addi x15 x0 0x45
  emit (Sw x10 x15 0)
  -- Final sentinel.
  emit (Sw x10 x11 0)
  spin <- label
  j spin

case_bssZeroInit :: Assertion
case_bssZeroInit = do
  -- 4 iterations × ~6 cycles (beq, sw=4-cycle-stall, addi, j) ≈ 24
  -- cycles inner loop. Plus warmup + branch-flush penalties. 2000
  -- is generous.
  let bytes = runSoc (assembleOrFail "bssZeroInitProg" bssZeroInitProg) 2000
  assertEqual "start / end / sentinel bytes arrive" [0x53, 0x45, 0x41] bytes

-- * Harness --------------------------------------------------------

runSoc :: [BitVector 32] -> Int -> [CP.BitVector 8]
runSoc codeWords nCycles =
  let dataVec :: Vec 64 (BitVector 32)
      dataVec = CP.repeat 0
      sramInit :: Vec 256 (BitVector 16)
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
