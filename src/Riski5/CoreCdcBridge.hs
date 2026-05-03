-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoStarIsType #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Riski5.CoreCdcBridge
Description : Toggle-handshake CDC bridge between DomCore and DomBus.

Sits between the RISC-V core (which moves to DomCore in the
multi-PLL split) and the rest of the SoC (DomBus). The core has
two memory interfaces — instruction fetch and data load/store —
but they share unified stall semantics: when the data port is
busy, the fetch port stalls anyway. So a single combined toggle
on a 'CoreBusReq'/'CoreBusReply' pair is sufficient.

This bridge is structurally identical to 'Riski5.SdramCdcBridge':
toggle handshake with 2-FF synchronisers, quasi-static held
payload, edge-detect on the destination side. The only difference
is the payload shape and the master-detects-new-request rule (the
core bus signals don't have a single "cs" strobe; instead any
change in @cbrPcFetch@ or assertion of @cbrDRen@ / @cbrDBe ≠ 0@
is treated as a new request).

For the initial multi-PLL landing where DomCore == DomBus
electrically, use 'coreCdcBridgeTied' which degenerates to a
direct wire — zero cycle latency, no FSM overhead.
-}
module Riski5.CoreCdcBridge (
  CoreBusReq (..),
  CoreBusReply (..),
  coreCdcBridge,
  coreCdcBridgeTied,
) where

import Clash.Explicit.Prelude hiding (not, (&&), (||))
import GHC.Generics (Generic)
import Prelude (not, (&&), (||))
import qualified Prelude as P
import Riski5.Cdc (edgeDetect, syncBit, syncBitVector)

{- | Combined memory-interface request from the core to the bus.
Instruction fetch (@cbrPcFetch@) and data port (@cbrDAddr@,
@cbrDWdata@, @cbrDBe@, @cbrDRen@) are bundled so a single CDC
transaction carries both. The bus side replies with a matching
'CoreBusReply' carrying both the fetched word and the data-port
read result + stall flags.
-}
data CoreBusReq = CoreBusReq
  { cbrPcFetch :: BitVector 32
  , cbrDAddr :: BitVector 32
  , cbrDWdata :: BitVector 32
  , cbrDBe :: BitVector 4
  , cbrDRen :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

data CoreBusReply = CoreBusReply
  { cbrImemData :: BitVector 32
  , cbrImemReady :: Bool
  , cbrDmemRdata :: BitVector 32
  , cbrStall :: Bool
  , cbrDataStall :: Bool
  , cbrMtip :: Bool
  , cbrMeip :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

defaultReply :: CoreBusReply
defaultReply =
  CoreBusReply
    { cbrImemData = 0
    , cbrImemReady = False
    , cbrDmemRdata = 0
    , cbrStall = True
    , cbrDataStall = True
    , cbrMtip = False
    , cbrMeip = False
    }

-- * Master FSM (DomCore side)

data MasterPhase = MIdle | MBusy | MDone
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

data MasterState = MasterState
  { mPhase :: MasterPhase
  , mLastSentPc :: BitVector 32
  , mReqToggle :: Bool
  , mReply :: CoreBusReply
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

masterInit :: MasterState
-- mLastSentPc initialised to 0xFFFF_FFFF (a sentinel address the
-- core will never execute from — outside any mapped region). The
-- reqIsLive heuristic fires when pcFetch differs from mLastSentPc,
-- so this sentinel guarantees the FIRST fetch (PC=reset_pc=0) is
-- treated as a fresh request and crosses the bridge. Without this,
-- both PC and mLastSentPc start at 0 → reqIsLive returns False →
-- bridge never fires → core deadlocks waiting for fetch reply.
masterInit = MasterState MIdle 0xFFFF_FFFF False defaultReply

-- * Slave FSM (DomBus side)

-- | Slave phases. The 'SDrive' phase exists so the bus has at least
-- one full cycle to register the new 'sLatReq' before we sample its
-- reply. The bus's 'imemReadyS' is constant 'True' for the BRAM-only
-- fetch path (CoreMark / Linux baseline), so the wait condition
-- 'not stall && not dataStall' is satisfied immediately on entering
-- 'SServe'; without 'SDrive' we would capture @blockRam@'s output
-- from the PREVIOUS request's pcFetch (the 1-cycle sync-read latency
-- means BRAM[newPC] only appears one cycle after the addr changes).
-- The data path's 'bramReadyS' already accounts for the 1-cycle BRAM
-- read latency on its own, so this only adds 1 cycle of overhead
-- there too.
data SlavePhase = SIdle | SDrive | SServe | SDone
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

data SlaveState = SlaveState
  { sPhase :: SlavePhase
  , sLatReq :: CoreBusReq
  , sDoneToggle :: Bool
  , sCapReply :: CoreBusReply
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

slaveInit :: SlaveState
slaveInit =
  SlaveState
    { sPhase = SIdle
    , sLatReq = CoreBusReq 0 0 0 0 False
    , sDoneToggle = False
    , sCapReply = defaultReply
    }

-- * Bridge

{- | CDC bridge between DomCore-side core and DomBus-side SoC.
Toggles per request, captures reply, releases stall.

Note: the bridge inserts a few cycles of CDC latency per
transaction. This means in non-tied mode the core experiences
slightly higher fetch+memory latency than single-domain — typical
for any CDC-bridged CPU. For initial multi-PLL bring-up where the
two domains run at the same rate, prefer 'coreCdcBridgeTied'
which has zero overhead.
-}
coreCdcBridge ::
  forall coreDom busDom.
  (KnownDomain coreDom, KnownDomain busDom) =>
  Clock coreDom ->
  Reset coreDom ->
  Enable coreDom ->
  Clock busDom ->
  Reset busDom ->
  Enable busDom ->
  -- | Core-side request bus.
  Signal coreDom CoreBusReq ->
  -- | Bus-side reply (from socBus).
  Signal busDom CoreBusReply ->
  -- | (core-side reply, bus-side request).
  ( Signal coreDom CoreBusReply
  , Signal busDom CoreBusReq
  )
coreCdcBridge clkC rstC enC clkB rstB enB reqInC replyInB =
  (replyOutC, reqOutB)
 where
  reqToggleC = mReqToggle <$> masterStateC
  reqToggleB = syncBit clkC clkB rstB enB reqToggleC
  reqEdgeB = edgeDetect clkB rstB enB reqToggleB

  doneToggleB = sDoneToggle <$> slaveStateB
  doneToggleC = syncBit clkB clkC rstC enC doneToggleB
  doneEdgeC = edgeDetect clkC rstC enC doneToggleC

  -- Captured reply crosses Bus→Core as a quasi-static bus.
  capReplyB = sCapReply <$> slaveStateB
  capReplyBundleB = packReply <$> capReplyB
  capReplyBundleC = syncBitVector clkB clkC rstC enC capReplyBundleB
  capReplyC = unpackReply <$> capReplyBundleC

  -- Latched core request crosses Core→Bus quasi-static.
  latReqBundleC = packReq <$> reqInC
  latReqBundleB = syncBitVector clkC clkB rstB enB latReqBundleC
  latReqB = unpackReq <$> latReqBundleB

  masterStateC :: Signal coreDom MasterState
  masterStateC =
    register clkC rstC enC masterInit $
      masterStep <$> masterStateC <*> reqInC <*> doneEdgeC <*> capReplyC

  slaveStateB :: Signal busDom SlaveState
  slaveStateB =
    register clkB rstB enB slaveInit $
      slaveStep <$> slaveStateB <*> reqEdgeB <*> latReqB <*> replyInB

  replyOutC = mReply <$> masterStateC

  reqOutB = sLatReq <$> slaveStateB

masterStep ::
  MasterState ->
  CoreBusReq ->
  Bool -> -- doneEdge
  CoreBusReply ->
  MasterState
masterStep st@MasterState{..} req doneEdge capR =
  case mPhase of
    MIdle
      | reqIsLive req mLastSentPc ->
          st
            { mPhase = MBusy
            , mLastSentPc = cbrPcFetch req
            , mReqToggle = not mReqToggle
            }
      | otherwise -> st
    MBusy
      | doneEdge -> st{mPhase = MDone, mReply = capR}
      | otherwise -> st
    -- mReply is restored to 'defaultReply' (stall=True, imemReady=
    -- False) so the core sees stall asserted again as soon as the
    -- one-cycle MDone reply pulse passes. Without this, mReply
    -- stays at the last 'capR' (stall=False) into MIdle, the core
    -- treats the next pcFetch as already-served, and consumes the
    -- previous request's instruction at every subsequent PC until
    -- the bridge round-trip catches up — a silent garbage-fetch
    -- loop that surfaces as zero UART output on silicon.
    MDone -> st{mPhase = MIdle, mReply = defaultReply}

-- | Treat a request as a "new request" if PC has changed (for
-- fetch) or if the data port is asserted (for load/store). This
-- is a conservative heuristic; the bus-side just services whatever
-- it receives.
reqIsLive :: CoreBusReq -> BitVector 32 -> Bool
reqIsLive req lastPc =
  cbrPcFetch req P./= lastPc || cbrDRen req || cbrDBe req P./= 0

slaveStep ::
  SlaveState ->
  Bool -> -- reqEdge
  CoreBusReq ->
  CoreBusReply ->
  SlaveState
slaveStep st@SlaveState{..} reqEdge latReq reply =
  case sPhase of
    SIdle
      | reqEdge -> st{sPhase = SDrive, sLatReq = latReq}
      | otherwise -> st
    -- One settle cycle after sLatReq updates so the bus's slave
    -- responses (notably blockRam-backed imemDataBramS, which has a
    -- 1-cycle sync-read latency) reflect the new pcFetch / dAddr
    -- before we capture them. See note on 'SlavePhase'.
    SDrive -> st{sPhase = SServe}
    SServe
      -- Wait for the bus to indicate the request is fully serviced.
      -- For fetch+data, both stalls must be deasserted.
      | not (cbrStall reply) && not (cbrDataStall reply) ->
          st{sPhase = SDone, sCapReply = reply}
      | otherwise -> st
    SDone -> st{sPhase = SIdle, sDoneToggle = not sDoneToggle}

-- * Packing helpers

packReq :: CoreBusReq -> BitVector 101
packReq CoreBusReq{..} =
  pack (cbrPcFetch, cbrDAddr, cbrDWdata, cbrDBe, cbrDRen)

unpackReq :: BitVector 101 -> CoreBusReq
unpackReq bv =
  let (pc, da, dw, be, rd) = unpack bv
   in CoreBusReq pc da dw be rd

packReply :: CoreBusReply -> BitVector 69
packReply CoreBusReply{..} =
  pack (cbrImemData, cbrImemReady, cbrDmemRdata, cbrStall, cbrDataStall, cbrMtip, cbrMeip)

unpackReply :: BitVector 69 -> CoreBusReply
unpackReply bv =
  let (im, ir, dm, ds, dst, mt, me) = unpack bv
   in CoreBusReply im ir dm ds dst mt me

-- * Tied-domains passthrough

{- | Direct-wire bridge for the case when DomCore == DomBus
electrically (the existing single-domain build and most sim
helpers). Compile-time gated by domain equality so a caller
can't accidentally tie genuinely different clocks.
-}
coreCdcBridgeTied ::
  forall dom.
  (KnownDomain dom) =>
  Signal dom CoreBusReq ->
  Signal dom CoreBusReply ->
  (Signal dom CoreBusReply, Signal dom CoreBusReq)
coreCdcBridgeTied reqIn replyIn = (replyIn, reqIn)
