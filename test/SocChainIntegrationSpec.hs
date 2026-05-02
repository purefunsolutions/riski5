-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RecordWildCards #-}
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
import Riski5.JtagUart (jtagUartAlteraSim)
import Riski5.Sdram (SdramIpBus (..), SdramIpReply (..), sdramIpSim)
import Riski5.Soc (
  SocIn (..),
  SocInFull (..),
  SocOut (..),
  SocOutSim (..),
  soc,
  socSimFullWith,
 )
import Riski5.Sram (sramChipSim)
import Riski5.AvalonMm (AvalonMmBus (..))
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
  let (bytes, busTrace, replyTrace, coreTrace) = runSocSdramStressDebugFull 8000

      isFailureByte :: BitVector 8 -> Bool
      isFailureByte b = b == 0x46 -- 'F' (the common-fail marker)

      failures = filter isFailureByte bytes
      bMarkers = length [() | b <- bytes, b == 0x42]
      dotCount = length [() | b <- bytes, b == 0x2E]
      -- Filter SDRAM bus to active cycles only (sibCs=True).
      activeBus = filter (\(_, b) -> sibCs b) (P.zip [(0 :: Int) ..] busTrace)
      writes = filter (\(_, b) -> sibWr b) activeBus
      reads = filter (\(_, b) -> sibRd b) activeBus
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
          P.++ "\nTotal SDRAM writes: "
          P.++ show (length writes)
          P.++ ", total reads: "
          P.++ show (length reads)
          P.++ "\nWrites with chip-addr > 0x100 (= bank-spread): "
          P.++ show (take 30 [(c, sibAddr b, sibWdata b) | (c, b) <- writes, sibAddr b > 0x100])
          P.++ "\nReads with chip-addr > 0x100: "
          P.++ show (take 30 [(c, sibAddr b) | (c, b) <- reads, sibAddr b > 0x100])
          P.++ "\nWrites count breakdown: addr<0x100: "
          P.++ show (length [c | (c, b) <- writes, sibAddr b < 0x100])
          P.++ ", addr>=0x100: "
          P.++ show (length [c | (c, b) <- writes, sibAddr b >= 0x100])
          P.++ "\nAll bus activity cy 500-530: "
          P.++ show (take 31 (drop 500 [(c, sibCs b, if sibWr b then 'W' else if sibRd b then 'R' else '.', sibAddr b) | (c, b) <- P.zip [(0 :: Int) ..] busTrace]))
          P.++ "\nIP reply cy 500-530: "
          P.++ show (take 31 (drop 500 (P.zip [(0 :: Int) ..] replyTrace)))
          P.++ "\nCore-side data port (sdramRdata, sdramDataReady) cy 500-530: "
          P.++ show (take 31 (drop 500 (P.zip [(0 :: Int) ..] coreTrace)))
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

We can't reuse @socSimFullWith@'s 32 KB sim SDRAM here because
the firmware spreads its 4 banks across an 8 MB chip-side window
(@0x80100000@ / @0x80300000@ / @0x80500000@ / @0x80700000@ +
inner-loop code at @0x80000000@). 32 KB wraps under @mod@ in
@sdramIpSim@ and aliases the data writes onto the code region —
the firmware overwrites itself in sim, indistinguishable from a
real arbitration race. Use a fresh inline harness with a larger
@simMem@ Vec sized to span the firmware's address footprint.
-}
runSocSdramStressDebug :: Int -> ([BitVector 8], [SdramIpBus])
runSocSdramStressDebug nCycles =
  let (txS, busS) = runSocSdramStressTraces
      bytesAll = sampleN @System nCycles txS
      busAll = sampleN @System nCycles busS
   in ([b | Just b <- bytesAll], busAll)

runSocSdramStressTraces ::
  ( Signal System (Maybe (BitVector 8))
  , Signal System SdramIpBus
  )
runSocSdramStressTraces = withClockResetEnable @System clockGen resetGen enableGen go
 where
  progVec :: Vec 4096 (BitVector 32)
  progVec = V.unsafeFromList (take 4096 (helloSdramStressFirmwareWords ++ P.repeat 0x0000_0013))
  dataVec :: Vec 1 (BitVector 32)
  dataVec = CP.repeat 0
  sramInit :: Vec 262144 (BitVector 16)
  sramInit = CP.repeat 0
  inputSig :: Signal System SocInFull
  inputSig = fromList (P.repeat SocInFull {sifSwitches = 0, sifKeys = 0xF})
  go :: (HiddenClockResetEnable System) => (Signal System (Maybe (BitVector 8)), Signal System SdramIpBus)
  go =
    let outSimS = socSimFullWithLargeSdram False True progVec dataVec sramInit inputSig
        txS = sosUartTx <$> outSimS
        busS = soSdramBus . sosOut <$> outSimS
     in (txS, busS)

-- | Combined debug trace: bytes, SDRAM bus, and the IP reply signal
-- the wrapper sees. Useful for seeing whether the IP returns the
-- right rdata that the wrapper then maps to dataRdata.
runSocSdramStressDebugFull ::
  Int ->
  ( [BitVector 8]
  , [SdramIpBus]
  , [(BitVector 16, Bool)]
  -- ^ (sirRdata, sirValid) per cycle from the IP
  , [(BitVector 32, Bool)]
  -- ^ (soDbgSdramRdata, soDbgSdramDataReady) per cycle — what the
  -- core's data port sees from the SoC's data ready chain.
  )
runSocSdramStressDebugFull nCycles = withClockResetEnable @System clockGen resetGen enableGen go
 where
  progVec :: Vec 4096 (BitVector 32)
  progVec = V.unsafeFromList (take 4096 (helloSdramStressFirmwareWords ++ P.repeat 0x0000_0013))
  dataVec :: Vec 1 (BitVector 32)
  dataVec = CP.repeat 0
  sramInit :: Vec 262144 (BitVector 16)
  sramInit = CP.repeat 0
  inputSig :: Signal System SocInFull
  inputSig = fromList (P.repeat SocInFull {sifSwitches = 0, sifKeys = 0xF})
  go ::
    (HiddenClockResetEnable System) =>
    ([BitVector 8], [SdramIpBus], [(BitVector 16, Bool)], [(BitVector 32, Bool)])
  go =
    let -- Reproduce the inline harness here so we can tap sdramReplyS.
        fullInS =
          ( \SocInFull {..} dq ur urRdy sdr ->
              SocIn
                { siSwitches = sifSwitches
                , siKeys = sifKeys
                , siSramDqIn = dq
                , siUartRdata = ur
                , siUartReady = urRdy
                , siUartIrq = False
                , siSdramReply = sdr
                , siCaptureReset = False
                , siCaptureOffset = 0
                , siJtagLoadMode = False
                , siJtagLoadAddr = 0
                , siJtagLoadWdata = 0
                , siJtagLoadWe = False
                , siJtagLoadRd = False
                , siJtagLoadBe = 0
                }
          )
            <$> inputSig
            <*> sramDqInS
            <*> uartRdataS
            <*> uartReadyS
            <*> sdramReplyS
        outS = soc False True progVec dataVec fullInS
        sramPinsS = soSramPins <$> outS
        (sramDqInS, _) = sramChipSim sramInit sramPinsS
        uartBusS = soUartBus <$> outS
        (uartRdataS, uartTxS, uartReadyS) =
          jtagUartAlteraSim
            (ambSel <$> uartBusS)
            (ambAddr <$> uartBusS)
            (ambWdata <$> uartBusS)
            (ambBe <$> uartBusS)
            (ambRe <$> uartBusS)
        sdramBusS = soSdramBus <$> outS
        sdramReplyS = sdramIpSim simMem sdramBusS
        simMem :: Vec 4194304 (BitVector 16)
        simMem = CP.repeat 0
        -- Sample rdata + valid from the IP reply.
        replyTrace = (\r -> (sirRdata r, sirValid r)) <$> sdramReplyS
        coreTrace = (\o -> (soDbgSdramRdata o, soDbgSdramDataReady o)) <$> outS
        bytes = [b | Just b <- sampleN @System nCycles uartTxS]
     in ( bytes
        , sampleN @System nCycles sdramBusS
        , sampleN @System nCycles replyTrace
        , sampleN @System nCycles coreTrace
        )

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
      go = socSimFullWithLargeSdram False True progVec dataVec sramInit inputSig

      trace =
        sampleN @System nCycles $
          withClockResetEnable @System clockGen resetGen enableGen go
   in [b | SocOutSim {sosUartTx = Just b} <- trace]

{- | Variant of 'socSimFullWith' with a 4 M half-word (8 MB)
@simMem@ Vec. Needed by the SDRAM-stress integration test
because the firmware's 4-bank stress pattern spans 8 MB of
chip-side address space (well beyond the 32 KB the standard
'socSimFullWith' provides).

Inlined here rather than parameterising 'socSimFullWith' on the
sdram memory size — the 8 MB Vec is huge in simulation
register-count terms and we don't want it on every test that
uses 'socSimFullWith' (most touch tiny corners of SDRAM).
-}
socSimFullWithLargeSdram ::
  forall dom p d n.
  ( HiddenClockResetEnable dom
  , CP.KnownNat p
  , 1 CP.<= p
  , CP.KnownNat d
  , 1 CP.<= d
  , CP.KnownNat n
  , 1 CP.<= n
  ) =>
  Bool ->
  Bool ->
  Vec p (BitVector 32) ->
  Vec d (BitVector 32) ->
  Vec n (BitVector 16) ->
  Signal dom SocInFull ->
  Signal dom SocOutSim
socSimFullWithLargeSdram enableSramFetch enableSdramFetch progInit dataInit sramInit inFullS = outSimS
 where
  fullInS =
    ( \SocInFull {..} dq ur urRdy sdr ->
        SocIn
          { siSwitches = sifSwitches
          , siKeys = sifKeys
          , siSramDqIn = dq
          , siUartRdata = ur
          , siUartReady = urRdy
          , siUartIrq = False
          , siSdramReply = sdr
          , siCaptureReset = False
          , siCaptureOffset = 0
          , siJtagLoadMode = False
          , siJtagLoadAddr = 0
          , siJtagLoadWdata = 0
          , siJtagLoadWe = False
          , siJtagLoadRd = False
          , siJtagLoadBe = 0
          }
    )
      <$> inFullS
      <*> sramDqInS
      <*> uartRdataS
      <*> uartReadyS
      <*> sdramReplyS
  outS = soc enableSramFetch enableSdramFetch progInit dataInit fullInS

  sramPinsS = soSramPins <$> outS
  (sramDqInS, _sramStoreS) = sramChipSim sramInit sramPinsS

  uartBusS = soUartBus <$> outS
  (uartRdataS, uartTxS, uartReadyS) =
    jtagUartAlteraSim
      (ambSel <$> uartBusS)
      (ambAddr <$> uartBusS)
      (ambWdata <$> uartBusS)
      (ambBe <$> uartBusS)
      (ambRe <$> uartBusS)

  sdramBusS = soSdramBus <$> outS
  sdramReplyS = sdramIpSim simMem sdramBusS
  -- 4 M half-words = 8 MB — full DE2 SDRAM footprint. Big in
  -- register count, but only this single integration test uses it.
  simMem :: Vec 4194304 (BitVector 16)
  simMem = CP.repeat 0

  outSimS = (\o t -> SocOutSim {sosOut = o, sosUartTx = t}) <$> outS <*> uartTxS

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
