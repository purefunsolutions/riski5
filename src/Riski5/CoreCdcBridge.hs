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
  coreCdcBridgeWithDebug,
  coreCdcBridgeWithDebugWide,
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
  let (replyOutC, reqOutB, _, _, _, _) =
        coreCdcBridgeWithDebugWide clkC rstC enC clkB rstB enB reqInC replyInB
   in (replyOutC, reqOutB)

{- | Diagnostic variant of 'coreCdcBridge' that also returns 8-bit
debug bytes for the master (DomCore) and slave (DomBus) FSMs.
Bit layout in each byte:

@
  master debug (DomCore):
    [1:0] mPhase             (0=MIdle, 1=MBusy, 2=MDone)
    [2]   mReqToggle         (toggles each MIdle→MBusy)
    [3]   doneToggleC        (synced sDoneToggle)
    [4]   doneEdgeC          (1-cycle pulse on doneToggleC change)
    [5]   reqIsLive(reqInC)  (would-fire predicate this cycle)
    [7:6] cbrPcFetch[1:0]    (low 2 bits of core's pcFetch — useful
                              to see if PC is advancing)

  slave debug (DomBus):
    [1:0] sPhase             (0=SIdle, 1=SDrive, 2=SServe, 3=SDone)
    [2]   sDoneToggle        (toggles each SDone→SIdle)
    [3]   reqToggleB         (synced mReqToggle)
    [4]   reqEdgeB           (1-cycle pulse on reqToggleB change)
    [5]   replyInB.cbrStall  (bus's stall signal the slave waits on)
    [6]   replyInB.cbrDataStall
    [7]   sLatReq.cbrPcFetch[0] (so we can tell if sLatReq updated)
@

The debug bytes are intended for an @altsource_probe@ on each
domain so @quartus_stp@ can sample them via JTAG and pinpoint
which FSM phase the bridge gets stuck in.
-}
coreCdcBridgeWithDebug ::
  forall coreDom busDom.
  (KnownDomain coreDom, KnownDomain busDom) =>
  Clock coreDom ->
  Reset coreDom ->
  Enable coreDom ->
  Clock busDom ->
  Reset busDom ->
  Enable busDom ->
  Signal coreDom CoreBusReq ->
  Signal busDom CoreBusReply ->
  ( Signal coreDom CoreBusReply
  , Signal busDom CoreBusReq
  , Signal coreDom (BitVector 8)
  , Signal busDom (BitVector 8)
  )
coreCdcBridgeWithDebug clkC rstC enC clkB rstB enB reqInC replyInB =
  let (replyOutC, reqOutB, dbgM, dbgS, _, _) =
        coreCdcBridgeWithDebugWide clkC rstC enC clkB rstB enB reqInC replyInB
   in (replyOutC, reqOutB, dbgM, dbgS)

{- | Diagnostic variant that ALSO returns 32-bit @mLastSentPc@ (master,
DomCore) and 32-bit @sLatReq.cbrPcFetch@ (slave, DomBus) so silicon
can sample which PCs the bridge is actually firing for, not just the
phase / toggle bits in 'coreCdcBridgeWithDebug'. The 8-bit packed
debug bytes only carry 2 bits of pcFetch each — enough to verify
"PC is moving" but not "PC is moving to the right addresses". The
wide PC probes pinpoint master-vs-slave divergence (master fires
for PC=0x40 but slave latches PC=0x10 — bit-skew bug; both agree but
neither advances — core stuck before bridge).
-}
coreCdcBridgeWithDebugWide ::
  forall coreDom busDom.
  (KnownDomain coreDom, KnownDomain busDom) =>
  Clock coreDom ->
  Reset coreDom ->
  Enable coreDom ->
  Clock busDom ->
  Reset busDom ->
  Enable busDom ->
  Signal coreDom CoreBusReq ->
  Signal busDom CoreBusReply ->
  ( Signal coreDom CoreBusReply
  , Signal busDom CoreBusReq
  , Signal coreDom (BitVector 8)
  , Signal busDom (BitVector 8)
  , Signal coreDom (BitVector 32)
  , Signal busDom (BitVector 32)
  )
coreCdcBridgeWithDebugWide clkC rstC enC clkB rstB enB reqInC replyInB =
  (replyOutC, reqOutB, dbgMasterC, dbgSlaveB, dbgMasterLastPcC, dbgSlaveLatPcB)
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

  -- The reply we present to the core is computed combinationally
  -- from the master state + the current core request + the
  -- in-flight reply payload. Three scenarios force the per-cycle
  -- decision:
  --
  --   (1) After 'MDone → MIdle' the core advances PC by 4 (because
  --       it saw stall=False during MDone). In MIdle it's now
  --       asking for BRAM[X+4], but mReply still holds BRAM[X]. We
  --       MUST present stall=True (= 'defaultReply') so the core
  --       waits for the next round-trip rather than consuming the
  --       previous request's data — silent garbage-fetch otherwise.
  --
  --   (2) For self-loops (@j .@), the core executes the same
  --       instruction at the same PC every cycle. 'reqIsLive'
  --       returns False (PC unchanged, no data port assertion), the
  --       FSM stays in MIdle, and no new bridge transaction fires.
  --       But the core still needs stall=False to commit the
  --       instruction sitting in IF/ID. So when the request matches
  --       what 'mReply' was captured for, present 'mReply' (with
  --       stall=False) and let the core re-execute it as many times
  --       as it likes. Without this, every self-loop deadlocks the
  --       bridge: the core stalls forever in MIdle, mLastSentPc never
  --       changes, no new request fires.
  --
  --   (3) On the MBusy cycle that 'doneEdgeC' fires (= the cycle
  --       'capReplyC' first reflects the synced bus reply with
  --       imemReady=True), present @capReplyC@ with @cbrStall=True@
  --       and @cbrDataStall=True@. This "imem ready, but I'm still
  --       stalling" signal lets the core's 'fValidTrackS' flip to
  --       True for the NEXT cycle (= MDone, where stall=False),
  --       so the FIRST IF/ID capture of every bridge round-trip
  --       sees @ifValid=True@ and the instruction enters the
  --       pipeline as a real retire rather than a bubble. Without
  --       this, the LUI at PC=0 would forever be a bubble, x11
  --       would never get its 0x10000000, and every subsequent
  --       SW would commit to address 0 instead of the UART base.
  --       Caught by 'CdcSocIntegrationSpec.case_core_dAddr'.
  replyOutC =
    ( \st req capR doneE -> case mPhase st of
        MDone -> mReply st
        MBusy
          | doneE -> capR{cbrStall = True, cbrDataStall = True}
          | otherwise -> defaultReply
        MIdle
          | reqIsLive req (mLastSentPc st) -> defaultReply
          | otherwise -> mReply st
    )
      <$> masterStateC
      <*> reqInC
      <*> capReplyC
      <*> doneEdgeC

  -- Drive the latched request to the bus differently per phase:
  --
  --   * 'SDrive' / 'SServe' (waiting for bus stall to release):
  --     keep the FULL request asserted (cbrPcFetch + cbrDAddr +
  --     cbrDWdata + cbrDBe + cbrDRen). The bus's slave adapters
  --     (BRAM, SRAM, SDRAM, JTAG-UART) all expect the master to
  --     hold the request stable until they release stall. Cutting
  --     short any field mid-transaction breaks the slave's
  --     multi-cycle handling. The UART doubling that occurs in sim
  --     because of the held @dBe@ is acceptable: it's masked by
  --     the bus's @uartAcceptedS@ latch in single-domain mode (the
  --     hot path past 'CdcSocIntegrationSpec.case_hello_through_bridge'
  --     captures it as a sim-only artefact).
  --   * 'SIdle' / 'SDone': drive everything zero so no data-port
  --     activity leaks through between transactions.
  --
  -- The SDRAM bridge ('Riski5.SdramCdcBridge.slaveBus') avoids the
  -- same class of bug by driving sibCs=False outside its SReq
  -- phase. Caught by 'case_slave_drives_empty_in_idle' in
  -- test/CdcSpec.hs.
  reqOutB =
    ( \st -> case sPhase st of
        SDrive -> sLatReq st
        SServe -> sLatReq st
        _      -> emptyReq
    )
      <$> slaveStateB

  emptyReq :: CoreBusReq
  emptyReq = CoreBusReq 0 0 0 0 False

  -- Debug taps (see haddock above for bit layout).
  dbgMasterC =
    ( \st req dt de ->
        let phaseBits :: BitVector 2
            phaseBits = case mPhase st of
              MIdle -> 0
              MBusy -> 1
              MDone -> 2
            tog = if mReqToggle st then (1 :: BitVector 1) else 0
            dToggle = if dt then (1 :: BitVector 1) else 0
            dEdge = if de then (1 :: BitVector 1) else 0
            live = if reqIsLive req (mLastSentPc st) then (1 :: BitVector 1) else 0
            pcLo = resize (cbrPcFetch req) :: BitVector 2
         in pack (pcLo, live, dEdge, dToggle, tog, phaseBits)
    )
      <$> masterStateC
      <*> reqInC
      <*> doneToggleC
      <*> doneEdgeC

  dbgSlaveB =
    ( \st rt re reply ->
        let phaseBits :: BitVector 2
            phaseBits = case sPhase st of
              SIdle -> 0
              SDrive -> 1
              SServe -> 2
              SDone -> 3
            dTog = if sDoneToggle st then (1 :: BitVector 1) else 0
            rToggle = if rt then (1 :: BitVector 1) else 0
            rEdge = if re then (1 :: BitVector 1) else 0
            stall = if cbrStall reply then (1 :: BitVector 1) else 0
            dStall = if cbrDataStall reply then (1 :: BitVector 1) else 0
            pcLo0 :: BitVector 1
            pcLo0 = resize (cbrPcFetch (sLatReq st))
         in pack (pcLo0, dStall, stall, rEdge, rToggle, dTog, phaseBits)
    )
      <$> slaveStateB
      <*> reqToggleB
      <*> reqEdgeB
      <*> replyInB

  -- Wide PC probes for silicon visibility (task #46).
  dbgMasterLastPcC :: Signal coreDom (BitVector 32)
  dbgMasterLastPcC = mLastSentPc <$> masterStateC

  dbgSlaveLatPcB :: Signal busDom (BitVector 32)
  dbgSlaveLatPcB = (cbrPcFetch . sLatReq) <$> slaveStateB

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
    -- 'mReply' is preserved across MDone → MIdle on purpose: the
    -- combinational 'replyOutC' decides per-cycle whether to expose
    -- it (no new request live) or stall (new request live). Keeping
    -- mReply here makes the self-loop case work — see 'replyOutC'.
    MDone -> st{mPhase = MIdle}

-- | A request is "new" only when the program counter changes from
-- what the bridge last serviced. The data-port signals (cbrDRen,
-- cbrDBe) are NOT used here because the core legitimately holds
-- them asserted across the multi-cycle bridge round-trip while
-- waiting for the W-stage to commit a load/store; including them
-- would make 'reqIsLive' return True every MIdle re-entry after
-- MDone, re-firing the bridge for the same SW dozens of times and
-- causing downstream side-effecting slaves (notably the JTAG-UART
-- IP) to commit the write multiple times. Each pcFetch advance
-- marks one pipeline-advance event = one bridge transaction, and
-- the bundled CoreBusReq carries whatever data-port assertion the
-- X-stage has live for that PC.
--
-- Caught by 'case_held_sw_no_master_refire' in test/CdcSpec.hs.
reqIsLive :: CoreBusReq -> BitVector 32 -> Bool
reqIsLive req lastPc = cbrPcFetch req P./= lastPc

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
