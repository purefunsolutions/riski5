-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : SocChainIntegrationSpec
Description : End-to-end whole-chain coverage for the new SDRAM + SRAM two-port architecture.

Per-controller two-port arbitration (tasks #21 + #22) gives the SoC
the same fetch-vs-data race-free behaviour for both off-chip RAMs.
This spec covers both chains end-to-end through 'socSimFullWith':

  * SDRAM chain (@enableSdramFetch=True@): @HelloSdramStress@
    runs an SDRAM-resident inner loop that writes-then-reads four
    different banks per iteration. While that loop runs, the IF
    stage is also fetching from SDRAM — the canonical fetch+data
    concurrent-access scenario the architectural fix targets.

  * SRAM chain (@enableSramFetch=True@): @HelloSramExec@ stages
    a small SRAM-resident loop and prints a deterministic byte
    pattern per iteration. While the loop runs, the IF stage and
    data port both touch SRAM.

Both tests hit the integration boundary the unit specs
('SdramTwoPortSpec' / 'SramTwoPortSpec') can't reach: the SoC's
JTAG-mux + bus decoder + core stall logic + the two-port adapter,
all driven by a real RV32I instruction stream. If the architectural
fix only worked under the unit-test harness's single-FSM input
shape, this spec catches the gap.
-}
module SocChainIntegrationSpec (
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
import HelloSdramStress (helloSdramStressFirmwareWords)
import HelloSramExec (helloSramExecFirmwareWords)
import Riski5.Soc (SocInFull (..), SocOutSim (..), socSimFullWith)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase)
import Prelude
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "SoC + two-port adapter integration (whole-chain)"
    [ testCase "SDRAM chain: HelloSdramStress writes-then-reads 4 banks per iter, no failure markers" case_sdramStressClean
    , testCase "SRAM chain: HelloSramExec emits 1 B + 1 S per iteration" case_sramExecClean
    ]

-- * Cases ------------------------------------------------------------

{- | HelloSdramStress runs a BRAM bootstrap that stages an inner
loop into SDRAM, then jumps to it. The inner loop:

  1. Writes a XOR-pattern value to four SDRAM banks.
  2. Reads back from each bank, branches to a per-bank failure
     handler on mismatch.
  3. Prints '.' on a clean iteration, increments iter, repeats up
     to 256 times. Prints 'D' on completion.

Failure shape: per-bank label 'A' / 'B' / 'C' / 'D' followed by
'F' and 8 bytes of expected/actual dump.

Architectural assertion: the captured byte stream contains __no__
failure markers. We don't require all 256 dots in the bounded
sim window — just that none of the cycles we observe land on a
failure.
-}
case_sdramStressClean :: Assertion
case_sdramStressClean = do
  let bytes :: [BitVector 8]
      bytes = runSocSdramStress 8000

      -- Failure-marker bytes the firmware emits on a bad bank read.
      isFailureByte :: BitVector 8 -> Bool
      isFailureByte b = b == 0x46 -- 'F' (the common-fail marker)

      failures = filter isFailureByte bytes
      bMarkers = length [() | b <- bytes, b == 0x42] -- 'B' bootstrap-alive
      dotCount = length [() | b <- bytes, b == 0x2E]
      msg =
        "Expected SDRAM-stress to print only B + ........ (no F failure marker). "
          P.++ "B-markers: "
          P.++ show bMarkers
          P.++ " dots: "
          P.++ show dotCount
          P.++ " failures (F bytes): "
          P.++ show (length failures)
          P.++ ". First 60 bytes: "
          P.++ show (take 60 bytes)
  assertBool ("must see at least one B (BRAM bootstrap alive) — got bytes prefix " P.++ show (take 30 bytes)) (bMarkers >= 1)
  assertBool msg (null failures)

{- | HelloSramExec stages a 2-instruction SRAM loop that writes 'S'
to the UART, then ebreak's back to BRAM. Each iteration emits
exactly 1 'B' (BRAM bootstrap) and 1 'S' (SRAM-resident write).

Architectural assertion: every observed iteration has exactly
1 B + 1 S. Same shape as 'SramExecSpec.case_oneSperBperIteration'
but proves the new two-port @sram@ doesn't regress the existing
1:1 contract that the SramExecSpec previously verified against
the SoC-side arbiter.
-}
case_sramExecClean :: Assertion
case_sramExecClean = do
  let bytes :: [BitVector 8]
      bytes = runSocSramExec 4000

      iters = sliceByB bytes
      complete = if length iters > 1 then take (length iters - 1) iters else iters
      bad = [it | it <- complete, fst it /= 1 || snd it /= 1]
      msg =
        "Expected 1 B + 1 S per iteration through the new two-port sram, got "
          P.++ show iters
          P.++ ". Bad iterations: "
          P.++ show bad
  assertBool msg (length complete > 0 && null bad)

-- * Slicing helper (shared with SramExecSpec) ------------------------

sliceByB :: [BitVector 8] -> [(Int, Int)]
sliceByB = goPre
 where
  goPre [] = []
  goPre (b : rest)
    | b == 0x42 = goIter (1 :: Int) (0 :: Int) rest
    | otherwise = goPre rest
  goIter !nB !nS [] = [(nB, nS)]
  goIter !nB !nS (b : rest)
    | b == 0x42 = (nB, nS) : goIter 1 0 rest
    | b == 0x53 = goIter nB (nS + 1) rest
    | otherwise = goIter nB nS rest

-- * Harnesses ------------------------------------------------------

{- | Run @HelloSdramStress@ with @enableSdramFetch=True@ — both core
ports want SDRAM (IF stage fetches the inner loop, data port
writes/reads). This is the silicon configuration we shipped as
the @riski5-core-sdramstress@ bitstream variant.
-}
runSocSdramStress :: Int -> [BitVector 8]
runSocSdramStress nCycles =
  let progVec :: Vec 4096 (BitVector 32)
      progVec = V.unsafeFromList (take 4096 (helloSdramStressFirmwareWords ++ P.repeat 0x0000_0013))

      dataVec :: Vec 1 (BitVector 32)
      dataVec = CP.repeat 0

      sramInit :: Vec 262144 (BitVector 16)
      sramInit = CP.repeat 0

      inputSig :: Signal System SocInFull
      inputSig =
        fromList (P.repeat SocInFull {sifSwitches = 0, sifKeys = 0xF})

      -- enableSramFetch=False, enableSdramFetch=True
      go :: (HiddenClockResetEnable System) => Signal System SocOutSim
      go = socSimFullWith False True progVec dataVec sramInit inputSig

      trace =
        sampleN @System nCycles $
          withClockResetEnable @System clockGen resetGen enableGen go
   in [b | SocOutSim {sosUartTx = Just b} <- trace]

{- | Run @HelloSramExec@ with @enableSramFetch=True@. Mirrors the
@riski5-core-sramexec@ bitstream variant.
-}
runSocSramExec :: Int -> [BitVector 8]
runSocSramExec nCycles =
  let progVec :: Vec 4096 (BitVector 32)
      progVec = V.unsafeFromList (take 4096 (helloSramExecFirmwareWords ++ P.repeat 0x0000_0013))

      dataVec :: Vec 1 (BitVector 32)
      dataVec = CP.repeat 0

      sramInit :: Vec 262144 (BitVector 16)
      sramInit = CP.repeat 0

      inputSig :: Signal System SocInFull
      inputSig =
        fromList (P.repeat SocInFull {sifSwitches = 0, sifKeys = 0xF})

      -- enableSramFetch=True, enableSdramFetch=False
      go :: (HiddenClockResetEnable System) => Signal System SocOutSim
      go = socSimFullWith True False progVec dataVec sramInit inputSig

      trace =
        sampleN @System nCycles $
          withClockResetEnable @System clockGen resetGen enableGen go
   in [b | SocOutSim {sosUartTx = Just b} <- trace]
