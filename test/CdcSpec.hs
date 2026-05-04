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
Module      : CdcSpec
Description : Property + unit tests for the CoreCdcBridge FSM.

Built to catch the class of silicon bugs that would otherwise need
a full bitstream-flash-probe round-trip per iteration:

  1. /Sentinel-init bug/. With @mLastSentPc@ initialised to 0 and
     reset_pc=0, 'reqIsLive' returns False on the very first cycle
     so the bridge never fires the boot transaction. Test:
     @case_first_fetch_fires@.

  2. /Garbage-fetch loop/. With @mReply@ preserved across MIdle
     after MDone, the core saw the last response held with
     stall=False while it was already asking for a new PC, so it
     committed the previous request's instruction at the new PC.
     Test: @case_pc_advance_no_stale_data@ — drives PC=0 then PC=4,
     asserts the imemData at the second 'stall=False' edge matches
     the reply for PC=4 (not PC=0).

  3. /Self-loop deadlock/. With @mReply = defaultReply@ on
     'MDone → MIdle', the core can't re-execute the same
     instruction (e.g. @j .@) because every cycle in MIdle it sees
     stall=True. Test: @case_self_loop_keeps_running@ — holds the
     same request across many cycles, asserts stall=False is seen
     on multiple separated cycles (so the core can commit the
     instruction more than once).

  4. /Multi-write store/. With the slave driving sLatReq even
     between transactions, dBe!=0 leaks into idle cycles and the
     bus's UART (or any side-effecting slave) commits the same
     write multiple times. Test: @case_store_drives_dBe_briefly@
     — sends one cycle of dBe!=0 from the core, asserts dBe!=0 on
     the bus side is bounded (not held forever in sLatReq).

  5. /Tied passthrough/. 'coreCdcBridgeTied' is a pure pass-through
     used by single-domain sim helpers; verify it actually returns
     the input signals unchanged. Test: @case_tied_passthrough@.

The tests use 'Clash.Explicit.Prelude' so the core and bus run in
genuinely-distinct clock domains. The bridge's FSM advances on each
domain's own clock per @tbClockGen@'s waveform.
-}
module CdcSpec (tests) where

import Clash.Explicit.Prelude hiding ((++))
import qualified Clash.Explicit.Prelude as CE
import Clash.Explicit.Testbench (tbClockGen)
import qualified Clash.Prelude as CP
import Riski5.CoreCdcBridge (
  CoreBusReply (..),
  CoreBusReq (..),
  coreCdcBridge,
  coreCdcBridgeTied,
  coreCdcBridgeWithDebug,
 )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, testCase)
import qualified Prelude as P
import Prelude (Bool (..), Int, fmap, show, ($), (++), (<), (==), (>=))

-- * Test domains -------------------------------------------------

-- | Core-side test domain. 25 ns / 40 MHz, matches DomBus default.
createDomain
  vSystem
    { vName = "DomTcA"
    , vPeriod = 25000
    , vResetKind = Asynchronous
    , vResetPolarity = ActiveLow
    }

-- | Bus-side test domain. Same period as DomTcA — for these
-- functional tests we don't need the asynchronous-clock case;
-- 'Clash.Explicit.Prelude' still treats them as distinct domains
-- so the bridge's CDC machinery (syncBit, syncBitVector,
-- edgeDetect) actually runs.
createDomain
  vSystem
    { vName = "DomTcB"
    , vPeriod = 25000
    , vResetKind = Asynchronous
    , vResetPolarity = ActiveLow
    }

-- | Faster bus-side domain for asymmetric-rate tests (12.5 ns /
-- 80 MHz). Not used in the functional suite below; reserved for
-- future Phase E multi-rate tests.
createDomain
  vSystem
    { vName = "DomTcBfast"
    , vPeriod = 12500
    , vResetKind = Asynchronous
    , vResetPolarity = ActiveLow
    }

-- * Default values ----------------------------------------------

emptyReq :: CoreBusReq
emptyReq = CoreBusReq 0 0 0 0 False

-- | Reply with a deterministic imemData derived from the request.
-- Lets each test assert "the imemData I see corresponds to the PC
-- I asked for" rather than tracking arbitrary fixtures.
busReply :: CoreBusReq -> CoreBusReply
busReply req =
  CoreBusReply
    { cbrImemData = cbrPcFetch req `CP.xor` 0xCAFEBABE
    , cbrImemReady = True
    , cbrDmemRdata = cbrDAddr req `CP.xor` 0xDEADBEEF
    , cbrStall = False
    , cbrDataStall = False
    , cbrMtip = False
    , cbrMeip = False
    }

-- * Harness -----------------------------------------------------

{- | Like 'runBridge' but also returns the per-cycle master debug
byte from 'coreCdcBridgeWithDebug'. Useful for asserting on FSM
transition counts.
-}
runBridgeDbg ::
  Int ->
  [CoreBusReq] ->
  (CoreBusReq -> CoreBusReply) ->
  ([CoreBusReply], [CoreBusReq], [BitVector 8], [BitVector 8])
runBridgeDbg n reqs busFunc =
  let clkA = tbClockGen @DomTcA (pure True)
      rstA = resetGen @DomTcA
      enA = enableGen @DomTcA
      clkB = tbClockGen @DomTcB (pure True)
      rstB = resetGen @DomTcB
      enB = enableGen @DomTcB
      reqInA :: Signal DomTcA CoreBusReq
      reqInA = fromList (reqs ++ P.repeat (P.last (emptyReq : reqs)))
      replyInB :: Signal DomTcB CoreBusReply
      replyInB = fmap busFunc reqOutB
      (replyOutA, reqOutB, dbgM, dbgS) =
        coreCdcBridgeWithDebug clkA rstA enA clkB rstB enB reqInA replyInB
   in ( CE.sampleN n replyOutA
      , CE.sampleN n reqOutB
      , CE.sampleN n dbgM
      , CE.sampleN n dbgS
      )

{- | Run the bridge for @n@ core-side cycles.

  - @reqs@: the sequence of requests the core asserts (held at the
    last value past its end, so short lists don't blow up).
  - @busFunc@: how the fake bus replies given the bridge's bus-side
    request. Per-cycle pure function so the test can model a
    memory or a stalling slave.

Returns @(replyOutCore, reqOutBus)@ traces over @n@ core cycles.
-}
runBridge ::
  Int ->
  [CoreBusReq] ->
  (CoreBusReq -> CoreBusReply) ->
  ([CoreBusReply], [CoreBusReq])
runBridge n reqs busFunc =
  let clkA = tbClockGen @DomTcA (pure True)
      rstA = resetGen @DomTcA
      enA = enableGen @DomTcA
      clkB = tbClockGen @DomTcB (pure True)
      rstB = resetGen @DomTcB
      enB = enableGen @DomTcB
      reqInA :: Signal DomTcA CoreBusReq
      reqInA = fromList (reqs ++ P.repeat (P.last (emptyReq : reqs)))
      replyInB :: Signal DomTcB CoreBusReply
      replyInB = fmap busFunc reqOutB
      (replyOutA, reqOutB) =
        coreCdcBridge clkA rstA enA clkB rstB enB reqInA replyInB
   in (CE.sampleN n replyOutA, CE.sampleN n reqOutB)

-- * Test cases --------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Riski5.CoreCdcBridge"
    [ testCase "tied passthrough returns input signals unchanged" case_tied_passthrough
    , testCase "first fetch fires (sentinel mLastSentPc init)" case_first_fetch_fires
    , testCase "PC advance presents fresh imemData (no stale-reply)" case_pc_advance_no_stale_data
    , testCase "self-loop request lets core re-execute (no deadlock)" case_self_loop_keeps_running
    , testCase "single SW asserts dBe!=0 on bus only briefly" case_store_drives_dBe_briefly
    , testCase "held SW request fires bridge ONCE not on every cycle" case_held_sw_fires_once
    , testCase "held SW: master FSM does NOT spuriously re-fire" case_held_sw_no_master_refire
    , testCase "slave drives empty req when not actively serving" case_slave_drives_empty_in_idle
    , testCase "imemReady=True is asserted one cycle BEFORE stall=False" case_imemready_announced_early
    ]

-- ** 1. Tied passthrough ----------------------------------------

case_tied_passthrough :: Assertion
case_tied_passthrough = do
  let req1 = CoreBusReq 0x100 0x200 0xDEAD 0xF True
      reply1 = CoreBusReply 0xCAFE True 0xBABE False False True False
      reqIn :: Signal DomTcA CoreBusReq
      reqIn = pure req1
      replyIn :: Signal DomTcA CoreBusReply
      replyIn = pure reply1
      (replyOut, reqOut) = coreCdcBridgeTied reqIn replyIn
  assertEqual
    "tied bridge returns reply input as core-side reply"
    [reply1]
    (CE.sampleN 1 replyOut)
  assertEqual
    "tied bridge returns req input as bus-side request"
    [req1]
    (CE.sampleN 1 reqOut)

-- ** 2. First fetch fires (sentinel test) -----------------------

-- | Hold pcFetch=0 (the reset PC) for many cycles. The bridge
-- must fire the first transaction even though pcFetch numerically
-- equals the field 'mLastSentPc' /would/ contain if it weren't
-- sentinel-initialised. Asserts: stall=False is observed within
-- the test window, and the imemData matches the reply for PC=0.
case_first_fetch_fires :: Assertion
case_first_fetch_fires = do
  let n = 60
      reqs = P.replicate n (emptyReq{cbrPcFetch = 0})
      (replyTrace, _) = runBridge n reqs busReply
      committed = P.filter (\r -> P.not (cbrStall r)) replyTrace
  assertBool
    ("expected at least one stall=False cycle in " ++ show n ++ " cycles, got 0")
    (P.length committed >= 1)
  let firstReply = P.head committed
  assertEqual
    "imemData on first commit should be the reply for PC=0"
    (cbrImemData (busReply emptyReq{cbrPcFetch = 0}))
    (cbrImemData firstReply)

-- ** 3. PC advance — no stale-reply garbage ---------------------

-- | Drive PC=0 for 30 cycles, then PC=4 for 30 cycles. After the
-- PC change, the core must NOT see a stall=False reply with the
-- old PC=0 imemData; the next stall=False reply must carry the
-- imemData computed for PC=4.
case_pc_advance_no_stale_data :: Assertion
case_pc_advance_no_stale_data = do
  let n = 60
      reqs =
        P.replicate 30 (emptyReq{cbrPcFetch = 0})
          ++ P.replicate 30 (emptyReq{cbrPcFetch = 4})
      (replyTrace, _) = runBridge n reqs busReply
      -- For each cycle index, record (pcFetch, replied imemData).
      paired = P.zip [0 :: Int ..] (P.zip reqs replyTrace)
      stallFalseAfterChange =
        [ (i, cbrImemData (busReply r), cbrImemData rep)
        | (i, (r, rep)) <- paired
        , i >= 30
        , P.not (cbrStall rep)
        ]
  assertBool
    "expected at least one stall=False cycle after the PC=4 transition"
    (P.length stallFalseAfterChange >= 1)
  -- The first stall=False after PC change must carry the PC=4 reply,
  -- not a stale PC=0 reply. We don't know the exact cycle the
  -- bridge will land MDone on, just that whichever reply we see
  -- with stall=False must be the one for PC=4.
  let badStaleReplies =
        [ (i, expectedNew, gotImem)
        | (i, expectedNew, gotImem) <- stallFalseAfterChange
        , gotImem == cbrImemData (busReply emptyReq{cbrPcFetch = 0})
        , gotImem CP./= expectedNew
        ]
  assertBool
    ( "found stale PC=0 imemData on stall=False cycles after PC change: "
        ++ show badStaleReplies
    )
    (P.null badStaleReplies)

-- ** 4. Self-loop request keeps running -------------------------

-- | Hold pcFetch=8 constant for many cycles (simulating a @j .@
-- self-loop). The bridge must let the core commit on multiple
-- separated cycles — not just once and then deadlock with
-- stall=True forever.
case_self_loop_keeps_running :: Assertion
case_self_loop_keeps_running = do
  let n = 200
      reqs = P.replicate n (emptyReq{cbrPcFetch = 8})
      (replyTrace, _) = runBridge n reqs busReply
      stallFalseCycles =
        [i | (i, r) <- P.zip [0 :: Int ..] replyTrace, P.not (cbrStall r)]
  -- Need to see commit on more than one cycle. With the self-loop
  -- deadlock bug, only the very first MDone cycle (or none) shows
  -- stall=False; subsequent MIdle cycles have stall=True forever.
  -- A working bridge keeps stall=False sustained in MIdle (no new
  -- request live), so we should see *many* stall=False cycles.
  assertBool
    ( "expected sustained stall=False in self-loop (got "
        ++ show (P.length stallFalseCycles)
        ++ " stall=False cycles in "
        ++ show n
        ++ ")"
    )
    (P.length stallFalseCycles >= 50)

-- ** 5. Single SW: dBe!=0 on bus only briefly -------------------

-- | Core asserts dBe!=0 for one core-cycle window (one bridge
-- transaction's worth), then drops back to dBe=0. The bridge must
-- not hold dBe!=0 on the bus side past the end of that one bridge
-- transaction — otherwise downstream side-effecting slaves (UART,
-- SDRAM controller) commit the write multiple times.
case_store_drives_dBe_briefly :: Assertion
case_store_drives_dBe_briefly = do
  let n = 200
      -- 1 cycle of SW request, then sustained idle to give the
      -- bridge time to complete and quiesce.
      reqs =
        [emptyReq{cbrPcFetch = 0x100, cbrDBe = 0xF, cbrDWdata = 0xC0FFEE, cbrDAddr = 0x10000000}]
          ++ P.replicate (n P.- 1) (emptyReq{cbrPcFetch = 0x104})
      (_, busReqTrace) = runBridge n reqs busReply
      dBeAssertedCount = P.length [() | r <- busReqTrace, cbrDBe r CP./= 0]
  -- A correctly-fenced bridge holds dBe!=0 only across the active
  -- 'SDrive'/'SServe' phases — ~2-5 bus cycles for the BRAM-busy
  -- case modelled here. The multi-write bug surfaces as dBe!=0
  -- leaking through 'SDone' and 'SIdle' (sLatReq persistence) and
  -- through the next bridge transaction's dispatch window, padding
  -- the count to ~10-15 cycles before the next sLatReq update with
  -- dBe=0 finally lands. Threshold tuned to fail the unfenced
  -- bridge but pass the version that drives an empty CoreBusReq
  -- outside SDrive/SServe (mirroring 'SdramCdcBridge.slaveBus''s
  -- cs=False default).
  assertBool
    ( "expected dBe!=0 on bus side bounded to ≤ 6 cycles (got "
        ++ show dBeAssertedCount
        ++ ")"
    )
    (dBeAssertedCount < 6)

-- | Held SW request: the core asserts (PC=p, dBe=0xF, ...) for the
-- WHOLE test window, mimicking a real core that holds the X-stage
-- request until it sees stall=False (= one bridge MDone). The
-- bridge must fire EXACTLY ONE transaction for this single SW, not
-- one per cycle of held dBe!=0. Counts the number of distinct
-- "reqEdge" pulses on the bus side by tracking transitions of
-- 'reqOutB.cbrPcFetch' would be the same — easier proxy: count
-- transitions of 'cbrDBe' from 0 to non-zero (each non-zero burst
-- = one transaction's bus-side activation).
case_held_sw_fires_once :: Assertion
case_held_sw_fires_once = do
  let n = 200
      sw = emptyReq{cbrPcFetch = 0x100, cbrDBe = 0xF, cbrDWdata = 0xC0FFEE, cbrDAddr = 0x10000000}
      reqs = P.replicate n sw
      (_, busReqTrace) = runBridge n reqs busReply
      -- Count rising edges of (dBe != 0) on the bus side.
      paired = P.zip busReqTrace (P.tail busReqTrace P.++ [P.last busReqTrace])
      risingEdges = P.length [() | (cur, nxt) <- paired, cbrDBe cur == 0, cbrDBe nxt CP./= 0]
  assertEqual
    ( "expected exactly 1 dBe rising edge on bus for held SW (got "
        ++ show risingEdges
        ++ "; multi-fire indicates 'reqIsLive' returns True every cycle dBe!=0)"
    )
    1
    risingEdges

-- | Held SW: count master FSM 'MIdle → MBusy' transitions. Should
-- be exactly 1 (one bridge fire for the one held SW). The
-- multi-fire bug is when 'reqIsLive' returns True every cycle
-- @cbrDBe != 0@ — then the master re-fires on every MIdle re-entry
-- after MDone, even though the request hasn't actually changed.
case_held_sw_no_master_refire :: Assertion
case_held_sw_no_master_refire = do
  let n = 200
      sw = emptyReq{cbrPcFetch = 0x100, cbrDBe = 0xF, cbrDWdata = 0xC0FFEE, cbrDAddr = 0x10000000}
      reqs = P.replicate n sw
      (_, _, dbgMTrace, _) = runBridgeDbg n reqs busReply
      -- bit [1:0] of the master debug byte = mPhase. 0=MIdle, 1=MBusy, 2=MDone.
      phaseOf b = b CP..&. 0b11
      paired = P.zip dbgMTrace (P.drop 1 dbgMTrace)
      idleToBusyEdges =
        P.length [() | (cur, nxt) <- paired, phaseOf cur == 0, phaseOf nxt == 1]
  assertEqual
    ( "expected exactly 1 MIdle→MBusy transition for one held SW (got "
        ++ show idleToBusyEdges
        ++ "; multi-fire indicates 'reqIsLive' fires every cycle dBe!=0)"
    )
    1
    idleToBusyEdges

-- | When the slave's FSM is in 'SIdle' or 'SDone' (not actively
-- serving a transaction), the bus side of the bridge ('reqOutB')
-- must drive an empty CoreBusReq — particularly cbrDBe=0 — so that
-- side-effecting downstream slaves (UART, SDRAM controller) don't
-- see lingering 'dBe!=0' from the previous transaction's sLatReq.
-- The bug this catches: 'reqOutB = sLatReq' regardless of slave
-- phase makes the bus see dBe!=0 across SDone/SIdle, the bus's
-- 'uartAcceptedS' latch resets when its internal stall goes False,
-- and the JTAG-UART IP commits the same write 4-5 more times
-- before the next bridge transaction's sLatReq update finally
-- lands with dBe=0. (Direct silicon symptom: each CoreMark
-- character printed 5×.)
case_slave_drives_empty_in_idle :: Assertion
case_slave_drives_empty_in_idle = do
  let n = 200
      sw = emptyReq{cbrPcFetch = 0x100, cbrDBe = 0xF, cbrDWdata = 0xC0FFEE, cbrDAddr = 0x10000000}
      reqs = P.replicate n sw
      (_, busReqTrace, _, dbgSTrace) = runBridgeDbg n reqs busReply
      -- bit [1:0] of slave debug = sPhase. 0=SIdle, 1=SDrive,
      -- 2=SServe, 3=SDone.
      phaseOf b = b CP..&. 0b11
      bad =
        [ (i, P.show (phaseOf phaseB), P.show (cbrDBe req))
        | (i, (phaseB, req)) <- P.zip [0 :: Int ..] (P.zip dbgSTrace busReqTrace)
        , phaseOf phaseB == 0 P.|| phaseOf phaseB == 3 -- SIdle or SDone
        , cbrDBe req CP./= 0
        ]
  -- Allow the FIRST few cycles (boot, before slave has captured
  -- anything) to be in SIdle with dBe coming from sLatReq init
  -- which is also empty. So 'bad' should be empty entirely if the
  -- bridge's slave drives empty in SIdle/SDone.
  assertEqual
    ( "expected slave to drive dBe=0 in SIdle/SDone phases (got "
        ++ show (P.length bad)
        ++ " violations: "
        ++ show (P.take 5 bad)
        ++ "...)"
    )
    []
    bad

-- ** 9. imemReady announced one cycle before stall releases ----

-- | The bridge MUST present @cbrImemReady = True@ for at least one
-- cycle WHILE @cbrStall = True@ before the cycle it releases stall.
-- This "early-announce" lets the core's 'fValidTrackS' counter flip
-- to True before the IF/ID capture cycle, so the FIRST instruction
-- of every bridge round-trip enters the pipeline as a real retire
-- (not a bubble). Without it, the LUI at PC=0 is forever a bubble,
-- x11 stays at 0, and every subsequent SW commits to address 0
-- instead of the UART base — silicon symptom "every SW commits
-- to address 0" and the integration test
-- 'CdcSocIntegrationSpec.case_core_dAddr' fails.
case_imemready_announced_early :: Assertion
case_imemready_announced_early = do
  let n = 80
      reqs = P.replicate n (emptyReq{cbrPcFetch = 0})
      (replyTrace, _) = runBridge n reqs busReply
      -- Find the first cycle where stall=False is presented.
      firstStallFalse =
        P.head [i | (i, r) <- P.zip [0 :: Int ..] replyTrace, P.not (cbrStall r)]
      prevReply = replyTrace P.!! (firstStallFalse P.- 1)
  assertBool
    ( "expected imemReady=True on the cycle BEFORE first stall=False "
        ++ "(cycle "
        ++ show (firstStallFalse P.- 1)
        ++ ", got cbrStall="
        ++ show (cbrStall prevReply)
        ++ " cbrImemReady="
        ++ show (cbrImemReady prevReply)
        ++ ")"
    )
    (cbrStall prevReply P.&& cbrImemReady prevReply)
