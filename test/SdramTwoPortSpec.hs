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
    , testCase
        "fetch-held + write-then-read: read must see written value (task-#17 scope)"
        case_fetchHeldWriteThenRead
    , testGroup
        "smoking-gun regression (task #21)"
        [ testCase
            "data load returns its OWN addr's value — not the fetch port's"
            case_dataLoadSeesOwnAddr
        , testCase
            "back-to-back mixed fetch+data: each gets correct value"
            case_mixedStreamCorrectness
        ]
    , testGroup
        "AMO-shape transactions (task #29)"
        [ testCase
            "fetch-held + AMO-shape (read X → write X → read X back-to-back) returns written value"
            case_amoShapeReadWriteRead
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
      -- Cycles 0=reset, 1-4=write (sw 0xDEADBEEF), 5-9=idle to
      -- separate write from read, 10-19=read window. The idle gap
      -- ensures the read's ready pulse is unambiguous (write
      -- completions also pulse dataReady — correctly — but we
      -- need to test the read's rdata in particular).
      cycles = 20
      fSels = P.replicate cycles False
      fAddrs = P.replicate cycles 0
      dSels =
        P.replicate 1 False
          P.++ P.replicate 4 True
          P.++ P.replicate 5 False
          P.++ P.replicate 10 True
      dAddrs = P.replicate cycles sdramBase
      dWdatas =
        P.replicate 1 0
          P.++ P.replicate 4 0xDEADBEEF
          P.++ P.replicate 15 0
      dBes =
        P.replicate 1 0
          P.++ P.replicate 4 0b1111
          P.++ P.replicate 15 0
      (_, _, dr, dy) = runSdram2 cycles fSels fAddrs dSels dAddrs dWdatas dBes mem
      -- Find ready pulses ONLY in the read window (cycle ≥ 10).
      readyCycles = P.zip [0 ..] dy
      readPulses = P.filter (\(i, r) -> r P.&& i P.>= 10) readyCycles
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
      -- Fetch is held continuously (= IF stage continually wants
      -- new instructions while core stalls on data load). Data
      -- pulses for one transaction window, then deasserts so fetch
      -- gets the next turn — same shape as a real load that
      -- completes and releases the data port. Without releasing,
      -- data wins every SIdle by priority and fetch never runs.
      cycles = 26
      fSels = False : P.replicate (cycles - 1) True
      fAddrs = sdramBase : P.replicate (cycles - 1) (sdramBase + 0x100)
      dSels =
        False : P.replicate 8 True P.++ P.replicate (cycles - 9) False
      dAddrs = P.replicate cycles (sdramBase + 0x200)
      dWdatas = P.replicate cycles 0
      dBes = P.replicate cycles 0 -- both reads
      (fr, fy, dr, dy) = runSdram2 cycles fSels fAddrs dSels dAddrs dWdatas dBes mem
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

{- | Reproduce the silicon @sdramstress@ failure shape in a tight
unit test: fetch port held continuously (= IF stage stuck in
SDRAM range), data port issues SW then LW to a different address.
The LW must return the value SW wrote.

This is the test the integration test @SocChainIntegrationSpec@
catches but the @SdramTwoPortSpec@ smoking-gun test misses —
because the smoking-gun was a read-only scenario, never exercised
write-then-read with fetch contention.
-}
case_fetchHeldWriteThenRead :: Assertion
case_fetchHeldWriteThenRead = do
  -- Fetch points at one cell, data writes 0xDEADBEEF to a different
  -- cell, then reads back. Both ports are asserted across the whole
  -- window; data wins on each SIdle so the write and read complete
  -- in turn while fetch waits.
  let dataOff = 0x4000 :: Int
      dataVal = 0xDEADBEEF
      mem = makeMem [(0x100, 0xCAFEBABE)] -- pre-seed fetch addr only
      cycles = 60
      fSels = False : P.replicate (cycles - 1) True
      fAddrs = sdramBase : P.replicate (cycles - 1) (sdramBase + 0x100)
      -- Data: idle 4, write window 8, idle 4, read window 8.
      dSels =
        P.replicate 4 False
          P.++ P.replicate 8 True -- write
          P.++ P.replicate 4 False
          P.++ P.replicate 8 True -- read
          P.++ P.replicate (cycles - 24) False
      dAddrs = P.replicate cycles (sdramBase + P.fromIntegral dataOff)
      dWdatas =
        P.replicate 4 0
          P.++ P.replicate 8 dataVal
          P.++ P.replicate (cycles - 12) 0
      dBes =
        P.replicate 4 0
          P.++ P.replicate 8 0b1111 -- write
          P.++ P.replicate (cycles - 12) 0 -- read window has be=0
      (_fr, _fy, dr, dy) = runSdram2 cycles fSels fAddrs dSels dAddrs dWdatas dBes mem
      -- The read window is cycle 16 onwards. Find the first
      -- data-ready in the read window.
      readPulses =
        P.map P.fst $
          P.filter (\(i, r) -> r P.&& i P.>= 16) (P.zip [(0 :: Int) ..] dy)
  case readPulses of
    [] -> assertBool ("expected at least one data-ready in read window. dy=" P.++ P.show dy) False
    (idx : _) ->
      assertEqual
        ("data load returned wrong value at cy " P.++ P.show idx)
        dataVal
        (dr P.!! idx)

-- | THE SMOKING GUN regression. In the broken SoC arbiter, a data
-- load with dAddr=0x80100000 returned the chip cells at
-- pcFetchS=0x80000054 instead — the IF stage's prefetched word
-- (= the lw instruction itself, encoding 0x00062983). Here we
-- replicate the exact failure shape: fetch port presents one
-- address, data port a different one, both have unique pre-seeded
-- values. Data port's rdata MUST come from its own dAddr.
case_dataLoadSeesOwnAddr :: Assertion
case_dataLoadSeesOwnAddr = do
  -- Mimic the silicon stress test: fetch points at one cell, data
  -- points at a different cell. Pre-seed both with distinct values
  -- so a routing bug shows up as the data port reading the fetch's
  -- value. (The silicon test uses 0x80100000 for data and PC for
  -- fetch; here we use small offsets that fit inside the test
  -- harness's Vec 16384 half-words = 32 KB chip image.)
  let fetchOff = 0x54
      dataOff = 0x4000 :: Int -- 16 KB into chip — distinct page from fetch
      fetchVal = 0x00062983 -- the lw instruction (the bug's signature)
      dataVal = 0x12340000 -- the value the firmware actually wrote
      mem =
        makeMem
          [ (fetchOff, fetchVal)
          , (dataOff, dataVal)
          ]
      -- Both ports concurrently want SDRAM. Fetch is held across
      -- the whole window (= IF stage stalled in SDRAM range while
      -- core does a load). Data pulses for one transaction; data
      -- has priority so the load takes the next SIdle slot.
      cycles = 26
      fSels = False : P.replicate (cycles - 1) True
      fAddrs = sdramBase : P.replicate (cycles - 1) (sdramBase + P.fromIntegral fetchOff)
      dSels =
        False : P.replicate 10 True P.++ P.replicate (cycles - 11) False
      dAddrs = P.replicate cycles (sdramBase + P.fromIntegral dataOff)
      dWdatas = P.replicate cycles 0
      dBes = P.replicate cycles 0 -- read
      (_fr, _fy, dr, dy) = runSdram2 cycles fSels fAddrs dSels dAddrs dWdatas dBes mem
      firstDataReady = P.length (P.takeWhile P.not dy)
  assertBool
    ("data ready should fire within 26 cycles, dy=" P.++ P.show dy)
    (firstDataReady P.< cycles)
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
  -- Hold fetch continuously. Pulse data twice in two well-separated
  -- windows. Each window is long enough for ONE read to complete
  -- (SDRAM sim takes ~6 cycles per read). Test that the FIRST
  -- ready pulse in each window has the right value.
  let fetchVals = [(0x100, 0xF1F1F1F1), (0x104, 0xF2F2F2F2), (0x108, 0xF3F3F3F3), (0x10C, 0xF4F4F4F4)]
      dataVals = [(0x200, 0xD1D1D1D1), (0x204, 0xD2D2D2D2)]
      mem = makeMem (fetchVals P.++ dataVals)
      cycles = 60
      win1Start = 4
      win1End = 14
      win2Start = 30
      win2End = 40
      fSels = False : P.replicate (cycles - 1) True
      fAddrs = sdramBase : P.replicate (cycles - 1) (sdramBase + 0x100)
      dSels =
        P.replicate win1Start False
          P.++ P.replicate (win1End - win1Start) True
          P.++ P.replicate (win2Start - win1End) False
          P.++ P.replicate (win2End - win2Start) True
          P.++ P.replicate (cycles - win2End) False
      dAddrs =
        P.replicate win1Start sdramBase
          P.++ P.replicate (win1End - win1Start) (sdramBase + 0x200)
          P.++ P.replicate (win2Start - win1End) sdramBase
          P.++ P.replicate (win2End - win2Start) (sdramBase + 0x204)
          P.++ P.replicate (cycles - win2End) sdramBase
      dWdatas = P.replicate cycles 0
      dBes = P.replicate cycles 0
      (_, _, dr, dy) = runSdram2 cycles fSels fAddrs dSels dAddrs dWdatas dBes mem
      -- First ready pulse in window 1 = first data load's value.
      win1Pulses =
        P.map P.fst $
          P.filter (\(i, r) -> r P.&& i P.>= win1Start P.&& i P.< win2Start) (P.zip [0 ..] dy)
      -- First ready pulse in window 2 = second data load's value.
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

{- | Mimic the bus-level shape of an AMO transaction (read X → write
X back-to-back from the data port) under continuous fetch
contention. The amoFU drives the data port:

  * Cycle range R1: dataSel asserted, be=0, addr=X (Read phase)
  * As soon as data-ready pulses, the FU transitions on the next
    clock and the bus re-asserts as a write to the SAME address.
  * Cycle range W1: dataSel asserted, be=0xF, addr=X, wdata=newVal
  * After write completes, the FU enters AmoDone for one cycle
    (data port idle), then the next instruction's bus access
    begins. We model that with a Read-Window R2 a few cycles
    later to verify the write actually committed.

Throughout, fetch is held at a different SDRAM address — the
same shape that broke task #21's data-load + fetch race. If the
new two-port adapter has a corner case where the data port's
write is re-routed to the fetch's address (or vice versa), the
post-write read returns the wrong value.
-}
case_amoShapeReadWriteRead :: Assertion
case_amoShapeReadWriteRead = do
  let dataOff = 0x4000 :: Int
      seedVal = 0x11111111 :: BitVector 32
      newVal = 0x22222222 :: BitVector 32
      mem =
        makeMem
          [ (0x100, 0xCAFEBABE) -- fetch port reads here
          , (dataOff, seedVal) -- data port AMO target
          ]
      -- Cycle plan (60 cycles):
      --   0     reset
      --   1-12  AMO Read phase: dataSel=True, be=0
      --   13-24 AMO Write phase: dataSel=True, be=0xF, wdata=newVal
      --   25-30 AmoDone idle: dataSel=False
      --   31-50 verify Read: dataSel=True, be=0
      --   51-59 idle
      cycles = 60
      readPhase1 = 12 -- enough for SDRAM read latency
      writePhase = 12
      donePhase = 6
      verifyPhase = 20
      fSels = False : P.replicate (cycles - 1) True
      fAddrs = sdramBase : P.replicate (cycles - 1) (sdramBase + 0x100)
      dSels =
        False
          : P.replicate readPhase1 True
          P.++ P.replicate writePhase True
          P.++ P.replicate donePhase False
          P.++ P.replicate verifyPhase True
          P.++ P.replicate (cycles - 1 - readPhase1 - writePhase - donePhase - verifyPhase) False
      dAddrs = P.replicate cycles (sdramBase + P.fromIntegral dataOff)
      dWdatas =
        P.replicate (1 + readPhase1) 0
          P.++ P.replicate writePhase newVal
          P.++ P.replicate (cycles - 1 - readPhase1 - writePhase) 0
      dBes =
        P.replicate (1 + readPhase1) 0
          P.++ P.replicate writePhase 0b1111
          P.++ P.replicate donePhase 0
          P.++ P.replicate verifyPhase 0
          P.++ P.replicate (cycles - 1 - readPhase1 - writePhase - donePhase - verifyPhase) 0
      (_fr, _fy, dr, dy) = runSdram2 cycles fSels fAddrs dSels dAddrs dWdatas dBes mem
      -- Find the first data-ready in the AMO-Read phase (cycles 1-12)
      -- and confirm it carries the seeded value.
      readReady =
        P.map P.fst $
          P.filter (\(i, r) -> r P.&& i P.> 0 P.&& i P.<= 1 + readPhase1) (P.zip [(0 :: Int) ..] dy)
      -- Find the first data-ready in the verify-Read phase
      -- (cycle ≥ 1 + readPhase1 + writePhase + donePhase) and confirm
      -- it carries the WRITTEN value (newVal). If a routing race
      -- between fetch and data scrambles the write, this returns
      -- seedVal (write didn't commit) or fetchVal (cross-port leak).
      verifyStart = 1 + readPhase1 + writePhase + donePhase
      verifyReady =
        P.map P.fst $
          P.filter (\(i, r) -> r P.&& i P.>= verifyStart) (P.zip [(0 :: Int) ..] dy)
  case readReady of
    [] -> assertBool ("expected AMO-Read ready in cycles 1-" P.++ P.show (1 + readPhase1) P.++ "; dy=" P.++ P.show dy) False
    (idx : _) ->
      assertEqual
        ("AMO-Read should return seed value at cy " P.++ P.show idx)
        seedVal
        (dr P.!! idx)
  case verifyReady of
    [] -> assertBool ("expected verify-Read ready after cy " P.++ P.show verifyStart P.++ "; dy=" P.++ P.show dy) False
    (idx : _) ->
      assertEqual
        ( "verify Read should return WRITTEN value (newVal=0x22222222) at cy "
            P.++ P.show idx
            P.++ ". If you see seedVal=0x11111111, the AMO write didn't commit. "
            P.++ "If you see 0xCAFEBABE, fetch leaked into the data port."
        )
        newVal
        (dr P.!! idx)
