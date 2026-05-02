-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : SdramTwoPortSpec
Description : Tests for the two-port 'Riski5.Sdram.sdram' (task #21).

The new two-port adapter accepts the IF-stage fetch and the data
port directly, arbitrates internally, and routes responses back
to the correct port. This spec pins the contract per the task #21
analysis:

  * Single-port-style behaviour for fetch-only or data-only
    traffic — the new design must remain a no-op vs the old
    single-port spec when only one port is active.
  * Concurrent fetch + data → data wins (data priority on
    simultaneous arrival, same convention as the old
    'nextSramOwner' arbiter).
  * The smoking-gun regression: when a data load and a fetch
    address BOTH point at SDRAM but at DIFFERENT cells, the data
    port's @rdata@ MUST come from its own @addr@, never from the
    fetch's @addr@. The old SoC-side @sdramOwnerS@ arbiter could
    leak the fetch's chip-side rdata onto the data port — that
    silicon failure is what motivated the refactor (task #19
    capture: load from 0x80100000 returned 0x00062983 = the @lw@
    instruction word at PC=0x80000054, the IF stage's prefetched
    address).
  * Per-port @ready@ pulses route to the correct caller — fetch
    completion never makes the data port think its load
    finished (and vice versa).
-}
module SdramTwoPortSpec (
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
import Riski5.MemMap (sdramBase)
import Riski5.Sdram (sdram, sdramIpSim)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, testCase)
import Prelude (Bool (..), Int, ($), (+), (-))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Sdram (two-port)"
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
        "smoking-gun regression (task #21)"
        [ testCase
            "data load returns its OWN addr's value — not the fetch port's"
            case_dataLoadSeesOwnAddr
        , testCase
            "back-to-back mixed fetch+data: each gets correct value"
            case_mixedStreamCorrectness
        ]
    ]

-- * Harness --------------------------------------------------------

-- | Drive the two-port 'sdram' for @n@ cycles. Returns
-- @(fetchRdata, fetchReady, dataRdata, dataReady)@ traces.
runSdram2 ::
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
  Vec 16384 (BitVector 16) ->
  ( [BitVector 32]
  , [Bool]
  , [BitVector 32]
  , [Bool]
  )
runSdram2 n fSels fAddrs dSels dAddrs dWdatas dBes initial =
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
        let (fr, fy, dr, dy, busS) =
              sdram fSelS fAddrS dSelS dAddrS dWdataS dBeS dRenS replyS
            replyS = sdramIpSim initial busS
         in (fr, fy, dr, dy)
      (frS, fyS, drS, dyS) =
        withClockResetEnable @System clockGen resetGen enableGen go
   in ( sampleN @System n frS
      , sampleN @System n fyS
      , sampleN @System n drS
      , sampleN @System n dyS
      )

-- | Pre-seed a small chip image with known values at SDRAM
-- addresses 'sdramBase + addr'. Values are 32-bit; each occupies
-- two consecutive 16-bit half-word indices.
makeMem :: [(Int, BitVector 32)] -> Vec 16384 (BitVector 16)
makeMem entries =
  -- Fold over entries, replacing consecutive halfword indices.
  P.foldr applyEntry (CP.repeat 0) entries
 where
  applyEntry :: (Int, BitVector 32) -> Vec 16384 (BitVector 16) -> Vec 16384 (BitVector 16)
  applyEntry (off, val) v =
    let halfIdx = off `P.div` 2 -- byte offset → half-word index
        loHalf = CP.resize @16 (CP.unpack (CP.pack (val CP..&. 0xFFFF)))
        hiHalf = CP.resize @16 (CP.unpack (CP.pack ((val `CP.shiftR` 16) CP..&. 0xFFFF)))
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
      -- 5 cycles: idle, then assert fetchSel for an address.
      -- Hold for 12 cycles; ready will pulse on completion (5-7
      -- cycles for a single 32-bit read with sim-model latency).
      fSels = False : P.replicate 12 True
      fAddrs = sdramBase : P.replicate 12 (sdramBase + 0x100)
      dSels = P.replicate 13 False
      dAddrs = P.replicate 13 0
      dWdatas = P.replicate 13 0
      dBes = P.replicate 13 0
      (fr, fy, _, _) = runSdram2 13 fSels fAddrs dSels dAddrs dWdatas dBes mem
      -- Find first cycle where fetchReady pulses.
      firstReady = P.length (P.takeWhile P.not fy)
  assertBool ("fetch ready pulse should occur within 12 cycles, fy=" P.++ P.show fy) (firstReady P.< 12)
  assertEqual
    "fetch rdata at the ready cycle equals the seeded value"
    0xCAFEBABE
    (fr P.!! firstReady)

-- | Data alone: SW 0xDEADBEEF then LW back. Verify dataRdata
-- returns it. Equivalent to the original SdramSpec
-- 'case_wordRoundTrip' but through the two-port interface.
case_dataOnly :: Assertion
case_dataOnly = do
  let mem = CP.repeat 0
      -- Cycles: 0=reset, 1-4=SW (4 cycles for write completion),
      -- 5-12=LW (multi-cycle read).
      fSels = P.replicate 13 False
      fAddrs = P.replicate 13 0
      dSels = False : P.replicate 4 True P.++ P.replicate 8 True
      dAddrs = sdramBase : P.replicate 12 sdramBase
      dWdatas = 0 : P.replicate 4 0xDEADBEEF P.++ P.replicate 8 0
      dBes = 0 : P.replicate 4 0b1111 P.++ P.replicate 8 0
      (_, _, dr, dy) = runSdram2 13 fSels fAddrs dSels dAddrs dWdatas dBes mem
      -- Skip the first 4 cycles (write window) and find the read
      -- ready pulse in the load window.
      readyCycles = P.zip [0 ..] dy
      readPulses = P.filter (\(i, r) -> r P.&& i P.> 4) readyCycles
  case readPulses of
    [] -> assertBool "data read should produce a ready pulse" False
    ((idx, _) : _) ->
      assertEqual
        "data rdata at the read-ready cycle equals the written value"
        0xDEADBEEF
        (dr P.!! idx)

-- | Concurrent fetch + data: both assert from cycle 1. Data has
-- priority — the FIRST transaction the FSM picks should be the
-- data port's. We verify this by checking that dataReady fires
-- BEFORE fetchReady when both are asserted from the same cycle.
case_dataWinsOnConcurrent :: Assertion
case_dataWinsOnConcurrent = do
  let mem =
        makeMem
          [ (0x100, 0xAAAAAAAA) -- fetch port reads here
          , (0x200, 0xBBBBBBBB) -- data port reads here
          ]
      -- Both ports assert from cycle 1 onwards, with different
      -- addresses. Hold long enough for both to complete.
      fSels = False : P.replicate 25 True
      fAddrs = sdramBase : P.replicate 25 (sdramBase + 0x100)
      dSels = False : P.replicate 25 True
      dAddrs = sdramBase : P.replicate 25 (sdramBase + 0x200)
      dWdatas = P.replicate 26 0
      dBes = P.replicate 26 0 -- both reads
      (fr, fy, dr, dy) = runSdram2 26 fSels fAddrs dSels dAddrs dWdatas dBes mem
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
  -- Fetch should also eventually complete, with its own value.
  assertBool
    ("fetch ready should also eventually fire, fy=" P.++ P.show fy)
    (firstFetchReady P.< 26)
  assertEqual
    "fetch rdata at first fetch-ready is fetch port's address value"
    0xAAAAAAAA
    (fr P.!! firstFetchReady)

-- | The fetch port's ready signal must NOT pulse when only the
-- data port has an active transaction. Regression cover for the
-- SoC-arbiter bug where ownership leakage made the wrong port's
-- ready pulse.
case_fetchReadyOnlyOnFetch :: Assertion
case_fetchReadyOnlyOnFetch = do
  let mem = makeMem [(0x100, 0xDEADBEEF)]
      -- Only data port asserts.
      fSels = P.replicate 13 False
      fAddrs = P.replicate 13 0
      dSels = False : P.replicate 12 True
      dAddrs = sdramBase : P.replicate 12 (sdramBase + 0x100)
      dWdatas = P.replicate 13 0
      dBes = P.replicate 13 0
      (_, fy, _, _) = runSdram2 13 fSels fAddrs dSels dAddrs dWdatas dBes mem
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
      -- Only fetch port asserts.
      fSels = False : P.replicate 12 True
      fAddrs = sdramBase : P.replicate 12 (sdramBase + 0x100)
      dSels = P.replicate 13 False
      dAddrs = P.replicate 13 0
      dWdatas = P.replicate 13 0
      dBes = P.replicate 13 0
      (_, _, _, dy) = runSdram2 13 fSels fAddrs dSels dAddrs dWdatas dBes mem
  assertBool
    ( "data ready must never pulse when dataSel is False, dy="
        P.++ P.show dy
    )
    (P.not (P.or dy))

-- | THE SMOKING GUN regression. In the broken SoC arbiter, a data
-- load with dAddr=0x80100000 returned the chip cells at
-- pcFetchS=0x80000054 instead — the IF stage's prefetched word
-- (= the lw instruction itself, encoding 0x00062983). Here we
-- replicate the exact failure shape: fetch port presents one
-- address, data port a different one, both have unique pre-seeded
-- values. Data port's rdata MUST come from its own dAddr.
case_dataLoadSeesOwnAddr :: Assertion
case_dataLoadSeesOwnAddr = do
  -- Mimic the silicon stress test: fetch points at 0x54 (= the
  -- second lw in the inner loop), data points at 0x80100000-style
  -- offset. Pre-seed both with distinct values so a routing bug
  -- shows up as the data port reading the fetch's value.
  let fetchOff = 0x54
      dataOff = 0x100000 -- 1 MB into chip = bank-crossing addr
      fetchVal = 0x00062983 -- the lw instruction (the bug's signature)
      dataVal = 0x12340000 -- the value the firmware actually wrote
      mem =
        makeMem
          [ (fetchOff, fetchVal)
          , (P.fromIntegral dataOff, dataVal)
          ]
      -- Both ports concurrently want SDRAM. Fetch will be held
      -- across the whole window (= same as a stalled IF stage).
      fSels = False : P.replicate 25 True
      fAddrs = sdramBase : P.replicate 25 (sdramBase + P.fromIntegral fetchOff)
      dSels = False : P.replicate 25 True
      dAddrs = sdramBase : P.replicate 25 (sdramBase + P.fromIntegral dataOff)
      dWdatas = P.replicate 26 0
      dBes = P.replicate 26 0 -- read
      (_fr, _fy, dr, dy) = runSdram2 26 fSels fAddrs dSels dAddrs dWdatas dBes mem
      firstDataReady = P.length (P.takeWhile P.not dy)
  assertBool
    ("data ready should fire within 26 cycles, dy=" P.++ P.show dy)
    (firstDataReady P.< 26)
  let actual = dr P.!! firstDataReady
  -- The whole point of the test: actual MUST be dataVal, NOT
  -- fetchVal. If a regression brings the bug back, this fails
  -- with actual=0x00062983.
  assertEqual
    ( "data port read returned the FETCH port's chip-side value "
        P.++ "(this is the task #21 silicon bug — see SdramTwoPortSpec header)"
    )
    dataVal
    actual

-- | Mixed back-to-back: stream of alternating fetch/data
-- transactions. Each port sees its own correct values. Catches
-- per-transaction port-leakage that single-shot tests miss.
case_mixedStreamCorrectness :: Assertion
case_mixedStreamCorrectness = do
  -- Pre-seed 4 fetch addresses + 4 data addresses, all distinct
  -- values. Run a long sequence holding fetchSel constantly (=
  -- IF stage always wants new instruction) and data port pulsing
  -- briefly for each load.
  let fetchVals = [(0x100, 0xF1F1F1F1), (0x104, 0xF2F2F2F2), (0x108, 0xF3F3F3F3), (0x10C, 0xF4F4F4F4)]
      dataVals = [(0x200, 0xD1D1D1D1), (0x204, 0xD2D2D2D2)]
      mem = makeMem (fetchVals P.++ dataVals)
      -- Hold fetch on offset 0x100 for many cycles. Pulse data
      -- twice on different addresses. Each data load must come
      -- back with its own value, NOT 0xF1F1F1F1.
      cycles = 60
      fSels = False : P.replicate (cycles - 1) True
      fAddrs = sdramBase : P.replicate (cycles - 1) (sdramBase + 0x100)
      -- Data: idle 4, assert 12 cycles for first load (addr 0x200),
      -- idle 12, assert 12 cycles for second load (addr 0x204).
      dSels =
        P.replicate 4 False
          P.++ P.replicate 12 True
          P.++ P.replicate 12 False
          P.++ P.replicate 12 True
          P.++ P.replicate (cycles - 52) False
      dAddrs =
        P.replicate 4 sdramBase
          P.++ P.replicate 12 (sdramBase + 0x200)
          P.++ P.replicate 12 sdramBase
          P.++ P.replicate 12 (sdramBase + 0x204)
          P.++ P.replicate (cycles - 52) sdramBase
      dWdatas = P.replicate cycles 0
      dBes = P.replicate cycles 0
      (_, _, dr, dy) = runSdram2 cycles fSels fAddrs dSels dAddrs dWdatas dBes mem
      -- Find both data-ready pulses.
      dyIdx = P.zip [0 ..] dy
      readyIdxs = P.map P.fst (P.filter P.snd dyIdx)
  assertBool
    ( "expected 2 data-ready pulses, got "
        P.++ P.show (P.length readyIdxs)
        P.++ " at cycles "
        P.++ P.show readyIdxs
    )
    (P.length readyIdxs P.>= 2)
  let val1 = dr P.!! (readyIdxs P.!! 0)
      val2 = dr P.!! (readyIdxs P.!! 1)
  assertEqual "first data load returns 0xD1D1D1D1" 0xD1D1D1D1 val1
  assertEqual "second data load returns 0xD2D2D2D2" 0xD2D2D2D2 val2
