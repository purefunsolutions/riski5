-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : SramTwoPortSpec
Description : Tests for the two-port 'Riski5.Sram.sram' (task #22).

Mirror of 'SdramTwoPortSpec' for the SRAM controller. The new
two-port @sram@ accepts the IF-stage fetch and the data port
directly, arbitrates internally, and routes responses back to the
correct port. Pins the same contract as the SDRAM two-port:

  * Single-port-style behaviour for fetch-only or data-only
    traffic.
  * Concurrent fetch + data → data wins (data priority on
    simultaneous arrival, same convention as the old SoC-level
    @sramOwnerS@ arbiter).
  * The smoking-gun regression: when a data load and a fetch
    address BOTH point at SRAM but at DIFFERENT cells, the data
    port's @rdata@ MUST come from its own @addr@, never from the
    fetch's @addr@.
  * Per-port @ready@ pulses route to the correct caller.

The SRAM FSM uses live (non-latched) bus signals across multi-
cycle states (e.g. SReadHiStall reads @wHi@ from the current
cycle's @halfIdxS@). The two-port wrapper latches addr / wdata /
be on the SIdle exit to keep them stable through the transaction
— if the wrapper drops the latch, this test fails the same way
the SoC-arbiter regression did.
-}
module SramTwoPortSpec (
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
import Riski5.MemMap (sramBase)
import Riski5.Sram (sram, sramChipSim)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, testCase)
import Prelude (Bool (..), Int, ($), (+), (-))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Sram (two-port)"
    [ testGroup
        "single-port equivalence (only one port active at a time)"
        [ testCase "fetch alone: 32-bit read returns the chip-side value" case_fetchOnly
        , testCase "data alone: SW then LW round-trips" case_dataOnly
        ]
    , testGroup
        "arbitration"
        [ testCase "concurrent fetch + data → data wins (data priority)" case_dataWinsOnConcurrent
        , testCase "fetch ready never pulses on data port" case_fetchReadyOnlyOnFetch
        , testCase "data ready never pulses on fetch port" case_dataReadyOnlyOnData
        ]
    , testGroup
        "smoking-gun regression (task #22)"
        [ testCase
            "data load returns its OWN addr's value — not the fetch port's"
            case_dataLoadSeesOwnAddr
        , testCase
            "back-to-back mixed fetch+data: each gets correct value"
            case_mixedStreamCorrectness
        ]
    ]

-- * Harness --------------------------------------------------------

-- | Drive the two-port 'sram' for @n@ cycles. Returns
-- @(fetchRdata, fetchReady, dataRdata, dataReady)@ traces.
runSram2 ::
  -- | sim-cycle count
  Int ->
  -- | fetch port: sel
  [Bool] ->
  -- | fetch port: addr (CPU byte addr)
  [BitVector 32] ->
  -- | data port: sel
  [Bool] ->
  -- | data port: addr (CPU byte addr)
  [BitVector 32] ->
  -- | data port: wdata
  [BitVector 32] ->
  -- | data port: be (= 0 for read)
  [BitVector 4] ->
  -- | initial chip-side memory contents (Vec of half-words)
  Vec 4096 (BitVector 16) ->
  ( [BitVector 32]
  , [Bool]
  , [BitVector 32]
  , [Bool]
  )
runSram2 n fSels fAddrs dSels dAddrs dWdatas dBes initial =
  let pad xs = xs P.++ P.repeat (P.last xs)
      fSelS = fromList (pad fSels)
      fAddrS = fromList (pad fAddrs)
      dSelS = fromList (pad dSels)
      dAddrS = fromList (pad dAddrs)
      dWdataS = fromList (pad dWdatas)
      dBeS = fromList (pad dBes)
      dRenS = fromList (P.repeat True)
      go ::
        (HiddenClockResetEnable System) =>
        ( Signal System (BitVector 32)
        , Signal System Bool
        , Signal System (BitVector 32)
        , Signal System Bool
        )
      go =
        let (fr, fy, dr, dy, pinsS) =
              sram fSelS fAddrS dSelS dAddrS dWdataS dBeS dRenS dqInS
            (dqInS, _storeS) = sramChipSim initial pinsS
         in (fr, fy, dr, dy)
      (frS, fyS, drS, dyS) =
        withClockResetEnable @System clockGen resetGen enableGen go
   in ( sampleN @System n frS
      , sampleN @System n fyS
      , sampleN @System n drS
      , sampleN @System n dyS
      )

-- | Pre-seed a small chip image with known values at SRAM
-- addresses 'sramBase + addr'. Values are 32-bit; each occupies
-- two consecutive 16-bit half-word indices.
makeMem :: [(Int, BitVector 32)] -> Vec 4096 (BitVector 16)
makeMem entries =
  P.foldr applyEntry (CP.repeat 0) entries
 where
  applyEntry :: (Int, BitVector 32) -> Vec 4096 (BitVector 16) -> Vec 4096 (BitVector 16)
  applyEntry (off, val) v =
    let halfIdx = off `P.div` 2
        loHalf = CP.slice CP.d15 CP.d0 val
        hiHalf = CP.slice CP.d31 CP.d16 val
     in CP.replace
          (P.fromIntegral (halfIdx + 1))
          hiHalf
          (CP.replace (P.fromIntegral halfIdx) loHalf v)

-- * Cases ----------------------------------------------------------

-- | Fetch alone: assert fetchSel for an address that has 0xCAFEBABE
-- pre-seeded; verify fetchRdata returns it on the ready cycle.
case_fetchOnly :: Assertion
case_fetchOnly = do
  let mem = makeMem [(0x100, 0xCAFEBABE)]
      -- Hold fetchSel for 8 cycles (read takes 3 cycles + DQ
      -- input register adds one cycle of latency).
      fSels = False : P.replicate 8 True
      fAddrs = sramBase : P.replicate 8 (sramBase + 0x100)
      dSels = P.replicate 9 False
      dAddrs = P.replicate 9 0
      dWdatas = P.replicate 9 0
      dBes = P.replicate 9 0
      (fr, fy, _, _) = runSram2 9 fSels fAddrs dSels dAddrs dWdatas dBes mem
      firstReady = P.length (P.takeWhile P.not fy)
  assertBool ("fetch ready pulse should occur within 8 cycles, fy=" P.++ P.show fy) (firstReady P.< 8)
  assertEqual
    "fetch rdata at the ready cycle equals the seeded value"
    0xCAFEBABE
    (fr P.!! firstReady)

-- | Data alone: SW 0xDEADBEEF then LW back. Verify dataRdata
-- returns it.
case_dataOnly :: Assertion
case_dataOnly = do
  let mem = CP.repeat 0
      -- Cycles: 0=reset, 1-4=SW (4 cycles for word write),
      -- 5-12=LW (multi-cycle read).
      fSels = P.replicate 13 False
      fAddrs = P.replicate 13 0
      dSels = False : P.replicate 12 True
      dAddrs = sramBase : P.replicate 12 sramBase
      dWdatas = 0 : P.replicate 4 0xDEADBEEF P.++ P.replicate 8 0
      dBes = 0 : P.replicate 4 0b1111 P.++ P.replicate 8 0
      (_, _, dr, dy) = runSram2 13 fSels fAddrs dSels dAddrs dWdatas dBes mem
      readyCycles = P.zip [0 ..] dy
      readPulses = P.filter (\(i, r) -> r P.&& i P.> 4) readyCycles
  case readPulses of
    [] -> assertBool "data read should produce a ready pulse" False
    ((idx, _) : _) ->
      assertEqual
        "data rdata at the read-ready cycle equals the written value"
        0xDEADBEEF
        (dr P.!! idx)

-- | Concurrent fetch + data: data has priority. Verify dataReady
-- fires BEFORE fetchReady when both are asserted from the same
-- cycle.
case_dataWinsOnConcurrent :: Assertion
case_dataWinsOnConcurrent = do
  let mem =
        makeMem
          [ (0x100, 0xAAAAAAAA)
          , (0x200, 0xBBBBBBBB)
          ]
      cycles = 16
      fSels = False : P.replicate (cycles - 1) True
      fAddrs = sramBase : P.replicate (cycles - 1) (sramBase + 0x100)
      dSels =
        False : P.replicate 5 True P.++ P.replicate (cycles - 6) False
      dAddrs = P.replicate cycles (sramBase + 0x200)
      dWdatas = P.replicate cycles 0
      dBes = P.replicate cycles 0
      (fr, fy, dr, dy) = runSram2 cycles fSels fAddrs dSels dAddrs dWdatas dBes mem
      firstFetchReady = P.length (P.takeWhile P.not fy)
      firstDataReady = P.length (P.takeWhile P.not dy)
  assertBool
    ( "data ready ("
        P.++ P.show firstDataReady
        P.++ ") should fire BEFORE fetch ready ("
        P.++ P.show firstFetchReady
        P.++ ") when both arrive simultaneously"
    )
    (firstDataReady P.< firstFetchReady)
  assertEqual
    "data rdata at first data-ready is data port's address value"
    0xBBBBBBBB
    (dr P.!! firstDataReady)
  assertBool
    ("fetch ready should also eventually fire, fy=" P.++ P.show fy)
    (firstFetchReady P.< 16)
  assertEqual
    "fetch rdata at first fetch-ready is fetch port's address value"
    0xAAAAAAAA
    (fr P.!! firstFetchReady)

-- | The fetch port's ready signal must NOT pulse when only the
-- data port has an active transaction.
case_fetchReadyOnlyOnFetch :: Assertion
case_fetchReadyOnlyOnFetch = do
  let mem = makeMem [(0x100, 0xDEADBEEF)]
      fSels = P.replicate 9 False
      fAddrs = P.replicate 9 0
      dSels = False : P.replicate 8 True
      dAddrs = sramBase : P.replicate 8 (sramBase + 0x100)
      dWdatas = P.replicate 9 0
      dBes = P.replicate 9 0
      (_, fy, _, _) = runSram2 9 fSels fAddrs dSels dAddrs dWdatas dBes mem
  assertBool
    ( "fetch ready must never pulse when fetchSel is False, fy="
        P.++ P.show fy
    )
    (P.not (P.or fy))

-- | Mirror image: data ready must NOT pulse when only fetch is
-- active.
case_dataReadyOnlyOnData :: Assertion
case_dataReadyOnlyOnData = do
  let mem = makeMem [(0x100, 0xDEADBEEF)]
      fSels = False : P.replicate 8 True
      fAddrs = sramBase : P.replicate 8 (sramBase + 0x100)
      dSels = P.replicate 9 False
      dAddrs = P.replicate 9 0
      dWdatas = P.replicate 9 0
      dBes = P.replicate 9 0
      (_, _, _, dy) = runSram2 9 fSels fAddrs dSels dAddrs dWdatas dBes mem
  assertBool
    ( "data ready must never pulse when dataSel is False, dy="
        P.++ P.show dy
    )
    (P.not (P.or dy))

-- | THE SMOKING GUN regression. Replicates the task #21 SDRAM
-- failure shape on SRAM: fetch port presents one address, data
-- port a different one, both have unique pre-seeded values. Data
-- port's rdata MUST come from its own dAddr.
case_dataLoadSeesOwnAddr :: Assertion
case_dataLoadSeesOwnAddr = do
  let fetchOff = 0x54
      dataOff = 0x800 -- 2 KB into chip — distinct page
      fetchVal = 0x00062983 -- the lw instruction (the SDRAM bug's signature)
      dataVal = 0x12340000
      mem =
        makeMem
          [ (fetchOff, fetchVal)
          , (P.fromIntegral dataOff, dataVal)
          ]
      cycles = 16
      fSels = False : P.replicate (cycles - 1) True
      fAddrs = sramBase : P.replicate (cycles - 1) (sramBase + P.fromIntegral fetchOff)
      dSels =
        False : P.replicate 5 True P.++ P.replicate (cycles - 6) False
      dAddrs = P.replicate cycles (sramBase + P.fromIntegral dataOff)
      dWdatas = P.replicate cycles 0
      dBes = P.replicate cycles 0
      (_fr, _fy, dr, dy) = runSram2 cycles fSels fAddrs dSels dAddrs dWdatas dBes mem
      firstDataReady = P.length (P.takeWhile P.not dy)
  assertBool
    ("data ready should fire within 16 cycles, dy=" P.++ P.show dy)
    (firstDataReady P.< cycles)
  let actual = dr P.!! firstDataReady
  assertEqual
    ( "data port read returned the FETCH port's chip-side value "
        P.++ "(if this fails the wrapper's address-latch logic is broken)"
    )
    dataVal
    actual

-- | Mixed back-to-back: stream of alternating fetch/data
-- transactions. Each port sees its own correct values.
case_mixedStreamCorrectness :: Assertion
case_mixedStreamCorrectness = do
  -- Hold fetch continuously. Pulse data twice in two well-separated
  -- windows. SRAM read takes 3 cycles; window of 4 cycles is enough
  -- for ONE read.
  let fetchVals = [(0x100, 0xF1F1F1F1), (0x104, 0xF2F2F2F2), (0x108, 0xF3F3F3F3), (0x10C, 0xF4F4F4F4)]
      dataVals = [(0x200, 0xD1D1D1D1), (0x204, 0xD2D2D2D2)]
      mem = makeMem (fetchVals P.++ dataVals)
      cycles = 40
      win1Start = 4
      win1End = 8
      win2Start = 16
      win2End = 20
      fSels = False : P.replicate (cycles - 1) True
      fAddrs = sramBase : P.replicate (cycles - 1) (sramBase + 0x100)
      dSels =
        P.replicate win1Start False
          P.++ P.replicate (win1End - win1Start) True
          P.++ P.replicate (win2Start - win1End) False
          P.++ P.replicate (win2End - win2Start) True
          P.++ P.replicate (cycles - win2End) False
      dAddrs =
        P.replicate win1Start sramBase
          P.++ P.replicate (win1End - win1Start) (sramBase + 0x200)
          P.++ P.replicate (win2Start - win1End) sramBase
          P.++ P.replicate (win2End - win2Start) (sramBase + 0x204)
          P.++ P.replicate (cycles - win2End) sramBase
      dWdatas = P.replicate cycles 0
      dBes = P.replicate cycles 0
      (_, _, dr, dy) = runSram2 cycles fSels fAddrs dSels dAddrs dWdatas dBes mem
      win1Pulses =
        P.map P.fst $
          P.filter (\(i, r) -> r P.&& i P.>= win1Start P.&& i P.< win2Start) (P.zip [0 ..] dy)
      win2Pulses =
        P.map P.fst $
          P.filter (\(i, r) -> r P.&& i P.>= win2Start P.&& i P.< cycles) (P.zip [0 ..] dy)
  assertBool
    ("expected at least 1 data-ready in window 1; pulses=" P.++ P.show win1Pulses)
    (P.not (P.null win1Pulses))
  assertBool
    ("expected at least 1 data-ready in window 2; pulses=" P.++ P.show win2Pulses)
    (P.not (P.null win2Pulses))
  let val1 = dr P.!! (P.head win1Pulses)
      val2 = dr P.!! (P.head win2Pulses)
  assertEqual "first data load returns 0xD1D1D1D1" 0xD1D1D1D1 val1
  assertEqual "second data load returns 0xD2D2D2D2" 0xD2D2D2D2 val2
