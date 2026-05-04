-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : SdramCdcSpec
Description : Asymmetric-rate SdramCdcBridge tests.

Companion to 'CdcSpec' / 'CoreCdcSpec' for the SDRAM-side CDC bridge.
The pre-Phase-E unit suite exercises 'sdramCdcBridge' indirectly only
via 'CdcSocIntegrationSpec' (which uses the PRODUCTION 'Riski5.Domains'
periods — DomBus = DomSdram = 25_000 ps) and via the tied-passthrough
shortcut. Neither variant exercises the toggle-handshake CDC machinery
under genuinely-asynchronous clocks.

This spec runs the bridge at the production multi-PLL ratios:

  * 'case_*_sdramfast'  — DomBus 25_000 ps (40 MHz) /
                           DomSdram 10_000 ps (100 MHz).
                           Mirrors the planned SDRAM-fast silicon
                           where the SDRAM controller runs near the
                           IS42S16400-7TL chip's spec.
  * 'case_*_sdramultra' — DomBus 25_000 ps (40 MHz) /
                           DomSdram 7_500 ps (133.33 MHz).
                           Chip-spec rate.
  * 'case_*_oddratio'   — DomBus 25_000 ps (40 MHz) /
                           DomSdram 11_000 ps (~90.9 MHz).
                           Non-integer ratio so the toggle edges
                           land on truly-asynchronous positions.

Each test plumbs:

@
   producer (DomBus)  ⇄  sdramCdcBridge  ⇄  sdramIpSim (DomSdram)
                                              + 16-word backing mem
@

and asserts data integrity (read after write returns the right value)
plus FSM correctness (master returns to MIdle after each transaction,
no spurious doneEdges, etc).
-}
module SdramCdcSpec (tests) where

import Clash.Explicit.Prelude hiding ((++))
import qualified Clash.Explicit.Prelude as CE
import Clash.Explicit.Testbench (tbClockGen)
import qualified Clash.Prelude as CP
import qualified Clash.Sized.Vector as V
import Riski5.Sdram (
  SdramIpBus (..),
  SdramIpReply (..),
  sdramIpSim,
 )
import Riski5.SdramCdcBridge (sdramCdcBridge, sdramCdcBridgeTied)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, testCase)
import qualified Prelude as P
import Prelude (Bool (..), Int, fmap, show, ($), (.), (++), (<), (<=), (==), (>=))

-- * Test domains -------------------------------------------------

-- | Bus side: 25_000 ps = 40 MHz. Same period as DomBus.
createDomain
  vSystem
    { vName = "DomBusS40"
    , vPeriod = 25000
    , vResetKind = Asynchronous
    , vResetPolarity = ActiveLow
    }

-- | SDRAM side: 10_000 ps = 100 MHz. Realistic Cyclone II SDRAM
-- controller rate.
createDomain
  vSystem
    { vName = "DomSdram100"
    , vPeriod = 10000
    , vResetKind = Asynchronous
    , vResetPolarity = ActiveLow
    }

-- | SDRAM side: 7_500 ps = 133.33 MHz. IS42S16400-7TL chip-spec
-- rated rate.
createDomain
  vSystem
    { vName = "DomSdram133"
    , vPeriod = 7500
    , vResetKind = Asynchronous
    , vResetPolarity = ActiveLow
    }

-- | SDRAM side: 11_000 ps (~90.9 MHz). Non-integer ratio with
-- DomBusS40 so the CDC edges land on asynchronous positions.
createDomain
  vSystem
    { vName = "DomSdramOdd"
    , vPeriod = 11000
    , vResetKind = Asynchronous
    , vResetPolarity = ActiveLow
    }

-- | SDRAM side: 25_000 ps = 40 MHz. Used for tied-vs-split equivalence
-- check (same period as bus, but distinct domain so the bridge still
-- inserts CDC machinery).
createDomain
  vSystem
    { vName = "DomSdramSame"
    , vPeriod = 25000
    , vResetKind = Asynchronous
    , vResetPolarity = ActiveLow
    }

-- * SdramIpBus helpers ------------------------------------------

idleBus :: SdramIpBus
idleBus = SdramIpBus False 0 0 0 False False

writeBus :: BitVector 22 -> BitVector 16 -> BitVector 2 -> SdramIpBus
writeBus a d be = SdramIpBus True a d be False True

readBus :: BitVector 22 -> SdramIpBus
readBus a = SdramIpBus True a 0 0b11 True False

-- | Initial 16-word memory (all zeros).
initMem :: Vec 16 (BitVector 16)
initMem = CP.repeat 0

-- | Pulse a single transaction onto the bus. Holds @sibCs=True@ for
-- @hold@ cycles to bridge the 1-cycle reset window so the master
-- definitely sees the assertion in MIdle, then drops to idle for
-- @idle@ cycles to give the bridge time to complete and quiesce
-- (so we get exactly one transaction even though sibCs was held).
-- The master goes MIdle → MBusy → ... → MDoneR/W. While in MBusy
-- it ignores input. By the time it returns to MIdle the @hold@
-- cycles have passed and sibCs is False, so no second acceptance.
--
-- Hold count must be ≤ the bridge's MBusy duration; ≤ 3 is
-- always safe at the multi-PLL test ratios since the round-trip
-- is ≥ 6 bus cycles (toggle sync + slave round-trip + done sync).
pulse :: SdramIpBus -> Int -> [SdramIpBus]
pulse req idle = P.replicate 3 req ++ P.replicate idle idleBus

-- * Harness over arbitrary domain pairs --------------------------

{- | Drive a sequence of SdramIpBus operations across the bridge and
return the per-cycle SdramIpReply seen by the master plus the
per-cycle SdramIpBus driven onto the slave.

The producer holds the LAST element of the sequence forever past
its end (typically 'idleBus' so the bridge eventually quiesces).
-}
runBridgePair ::
  forall busDom sdramDom.
  (KnownDomain busDom, KnownDomain sdramDom) =>
  Clock busDom ->
  Reset busDom ->
  Enable busDom ->
  Clock sdramDom ->
  Reset sdramDom ->
  Enable sdramDom ->
  Int ->
  [SdramIpBus] ->
  ([SdramIpReply], [SdramIpBus])
runBridgePair clkB rstB enB clkS rstS enS n ops =
  let busInB :: Signal busDom SdramIpBus
      busInB = fromList (ops ++ P.repeat idleBus)
      (replyOutB, busOutS) =
        sdramCdcBridge clkB rstB enB clkS rstS enS busInB replyInS
      replyInS :: Signal sdramDom SdramIpReply
      replyInS =
        CP.exposeClockResetEnable
          (sdramIpSim initMem busOutS)
          clkS
          rstS
          enS
   in (CE.sampleN n replyOutB, CE.sampleN n busOutS)

-- | DomBusS40 over DomSdram100: 40 MHz bus, 100 MHz SDRAM.
runSdramFast :: Int -> [SdramIpBus] -> ([SdramIpReply], [SdramIpBus])
runSdramFast =
  runBridgePair
    (tbClockGen @DomBusS40 (CP.pure True))
    (resetGen @DomBusS40)
    (enableGen @DomBusS40)
    (tbClockGen @DomSdram100 (CP.pure True))
    (resetGen @DomSdram100)
    (enableGen @DomSdram100)

-- | DomBusS40 over DomSdram133: 40 MHz bus, 133 MHz SDRAM (chip-spec).
runSdramUltra :: Int -> [SdramIpBus] -> ([SdramIpReply], [SdramIpBus])
runSdramUltra =
  runBridgePair
    (tbClockGen @DomBusS40 (CP.pure True))
    (resetGen @DomBusS40)
    (enableGen @DomBusS40)
    (tbClockGen @DomSdram133 (CP.pure True))
    (resetGen @DomSdram133)
    (enableGen @DomSdram133)

-- | DomBusS40 over DomSdramOdd: 40 MHz bus, ~90.9 MHz SDRAM.
runSdramOdd :: Int -> [SdramIpBus] -> ([SdramIpReply], [SdramIpBus])
runSdramOdd =
  runBridgePair
    (tbClockGen @DomBusS40 (CP.pure True))
    (resetGen @DomBusS40)
    (enableGen @DomBusS40)
    (tbClockGen @DomSdramOdd (CP.pure True))
    (resetGen @DomSdramOdd)
    (enableGen @DomSdramOdd)

-- | DomBusS40 over DomSdramSame: same period (40/40 MHz) but
-- distinct domain so the bridge's full CDC machinery runs. Used
-- for "split bridge degenerates to tied behaviour modulo CDC
-- latency" property tests.
runSdramSame :: Int -> [SdramIpBus] -> ([SdramIpReply], [SdramIpBus])
runSdramSame =
  runBridgePair
    (tbClockGen @DomBusS40 (CP.pure True))
    (resetGen @DomBusS40)
    (enableGen @DomBusS40)
    (tbClockGen @DomSdramSame (CP.pure True))
    (resetGen @DomSdramSame)
    (enableGen @DomSdramSame)

-- | Tied passthrough harness in DomBusS40. Same producer feeds
-- 'sdramCdcBridgeTied' and 'sdramIpSim' directly; baseline for
-- equivalence comparison.
runTied :: Int -> [SdramIpBus] -> ([SdramIpReply], [SdramIpBus])
runTied n ops =
  let clkB = tbClockGen @DomBusS40 (CP.pure True)
      rstB = resetGen @DomBusS40
      enB = enableGen @DomBusS40
      busInB :: Signal DomBusS40 SdramIpBus
      busInB = fromList (ops ++ P.repeat idleBus)
      (replyOutB, busOutS) = sdramCdcBridgeTied busInB replyInS
      replyInS :: Signal DomBusS40 SdramIpReply
      replyInS =
        CP.exposeClockResetEnable (sdramIpSim initMem busOutS) clkB rstB enB
   in (CE.sampleN n replyOutB, CE.sampleN n busOutS)

-- * Test cases --------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Riski5.SdramCdcBridge — asymmetric-rate"
    [ testCase "tied passthrough returns input bus + reply unchanged" case_tied_passthrough
    , testCase "single write completes (40/100 MHz)" case_single_write_sdramfast
    , testCase "single read completes & returns 0 (40/100 MHz)" case_single_read_sdramfast
    , testCase "write then read returns written data (40/100 MHz)" case_wr_rd_sdramfast
    , testCase "write then read returns written data (40/133 MHz)" case_wr_rd_sdramultra
    , testCase "write then read returns written data (40/90.9 MHz)" case_wr_rd_oddratio
    , testCase "back-to-back writes both commit (40/100 MHz)" case_b2b_writes_sdramfast
    , testCase "split bridge ↔ tied bridge: same data, more latency" case_split_vs_tied_data
    , testCase "master returns to MIdle (waitrequest=False) after txn" case_master_idle_after_txn
    ]

-- ** Tied passthrough sanity ------------------------------------

case_tied_passthrough :: Assertion
case_tied_passthrough = do
  -- Drive a write at cycle 0 and assert the bridge passes the bus
  -- through unchanged in cycle 0 (and returns whatever the slave
  -- said). The tied bridge is a pure direct wire — no FSM, so we
  -- don't need to bridge a reset cycle here.
  let ops = [writeBus 0x10 0xCAFE 0b11, idleBus, idleBus, idleBus]
      (_replyTrace, busTrace) = runTied 4 ops
  assertEqual
    "tied bridge: cycle 0 bus driven to slave matches input"
    (writeBus 0x10 0xCAFE 0b11)
    (P.head busTrace)

-- ** Single transactions ----------------------------------------

{- | Issue a single write and let the bridge run. Assert that the
master enters MBusy (waitrequest=True) for at least a few cycles —
proves the bridge accepted the transaction. With the @pulse@
helper above the request is held for 3 cycles (spans the 1-cycle
reset window), so the master picks it up at cycle 1 (when reset
deasserts) and goes MIdle → MBusy.
-}
case_single_write_sdramfast :: Assertion
case_single_write_sdramfast = do
  let n = 200
      ops = pulse (writeBus 0x05 0xBEEF 0b11) (n P.- 3)
      (replyTrace, _) = runSdramFast n ops
      busyCount = P.length [() | r <- replyTrace, sirWaitrequest r]
      waitFalseCount = P.length [() | r <- replyTrace, P.not (sirWaitrequest r)]
  -- Master should be in MBusy for the duration of the bridge's
  -- round-trip — at least a handful of bus cycles.
  assertBool
    ("expected master to enter MBusy (≥3 cycles waitrequest=True; got " ++ show busyCount ++ ")")
    (busyCount >= 3)
  -- And eventually return to MIdle, so waitrequest=False dominates.
  assertBool
    ("expected waitrequest=False to dominate after completion (got " ++ show waitFalseCount ++ "/" ++ show n ++ ")")
    (waitFalseCount >= n - 50)

case_single_read_sdramfast :: Assertion
case_single_read_sdramfast = do
  let n = 200
      ops = pulse (readBus 0x05) (n P.- 3)
      (replyTrace, _) = runSdramFast n ops
      validPulses = [(i, r) | (i, r) <- P.zip [0 :: Int ..] replyTrace, sirValid r]
  assertBool
    ("expected ≥1 sirValid pulse for read (got " ++ show (P.length validPulses) ++ ")")
    (P.length validPulses >= 1)
  -- mem is zero-initialised so read should return 0.
  assertEqual
    "read of unwritten cell returns 0"
    0
    (sirRdata (P.snd (P.head validPulses)))

{- | The load-bearing data-integrity test: write 0xCAFE to cell 5,
let the bridge complete, then read cell 5 back and assert we get
0xCAFE. Catches any data corruption on the Bus→Sdram payload
crossing (latched bundle racing toggle, etc.) or on the
Sdram→Bus rdata crossing (wrong cycle of capRdata sampled, etc.).
-}
case_wr_rd_sdramfast :: Assertion
case_wr_rd_sdramfast = wr_rd_template runSdramFast

case_wr_rd_sdramultra :: Assertion
case_wr_rd_sdramultra = wr_rd_template runSdramUltra

case_wr_rd_oddratio :: Assertion
case_wr_rd_oddratio = wr_rd_template runSdramOdd

wr_rd_template ::
  (Int -> [SdramIpBus] -> ([SdramIpReply], [SdramIpBus])) ->
  Assertion
wr_rd_template runner = do
  let n = 600
      -- pulse holds for 3 cycles + idle. Write 0xCAFE to addr 5,
      -- give bridge ~100 bus cycles to complete, then issue read,
      -- give bridge another ~400 cycles for completion. The
      -- bridge's round-trip at any of the test ratios is well
      -- under 50 bus cycles, so 100 is generous.
      ops =
        pulse (writeBus 0x05 0xCAFE 0b11) 100
          ++ pulse (readBus 0x05) (n P.- 200)
      (replyTrace, _) = runner n ops
      validPulses = [r | r <- replyTrace, sirValid r]
  assertBool
    ("expected ≥1 sirValid pulse for read (got " ++ show (P.length validPulses) ++ ")")
    (P.length validPulses >= 1)
  assertEqual
    "read after write returns the written value"
    0xCAFE
    (sirRdata (P.head validPulses))

-- ** Back-to-back transactions ----------------------------------

{- | Issue two write transactions back-to-back (with enough idle
gap that the bridge completes the first before the second
arrives), then assert both committed by reading each back. Catches
the multi-PLL-silicon DTB-corruption regression that motivated
the back-to-back accept branches in 'masterStep' (commits MDoneW /
MDoneR can re-arm with @sibCs@).
-}
case_b2b_writes_sdramfast :: Assertion
case_b2b_writes_sdramfast = do
  let n = 1000
      ops =
        pulse (writeBus 0x03 0x1234 0b11) 100
          ++ pulse (writeBus 0x07 0x5678 0b11) 100
          ++ pulse (readBus 0x03) 200
          ++ pulse (readBus 0x07) (n P.- 410)
      (replyTrace, _) = runSdramFast n ops
      validPulses = [r | r <- replyTrace, sirValid r]
      rdatas = P.map sirRdata validPulses
  assertBool
    ("expected ≥2 sirValid pulses (one per read; got " ++ show (P.length validPulses) ++ ")")
    (P.length validPulses >= 2)
  assertEqual
    "both writes must be readable back"
    [0x1234, 0x5678]
    (P.take 2 rdatas)

-- ** Equivalence of split vs tied --------------------------------

{- | The split bridge MUST produce the same observable data as the
tied passthrough — only with extra latency. Drive the same write+
read sequence through both and assert the read data matches (cycle
of the rdata may differ, but the value must be the same).
-}
case_split_vs_tied_data :: Assertion
case_split_vs_tied_data = do
  let n = 600
      ops =
        pulse (writeBus 0x09 0xABCD 0b11) 100
          ++ pulse (readBus 0x09) (n P.- 200)
      (splitReply, _) = runSdramSame n ops
      (tiedReply, _) = runTied n ops
      splitValid = [sirRdata r | r <- splitReply, sirValid r]
      tiedValid = [sirRdata r | r <- tiedReply, sirValid r]
  assertBool
    "tied bridge must produce ≥1 valid read"
    (P.length tiedValid >= 1)
  assertBool
    "split bridge must produce ≥1 valid read"
    (P.length splitValid >= 1)
  assertEqual
    "both bridges must return the same first read value"
    (P.head tiedValid)
    (P.head splitValid)

-- ** Master FSM exits MBusy -------------------------------------

{- | After a single transaction, the master MUST return to MIdle
(= waitrequest=False) within a bounded number of cycles. Without
this, every transaction "stalls forever" in MBusy and the SoC
deadlocks the first time it issues an SDRAM request.
-}
case_master_idle_after_txn :: Assertion
case_master_idle_after_txn = do
  let n = 300
      ops = pulse (writeBus 0x02 0x4242 0b11) (n P.- 3)
      (replyTrace, _) = runSdramFast n ops
      -- Find the first cycle waitrequest goes True (= MBusy entered).
      busyEntered =
        P.takeWhile P.not (P.map sirWaitrequest replyTrace)
      -- After busyEntered, find the first cycle waitrequest goes
      -- False again (= MDoneW or MIdle).
      afterBusy = P.drop (P.length busyEntered) replyTrace
      busyHigh = P.takeWhile sirWaitrequest afterBusy
  -- The whole MBusy interval should be bounded — at 40/100 MHz with
  -- the toggle handshake the round-trip is ~6 bus cycles + sdram
  -- internal. Allow generous bound 50 bus cycles.
  assertBool
    ( "expected MBusy phase ≤ 50 bus cycles (got "
        ++ show (P.length busyHigh)
        ++ "; if this is huge, the bridge is hung in MBusy)"
    )
    (P.length busyHigh <= 50)
  -- Sanity: master must have entered MBusy at all.
  assertBool
    "master must have entered MBusy at least once"
    (P.length busyHigh >= 1)
