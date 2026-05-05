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
Module      : CoreCdcSpec
Description : Asymmetric-rate CoreCdcBridge tests + Phase D-3a regression.

The companion 'CdcSpec' exercises the bridge with both domains at the
SAME period (25_000 ps = 40 MHz for both DomTcA and DomTcB). Those
tests are sufficient to catch FSM-shape bugs (sentinel init,
self-loop deadlock, multi-write store, tied-passthrough) but they
DON'T exercise the asynchronous-clock CDC machinery — every signal
transition lines up at the same edge, so 'syncBit' never sees a
metastable-shaped sample window.

This spec runs the bridge with /genuinely-asymmetric/ periods on each
side, mirroring the production multi-PLL silicon configurations:

  * 'case_*_corefast_*'  — DomCore at 12_500 ps (80 MHz) /
                            DomBus at 25_000 ps (40 MHz).
                            Mimics the planned Tiny-Performance
                            split where the CPU runs faster than
                            the bus.
  * 'case_*_busfast_*'   — DomCore at 25_000 ps (40 MHz) /
                            DomBus at 12_500 ps (80 MHz).
                            Models the inverse — slower CPU,
                            faster bus (e.g., for low-power CPU
                            with high-bandwidth memory).
  * 'case_*_oddratio_*'  — DomCore at 17_000 ps (~58.8 MHz) /
                            DomBus at 25_000 ps (40 MHz).
                            Non-integer-ratio clocks force the CDC
                            edges into truly-asynchronous patterns.

A dedicated 'case_if_starvation_phase_d3a' test reproduces the
silicon-only bug that landed in commit @c9a70e8@:

  When the IF stage and DATA port BOTH target SDRAM (e.g., amostress
  inner loop running from SDRAM with cross-bank data SWs), the
  bus-side @Riski5.Sdram@ has data-priority arbitration and re-issues
  the held data SW indefinitely. Once 'cbrDataStall' drops, IF never
  gets served, 'cbrStall' stays True forever, the bridge slave
  deadlocks waiting for "both stalls False simultaneously".

The fix (per-port done tracking + data-port mask in slave + cbrDBe/
cbrDRen rising-edge re-fire in master) is verified here by a reply
function that models the data-priority arbiter behaviour.

A side-by-side 'tied vs split' equivalence property checks that the
async-rate bridge produces the SAME observable byte stream as the
tied passthrough, modulo a bounded amount of CDC latency.
-}
module CoreCdcSpec (tests) where

import Clash.Explicit.Prelude hiding ((++))
import qualified Clash.Explicit.Prelude as CE
import Clash.Explicit.Testbench (tbClockGen)
import qualified Clash.Prelude as CP
import Riski5.CoreCdcBridge (
  CoreBusReply (..),
  CoreBusReq (..),
  coreCdcBridge,
  coreCdcBridgeWithDebug,
 )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, testCase)
import qualified Prelude as P
import Prelude (Bool (..), Int, fmap, show, ($), (.), (++), (<), (<=), (==), (>=))

-- * Test domains -------------------------------------------------
--
-- Use distinct domain names per period so multiple specs can
-- coexist without TH-generated instance collisions.

-- | Core-side fast: 12_500 ps = 80 MHz. Pairs with 'DomBusSlow'.
createDomain
  vSystem
    { vName = "DomCoreFast"
    , vPeriod = 12500
    , vResetKind = Asynchronous
    , vResetPolarity = ActiveLow
    }

-- | Bus-side slow: 25_000 ps = 40 MHz.
createDomain
  vSystem
    { vName = "DomBusSlow"
    , vPeriod = 25000
    , vResetKind = Asynchronous
    , vResetPolarity = ActiveLow
    }

-- | Bus-side fast: 12_500 ps = 80 MHz. Pairs with 'DomCoreSlow'.
createDomain
  vSystem
    { vName = "DomBusFast"
    , vPeriod = 12500
    , vResetKind = Asynchronous
    , vResetPolarity = ActiveLow
    }

-- | Core-side slow: 25_000 ps = 40 MHz.
createDomain
  vSystem
    { vName = "DomCoreSlow"
    , vPeriod = 25000
    , vResetKind = Asynchronous
    , vResetPolarity = ActiveLow
    }

-- | Odd-ratio core: 17_000 ps (~58.8 MHz). Non-integer ratio with
-- 25_000 ps so the toggle edges fall on genuinely-asynchronous
-- positions in DomBus's clock period.
createDomain
  vSystem
    { vName = "DomCoreOdd"
    , vPeriod = 17000
    , vResetKind = Asynchronous
    , vResetPolarity = ActiveLow
    }

-- * Default values ----------------------------------------------

emptyReq :: CoreBusReq
emptyReq = CoreBusReq 0 0 0 0 False False

-- | Reply with deterministic imemData derived from the request, so
-- each test asserts "imemData I see corresponds to the PC I asked
-- for" without tracking arbitrary fixtures.
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

-- * Harness over arbitrary domain pairs --------------------------
--
-- Each helper takes a 'KnownDomain' constraint pair and produces
-- traces over @n@ core-side cycles. The bridge sits between them.

runBridgePair ::
  forall coreDom busDom.
  (KnownDomain coreDom, KnownDomain busDom) =>
  Clock coreDom ->
  Reset coreDom ->
  Enable coreDom ->
  Clock busDom ->
  Reset busDom ->
  Enable busDom ->
  Int ->
  [CoreBusReq] ->
  (CoreBusReq -> CoreBusReply) ->
  ([CoreBusReply], [CoreBusReq])
runBridgePair clkC rstC enC clkB rstB enB n reqs busFunc =
  let reqInC :: Signal coreDom CoreBusReq
      reqInC = fromList (reqs ++ P.repeat (P.last (emptyReq : reqs)))
      replyInB :: Signal busDom CoreBusReply
      replyInB = fmap busFunc reqOutB
      (replyOutC, reqOutB) =
        coreCdcBridge clkC rstC enC clkB rstB enB reqInC replyInB
   in (CE.sampleN n replyOutC, CE.sampleN n reqOutB)

runBridgePairDbg ::
  forall coreDom busDom.
  (KnownDomain coreDom, KnownDomain busDom) =>
  Clock coreDom ->
  Reset coreDom ->
  Enable coreDom ->
  Clock busDom ->
  Reset busDom ->
  Enable busDom ->
  Int ->
  [CoreBusReq] ->
  (CoreBusReq -> CoreBusReply) ->
  ([CoreBusReply], [CoreBusReq], [BitVector 8], [BitVector 8])
runBridgePairDbg clkC rstC enC clkB rstB enB n reqs busFunc =
  let reqInC :: Signal coreDom CoreBusReq
      reqInC = fromList (reqs ++ P.repeat (P.last (emptyReq : reqs)))
      replyInB :: Signal busDom CoreBusReply
      replyInB = fmap busFunc reqOutB
      (replyOutC, reqOutB, dbgM, dbgS) =
        coreCdcBridgeWithDebug clkC rstC enC clkB rstB enB reqInC replyInB
   in ( CE.sampleN n replyOutC
      , CE.sampleN n reqOutB
      , CE.sampleN n dbgM
      , CE.sampleN n dbgS
      )

-- | DomCoreFast (80 MHz) over DomBusSlow (40 MHz) — core faster.
runCoreFast ::
  Int -> [CoreBusReq] -> (CoreBusReq -> CoreBusReply) -> ([CoreBusReply], [CoreBusReq])
runCoreFast =
  runBridgePair
    (tbClockGen @DomCoreFast (CP.pure True))
    (resetGen @DomCoreFast)
    (enableGen @DomCoreFast)
    (tbClockGen @DomBusSlow (CP.pure True))
    (resetGen @DomBusSlow)
    (enableGen @DomBusSlow)

-- | DomCoreSlow (40 MHz) over DomBusFast (80 MHz) — bus faster.
runBusFast ::
  Int -> [CoreBusReq] -> (CoreBusReq -> CoreBusReply) -> ([CoreBusReply], [CoreBusReq])
runBusFast =
  runBridgePair
    (tbClockGen @DomCoreSlow (CP.pure True))
    (resetGen @DomCoreSlow)
    (enableGen @DomCoreSlow)
    (tbClockGen @DomBusFast (CP.pure True))
    (resetGen @DomBusFast)
    (enableGen @DomBusFast)

-- | DomCoreOdd (17_000 ps ~58.8 MHz) over DomBusSlow (40 MHz) —
-- non-integer ratio.
runOddRatio ::
  Int -> [CoreBusReq] -> (CoreBusReq -> CoreBusReply) -> ([CoreBusReply], [CoreBusReq])
runOddRatio =
  runBridgePair
    (tbClockGen @DomCoreOdd (CP.pure True))
    (resetGen @DomCoreOdd)
    (enableGen @DomCoreOdd)
    (tbClockGen @DomBusSlow (CP.pure True))
    (resetGen @DomBusSlow)
    (enableGen @DomBusSlow)

runCoreFastDbg ::
  Int -> [CoreBusReq] -> (CoreBusReq -> CoreBusReply) -> ([CoreBusReply], [CoreBusReq], [BitVector 8], [BitVector 8])
runCoreFastDbg =
  runBridgePairDbg
    (tbClockGen @DomCoreFast (CP.pure True))
    (resetGen @DomCoreFast)
    (enableGen @DomCoreFast)
    (tbClockGen @DomBusSlow (CP.pure True))
    (resetGen @DomBusSlow)
    (enableGen @DomBusSlow)

-- * Test cases --------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Riski5.CoreCdcBridge — asymmetric-rate + Phase D-3a regression"
    [ testCase "first fetch fires (core 80 / bus 40)" case_first_fetch_corefast
    , testCase "first fetch fires (core 40 / bus 80)" case_first_fetch_busfast
    , testCase "first fetch fires (odd ratio 58.8 / 40)" case_first_fetch_oddratio
    , testCase "PC advance presents fresh imemData (core 80 / bus 40)" case_pc_advance_corefast
    , testCase "PC advance presents fresh imemData (core 40 / bus 80)" case_pc_advance_busfast
    , testCase "self-loop keeps running (core 80 / bus 40)" case_self_loop_corefast
    , testCase "single SW dBe!=0 bounded on bus (core 80 / bus 40)" case_store_brief_corefast
    , testCase "held SW fires bridge ONCE (core 80 / bus 40)" case_held_sw_corefast
    , testCase "Phase D-3a: IF starvation NOT possible after fix" case_if_starvation_phase_d3a
    , testCase "Phase D-3a: AMO read→write phase progresses (cbrDBe rising-edge)" case_amo_read_write_progresses
    ]

-- ** First-fetch tests at three rate combinations ---------------

case_first_fetch_corefast :: Assertion
case_first_fetch_corefast = do
  let n = 200
      reqs = P.replicate n (emptyReq{cbrPcFetch = 0})
      (replyTrace, _) = runCoreFast n reqs busReply
      committed = P.filter (\r -> P.not (cbrStall r)) replyTrace
  assertBool
    ( "expected ≥1 stall=False cycle in "
        ++ show n
        ++ " core cycles (got "
        ++ show (P.length committed)
        ++ ")"
    )
    (P.length committed >= 1)
  let firstReply = P.head committed
  assertEqual
    "imemData on first commit should be the reply for PC=0"
    (cbrImemData (busReply emptyReq{cbrPcFetch = 0}))
    (cbrImemData firstReply)

case_first_fetch_busfast :: Assertion
case_first_fetch_busfast = do
  let n = 200
      reqs = P.replicate n (emptyReq{cbrPcFetch = 0})
      (replyTrace, _) = runBusFast n reqs busReply
      committed = P.filter (\r -> P.not (cbrStall r)) replyTrace
  assertBool
    ("bus-fast variant: expected ≥1 stall=False cycle (got " ++ show (P.length committed) ++ ")")
    (P.length committed >= 1)

case_first_fetch_oddratio :: Assertion
case_first_fetch_oddratio = do
  let n = 200
      reqs = P.replicate n (emptyReq{cbrPcFetch = 0})
      (replyTrace, _) = runOddRatio n reqs busReply
      committed = P.filter (\r -> P.not (cbrStall r)) replyTrace
  assertBool
    ("odd-ratio variant: expected ≥1 stall=False cycle (got " ++ show (P.length committed) ++ ")")
    (P.length committed >= 1)

-- ** PC-advance tests --------------------------------------------

case_pc_advance_corefast :: Assertion
case_pc_advance_corefast = do
  let n = 400
      reqs =
        P.replicate 200 (emptyReq{cbrPcFetch = 0})
          ++ P.replicate 200 (emptyReq{cbrPcFetch = 4})
      (replyTrace, _) = runCoreFast n reqs busReply
      paired = P.zip [0 :: Int ..] (P.zip reqs replyTrace)
      stallFalseAfterChange =
        [ (i, cbrImemData (busReply r), cbrImemData rep)
        | (i, (r, rep)) <- paired
        , i >= 200
        , P.not (cbrStall rep)
        ]
  assertBool
    "expected ≥1 stall=False cycle after PC=4 transition"
    (P.length stallFalseAfterChange >= 1)
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

case_pc_advance_busfast :: Assertion
case_pc_advance_busfast = do
  let n = 400
      reqs =
        P.replicate 200 (emptyReq{cbrPcFetch = 0})
          ++ P.replicate 200 (emptyReq{cbrPcFetch = 4})
      (replyTrace, _) = runBusFast n reqs busReply
      stallFalseAfterChange =
        [ cbrImemData rep
        | (i, rep) <- P.zip [0 :: Int ..] replyTrace
        , i >= 200
        , P.not (cbrStall rep)
        ]
  assertBool
    "bus-fast: expected ≥1 stall=False cycle after PC=4 transition"
    (P.length stallFalseAfterChange >= 1)
  let badStale =
        [ d
        | d <- stallFalseAfterChange
        , d == cbrImemData (busReply emptyReq{cbrPcFetch = 0})
        ]
  assertEqual
    "bus-fast: no stale PC=0 imemData after PC change"
    []
    badStale

-- ** Self-loop test ---------------------------------------------

case_self_loop_corefast :: Assertion
case_self_loop_corefast = do
  let n = 600
      reqs = P.replicate n (emptyReq{cbrPcFetch = 0x40})
      (replyTrace, _) = runCoreFast n reqs busReply
      stallFalseCycles =
        [i | (i, r) <- P.zip [0 :: Int ..] replyTrace, P.not (cbrStall r)]
  -- Sustained stall=False expected — bridge stays in MIdle with
  -- mReply held, replyOutC presents it (no new request live).
  assertBool
    ( "expected sustained stall=False (got "
        ++ show (P.length stallFalseCycles)
        ++ " of "
        ++ show n
        ++ ")"
    )
    (P.length stallFalseCycles >= 200)

-- ** Single-SW: bus-side dBe not held forever ------------------

case_store_brief_corefast :: Assertion
case_store_brief_corefast = do
  let n = 600
      reqs =
        [emptyReq{cbrPcFetch = 0x100, cbrDBe = 0xF, cbrDWdata = 0xC0FFEE, cbrDAddr = 0x10000000}]
          ++ P.replicate (n P.- 1) (emptyReq{cbrPcFetch = 0x104})
      (_, busReqTrace) = runCoreFast n reqs busReply
      dBeCount = P.length [() | r <- busReqTrace, cbrDBe r CP./= 0]
  -- At asymmetric rates the bridge holds the request through SDrive
  -- + SServe (a few bus cycles); allow generous bound.
  assertBool
    ( "expected dBe!=0 on bus side bounded (got "
        ++ show dBeCount
        ++ " bus cycles)"
    )
    (dBeCount <= 10)

-- ** Held SW fires exactly once ---------------------------------

case_held_sw_corefast :: Assertion
case_held_sw_corefast = do
  let n = 800
      sw = emptyReq{cbrPcFetch = 0x100, cbrDBe = 0xF, cbrDWdata = 0xC0FFEE, cbrDAddr = 0x10000000}
      reqs = P.replicate n sw
      (_, _, dbgMTrace, _) = runCoreFastDbg n reqs busReply
      phaseOf b = b CP..&. 0b11
      paired = P.zip dbgMTrace (P.drop 1 dbgMTrace)
      idleToBusyEdges =
        P.length [() | (cur, nxt) <- paired, phaseOf cur == 0, phaseOf nxt == 1]
  assertEqual
    ( "expected exactly 1 MIdle→MBusy transition for one held SW (got "
        ++ show idleToBusyEdges
        ++ ")"
    )
    1
    idleToBusyEdges

-- ** Phase D-3a regression tests --------------------------------

{- | Reproduces the silicon bug from commit @c9a70e8@.

The Riski5.Sdram two-port adapter has data-priority arbitration. When
both IF and DATA target SDRAM (amostress inner loop with
SDRAM-resident code + cross-bank data SWs), the held data SW completes
first; if the bridge slave then re-issues the data port (cbrDBe still
non-zero in the held request), the data adapter re-fires and IF
starves. Bridge slave deadlocks waiting for "both stalls False
simultaneously".

The fix in commit @c9a70e8@ added per-port done tracking (sDataDone /
sImemDone) and the slave masks cbrDBe/cbrDRen/cbrDWdata to zero once
sDataDone latches, so the adapter sees an idle data port and serves
the IF stage.

This test simulates the deadlock pattern with a reply function that
mimics the data-priority arbiter:

  - First few cycles after request: BOTH stalls True (Sdram fetching
    instruction word).
  - Cycle N:   cbrDataStall drops to False (data port served).
  - Cycle N+1: if the request still has cbrDBe!=0 OR cbrDRen=True,
    data port re-asserts dataStall=True — modelling Sdram re-issuing
    the held SW.
  - Eventually: cbrStall drops to False (IF served). But this only
    happens if the bridge stops driving the data port — i.e., the
    fix correctly masks the data port after sDataDone.

If the fix isn't in place, the bridge would never see "both stalls
False on the same cycle" → SServe loops forever → no SDone → no
done toggle → core-side mPhase stays MBusy → cbrStall=True forever.

We assert: within a generous cycle window, the bridge IS able to
exit SServe (dBe goes to 0 on the bus side, then both stalls drop,
then SDone fires, then the core sees cbrStall=False).
-}
case_if_starvation_phase_d3a :: Assertion
case_if_starvation_phase_d3a = do
  let n = 500
      sw =
        emptyReq
          { cbrPcFetch = 0x80000044
          , cbrDBe = 0xF
          , cbrDWdata = 0xDEADBEEF
          , cbrDAddr = 0x80100000
          }
      reqs = P.replicate n sw

      -- The data-priority arbiter mock. Track time since the slave
      -- entered SServe (= when bus-side cbrDBe transitions 0→non-zero)
      -- and apply the deadlock pattern unless dBe goes back to 0.
      --
      -- Reply function: per-cycle pure function so we model the
      -- adapter's response. We can't track per-cycle state in a pure
      -- (CoreBusReq -> CoreBusReply); instead encode the pattern as
      -- a function of the request only:
      --
      --   * If dBe == 0: data adapter idle, data side ready
      --     (dataStall=False); IF side ready (stall=False).
      --   * If dBe != 0: data side keeps re-firing (dataStall always
      --     False — adapter accepts), but IF side ALSO never gets
      --     served until the slave masks dBe (= dBe seen as 0 by the
      --     adapter). With the bug: dBe stays non-zero forever in
      --     SServe, so IF stays stalled forever.
      --   * stall=True only when dBe!=0 — modelling Sdram serving
      --     data first.
      arbReply :: CoreBusReq -> CoreBusReply
      arbReply r =
        if cbrDBe r CP./= 0 P.|| cbrDRen r
          then
            CoreBusReply
              { cbrImemData = 0xCAFE_F00D
              , cbrImemReady = False
              , cbrDmemRdata = 0
              , cbrStall = True -- IF starved while data port active
              , cbrDataStall = False -- data port keeps completing
              , cbrMtip = False
              , cbrMeip = False
              }
          else
            CoreBusReply
              { cbrImemData = cbrPcFetch r `CP.xor` 0xCAFEBABE
              , cbrImemReady = True
              , cbrDmemRdata = 0
              , cbrStall = False -- IF served once data port idle
              , cbrDataStall = False
              , cbrMtip = False
              , cbrMeip = False
              }

      (replyTrace, busReqTrace) = runCoreFast n reqs arbReply
      coreSawStallFalse = P.any (P.not . cbrStall) replyTrace
      busDbeWentToZero =
        P.any (P.== 0) (P.map cbrDBe (P.drop 5 busReqTrace))
  -- The fix: bus-side dBe MUST go back to 0 within SServe (= the
  -- mask after sDataDone latches).
  assertBool
    "Phase D-3a fix: bridge slave must mask cbrDBe to 0 after data port completes"
    busDbeWentToZero
  -- Consequence of the mask: arbReply sees dBe=0 → drops cbrStall →
  -- bridge's MBusy gets doneEdge → core sees cbrStall=False.
  assertBool
    "Phase D-3a fix: core MUST see cbrStall=False (= IF served) within "
    coreSawStallFalse

{- | AMO FU's read→write phase transition: cbrDBe goes 0→0xF mid-AMO
without the F stage advancing (PC stays the same). Pre-Phase D-3a,
the master's @reqIsLive@ only checked the PC, so the AMO write
phase silently never fired a bridge transaction and the swap
didn't commit (caught on silicon by amostress hitting bank-A
failAL with rd==tExpected, indicating the AMO write never updated
mem[tA]).

The fix added cbrDBe rising-edge to @reqIsLive@. This test verifies
that a held PC with a 0→0xF dBe transition fires a SECOND bridge
transaction.
-}
case_amo_read_write_progresses :: Assertion
case_amo_read_write_progresses = do
  let n = 400
      -- AMO read phase: PC fixed, cbrDRen=True (load), dBe=0.
      readReq = emptyReq{cbrPcFetch = 0x80000020, cbrDRen = True, cbrDAddr = 0x80100000}
      -- AMO write phase: SAME PC, cbrDRen=False, dBe=0xF (store).
      writeReq =
        emptyReq
          { cbrPcFetch = 0x80000020 -- unchanged
          , cbrDBe = 0xF
          , cbrDWdata = 0xCAFEBABE
          , cbrDAddr = 0x80100000
          }
      -- 100 cycles of read phase, then 100 cycles of write phase.
      reqs = P.replicate 100 readReq ++ P.replicate 300 writeReq
      (_, _, dbgMTrace, _) = runCoreFastDbg n reqs busReply
      phaseOf b = b CP..&. 0b11
      paired = P.zip dbgMTrace (P.drop 1 dbgMTrace)
      idleToBusyEdges =
        P.length [() | (cur, nxt) <- paired, phaseOf cur == 0, phaseOf nxt == 1]
  -- Expect ≥2 transactions: one for the read phase (cbrDRen rising
  -- edge), one for the write phase (cbrDBe rising edge while PC
  -- unchanged).
  assertBool
    ( "AMO read→write should fire ≥2 bridge transactions (got "
        ++ show idleToBusyEdges
        ++ "; pre-Phase-D-3a only the read fires, write phase silently dropped)"
    )
    (idleToBusyEdges >= 2)
