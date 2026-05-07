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
  , -- | Flush pulse from the core's X-stage. True for the cycle
    -- when a branch / jump / trap redirects PC. The bridge uses
    -- this to refire even if @cbrPcFetch@ doesn't change after the
    -- redirect (= when the F-stage was speculatively fetching the
    -- same address as the redirect target). Without this signal,
    -- a beqz-takes-to-same-PC-as-pcFetchS corner case causes the
    -- bridge to skip the post-flush fetch, losing the instruction
    -- (e.g. @lw ra, 28(sp)@ in seq_buf_printf's .L36 epilogue —
    -- see TODO #55). Defaults to False.
    cbrFlush :: Bool
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
  , -- | The data-port byte-enable last latched at MIdle→MBusy. Used
    -- by 'reqIsLive' so the bridge fires a NEW transaction whenever
    -- the core asserts a fresh data-port operation at the same PC —
    -- the AMO FU's read→write phase transition does exactly this
    -- (cbrDBe goes 0→0xF mid-AMO without PC advancing). Without this
    -- track, the AMO's write phase would silently never reach the
    -- bus and the swap would not commit (caught on silicon by
    -- amostress hitting bank-A failAL with rd==tExpected, indicating
    -- the AMO write never updated mem[tA]).
    mLastDBe :: BitVector 4
  , -- | The data-port read-enable last latched. Same role as
    -- 'mLastDBe' for completeness — covers a hypothetical AMO write→
    -- read sequence at the same PC.
    mLastDRen :: Bool
  , mReqToggle :: Bool
  , mReply :: CoreBusReply
  , -- | Latched cbrFlush pulse, held until the master enters MIdle
    -- and refires. Required because cbrFlush is a 1-cycle pulse from
    -- the core's X-stage; if the bridge is in MBusy/MDone when the
    -- pulse arrives, the master would otherwise miss it (TODO #55).
    -- Cleared at MIdle→MBusy. Distinguished from cbrFlush req in
    -- masterStep: this latch carries the flush across multi-cycle
    -- bridge transactions.
    mFlushPending :: Bool
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
masterInit = MasterState MIdle 0xFFFF_FFFF 0 False False defaultReply False

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
  , -- | Latched once 'cbrDataStall' has gone False at least once during
    -- this transaction. After this, the bridge masks the data-port
    -- fields ('cbrDBe', 'cbrDRen', 'cbrDWdata') driven onto the bus so
    -- 'Riski5.Sdram.sdram' (which has data-priority arbitration and
    -- keeps re-issuing the held SW indefinitely while IF would starve)
    -- can finally serve the IF stage. Without this, an SDRAM-resident
    -- pipeline running a data SW to SDRAM deadlocks the bridge: data
    -- completes and re-fires forever, IF never gets served, 'cbrStall'
    -- stays True forever. Caught on silicon by amostress hanging at
    -- PC=0x80000044 (3rd cross-row SDRAM SW with concurrent SDRAM IF).
    sDataDone :: Bool
  , -- | Latched once 'cbrStall' has gone False at least once during
    -- this transaction. Same per-port-done-tracking idea as
    -- 'sDataDone'. The 'sImemRdata' below captures the instruction
    -- word at the cycle imemReady fires so it survives any number of
    -- subsequent re-fetches Sdram might do before the data side also
    -- completes.
    sImemDone :: Bool
  , -- | Captured instruction word at the cycle 'cbrStall' first
    -- dropped to False. Held through the rest of SServe so the final
    -- 'sCapReply' carries the right imem data even if Sdram re-fetches
    -- in the interim.
    sImemRdata :: BitVector 32
  , -- | Captured load rdata at the cycle 'cbrDataStall' first dropped
    -- to False. Same role as 'sImemRdata' but for the data port.
    sDmemRdata :: BitVector 32
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

slaveInit :: SlaveState
slaveInit =
  SlaveState
    { sPhase = SIdle
    , sLatReq = CoreBusReq 0 0 0 0 False False
    , sDoneToggle = False
    , sCapReply = defaultReply
    , sDataDone = False
    , sImemDone = False
    , sImemRdata = 0
    , sDmemRdata = 0
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

  -- Latched core request crosses Core→Bus quasi-static. Source from
  -- the LIVE 'reqInC' (NOT a latched master-state field) so the
  -- bundle leads the @mReqToggle@ by 1 cycle: by the time the toggle
  -- edge propagates through the CDC sync, the bundle has been stable
  -- for ≥1 cycle on the source side, giving the slave's
  -- @syncBitVector@ a safely-stable window. The pipeline-stall
  -- guarantee on the core side keeps reqInC's contributing fields
  -- (cbrPcFetch from the F stage, cbrDAddr/cbrDBe/cbrDWdata from
  -- the M stage) constant through MBusy because @stallInternalS@
  -- holds those stages frozen.
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
  -- Side-channel mtip / meip propagation. The interrupt-pending
  -- bits MUST cross continuously, NOT bundled in the request/reply
  -- round-trip — otherwise the core's view goes stale during
  -- MIdle (live req) and MBusy (non-doneEdge) cycles where the
  -- 'replyOutC' below picks 'defaultReply' (mtip=False, meip=False).
  -- That used to be harmless in the common case (every fetch refires
  -- the bridge so the round-trip refreshes mtip on each round) but
  -- it deadlocks the kernel idle loop: when WFI halts the X stage,
  -- pcFetch freezes, no new bridge round-trip ever fires, and the
  -- last-captured mReply.cbrMtip stays at whatever value it had at
  -- the last SDone — typically False if the timer hadn't fired yet.
  -- Live mtipS rising on the bus side then never reaches the core,
  -- WFI never wakes, and the kernel hangs forever in arch_cpu_idle.
  --
  -- These two 2-FF synchronisers carry mtip / meip from busDom
  -- straight to coreDom every cycle, regardless of bridge phase.
  -- 'replyOutC' below overlays them onto whatever payload it picks,
  -- so the core's view of the irq-pending bits is always live within
  -- 1-2 cycles of the bus side asserting them.
  liveMtipB :: Signal busDom Bool
  liveMtipB = cbrMtip <$> replyInB
  liveMtipC :: Signal coreDom Bool
  liveMtipC = syncBit clkB clkC rstC enC liveMtipB

  liveMeipB :: Signal busDom Bool
  liveMeipB = cbrMeip <$> replyInB
  liveMeipC :: Signal coreDom Bool
  liveMeipC = syncBit clkB clkC rstC enC liveMeipB

  replyOutC =
    ( \st req capR doneE liveMtip liveMeip ->
        let base = case mPhase st of
              MDone -> mReply st
              MBusy
                | doneE -> capR{cbrStall = True, cbrDataStall = True}
                | otherwise -> defaultReply
              MIdle
                | reqIsLive req (mLastSentPc st) (mLastDBe st) (mLastDRen st)
                    P.|| mFlushPending st ->
                    -- Stall in MIdle when a flush is pending OR is firing
                    -- this cycle — the master is about to refire and the
                    -- core mustn't commit the stale mReply. See TODO #55.
                    -- (#64 fix: dropped `cbrFlush req` from this disjunct
                    -- to break the comb loop replyOutC.cbrStall → core.flushS
                    -- → cbrFlush req → replyOutC.cbrStall that Verilator
                    -- detected as UNOPTFLAT and aborted on at sim cycle 480M.
                    -- The pendingFlush latch in masterStep still catches the
                    -- flush pulse and asserts mFlushPending on the next cycle,
                    -- so flush detection lags by 1 cycle but is preserved.)
                    defaultReply
                | otherwise -> mReply st
         in -- Always overlay live-synced mtip / meip from the bus
            -- side, regardless of phase. See the long comment above
            -- 'liveMtipB' for why this side-channel is essential
            -- for the WFI-halt path to work.
            base{cbrMtip = liveMtip, cbrMeip = liveMeip}
    )
      <$> masterStateC
      <*> reqInC
      <*> capReplyC
      <*> doneEdgeC
      <*> liveMtipC
      <*> liveMeipC

  -- Drive the latched request to the bus differently per phase:
  --
  --   * 'SDrive': keep the FULL request asserted (cbrPcFetch +
  --     cbrDAddr + cbrDWdata + cbrDBe + cbrDRen). One cycle of
  --     full-request drive is enough for the bus's slave adapters
  --     (BRAM, SRAM, SDRAM, JTAG-UART) to register their initial
  --     captures. See 'SlavePhase' note on why SDrive exists.
  --   * 'SServe': mask the data-port fields once 'sDataDone' has
  --     latched (= cbrDataStall has dropped at least once = the
  --     data-port adapter has accepted/completed the SW or LW). This
  --     prevents 'Riski5.Sdram.sdram', whose internal arbitration
  --     gives data priority and re-issues a held data SW indefinitely,
  --     from starving the IF stage when both ports target SDRAM (as
  --     in the amostress inner loop with SDRAM-resident code + cross-
  --     row data SWs). Without the mask the bridge deadlocks: data
  --     completes + re-fires forever, IF never gets served, cbrStall
  --     stays True, slave waits forever. Same mask also eliminates
  --     the UART-doubling sim artefact previously papered over with
  --     'halveRuns' in CdcSocIntegrationSpec — once cbrDBe goes 0,
  --     the JTAG-UART IP only sees one accept per SW.
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
        SServe ->
          let req = sLatReq st
           in if sDataDone st
                then req{cbrDBe = 0, cbrDRen = False, cbrDWdata = 0}
                else req
        _ -> emptyReq
    )
      <$> slaveStateB

  emptyReq :: CoreBusReq
  emptyReq = CoreBusReq 0 0 0 0 False False

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
            live = if reqIsLive req (mLastSentPc st) (mLastDBe st) (mLastDRen st) then (1 :: BitVector 1) else 0
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
  -- Latch any incoming flush pulse — it may arrive while master is
  -- MBusy/MDone, and we need to honour it on the next MIdle.
  let pendingFlush = mFlushPending P.|| cbrFlush req
   in case mPhase of
        MIdle
          | reqIsLive req mLastSentPc mLastDBe mLastDRen P.|| pendingFlush ->
              -- pendingFlush forces a refire even when reqIsLive returns
              -- False (= when post-flush PC equals the previous
              -- mLastSentPc, which happens when F-stage was speculatively
              -- fetching the branch target before the redirect). Without
              -- this, the in-flight bridge transaction's data gets
              -- bubbled by flushIfIdS and the bridge never refires,
              -- losing the instruction. See TODO #55 for the
              -- seq_buf_printf .L36 race.
              st
                { mPhase = MBusy
                , mLastSentPc = cbrPcFetch req
                , mLastDBe = cbrDBe req
                , mLastDRen = cbrDRen req
                , mReqToggle = not mReqToggle
                , mFlushPending = False -- consumed
                }
          | otherwise -> st{mFlushPending = pendingFlush}
        MBusy
          | doneEdge -> st{mPhase = MDone, mReply = capR, mFlushPending = pendingFlush}
          | otherwise -> st{mFlushPending = pendingFlush}
        -- 'mReply' is preserved across MDone → MIdle on purpose: the
        -- combinational 'replyOutC' decides per-cycle whether to expose
        -- it (no new request live) or stall (new request live). Keeping
        -- mReply here makes the self-loop case work — see 'replyOutC'.
        MDone -> st{mPhase = MIdle, mFlushPending = pendingFlush}

-- | A request is "new" when ANY of these holds:
--
--   * The program counter changed from what the bridge last
--     serviced — the normal pipeline-advance trigger.
--   * The data-port byte-enable transitioned from zero to non-zero
--     while PC stayed the same — covers the AMO FU's read→write
--     phase transition (cbrDBe goes 0→0xF mid-AMO without the F
--     stage advancing) and any future multi-phase data-port FUs.
--     Without this, the AMO's write phase would silently never
--     fire a bridge transaction and the swap would not commit.
--   * The data-port read-enable transitioned from False to True —
--     symmetric to the dBe edge for hypothetical write→read at the
--     same PC.
--
-- We intentionally use *rising-edge* checks rather than "is non-zero"
-- so a held SW (cbrDBe=0xF for many cycles while M-stage stalls on
-- the bridge round-trip) does not refire the bridge dozens of times,
-- which would cause downstream side-effecting slaves (notably the
-- JTAG-UART IP) to commit the write multiple times.
--
-- Caught by 'case_held_sw_no_master_refire' (no spurious refires) and
-- the AMO silicon test 'amostress' (write phase actually commits).
reqIsLive :: CoreBusReq -> BitVector 32 -> BitVector 4 -> Bool -> Bool
reqIsLive req lastPc lastDBe lastDRen =
  cbrPcFetch req P./= lastPc
    P.|| (lastDBe P.== 0 P.&& cbrDBe req P./= 0)
    P.|| (P.not lastDRen P.&& cbrDRen req)

slaveStep ::
  SlaveState ->
  Bool -> -- reqEdge
  CoreBusReq ->
  CoreBusReply ->
  SlaveState
slaveStep st@SlaveState{..} reqEdge latReq reply =
  case sPhase of
    SIdle
      | reqEdge ->
          st
            { sPhase = SDrive
            , sLatReq = latReq
            , sDataDone = False
            , sImemDone = False
            , sImemRdata = 0
            , sDmemRdata = 0
            }
      | otherwise -> st
    -- One settle cycle after sLatReq updates so the bus's slave
    -- responses (notably blockRam-backed imemDataBramS, which has a
    -- 1-cycle sync-read latency) reflect the new pcFetch / dAddr
    -- before we capture them. See note on 'SlavePhase'.
    SDrive -> st{sPhase = SServe}
    SServe ->
      let -- Whether the latched request actually has a data-port
          -- operation pending. Without this gate, IF-only
          -- transactions (cbrDRen=False, cbrDBe=0) see
          -- cbrDataStall=False from the very first SServe cycle (the
          -- bus drives dataStallS=False whenever dataAccessS=False),
          -- and the bridge captures whatever stale value happens to
          -- be on the bus's combinational dmemRdataS — typically a
          -- BRAM word from addr 0 (the firmware's `lui a0, 0x10000`
          -- = 0x10000537). That stale value then poisons mReply, and
          -- the next time the master is in MIdle without a live req,
          -- the core sees the poisoned value as a "fake LW result"
          -- via the bridge's MIdle-otherwise → mReply path. Gating
          -- the capture (and the dataDone signal) on actually-pending
          -- data port use keeps mReply stable until a real LW lands.
          dataPortPending =
            cbrDRen sLatReq || cbrDBe sLatReq /= 0
          imemDoneNow = sImemDone || not (cbrStall reply)
          dataDoneNow =
            sDataDone
              || not dataPortPending
              || not (cbrDataStall reply)
          imemRdataNow =
            if not sImemDone && not (cbrStall reply)
              then cbrImemData reply
              else sImemRdata
          dmemRdataNow =
            if not sDataDone
              && dataPortPending
              && not (cbrDataStall reply)
              then cbrDmemRdata reply
              else sDmemRdata
          capReply' =
            reply
              { cbrImemData = imemRdataNow
              , cbrImemReady = True
              , cbrDmemRdata = dmemRdataNow
              , cbrStall = False
              , cbrDataStall = False
              }
       in if imemDoneNow && dataDoneNow
            then
              st
                { sPhase = SDone
                , sCapReply = capReply'
                , sImemDone = True
                , sDataDone = True
                , sImemRdata = imemRdataNow
                , sDmemRdata = dmemRdataNow
                }
            else
              st
                { sImemDone = imemDoneNow
                , sDataDone = dataDoneNow
                , sImemRdata = imemRdataNow
                , sDmemRdata = dmemRdataNow
                }
    SDone -> st{sPhase = SIdle, sDoneToggle = not sDoneToggle}

-- * Packing helpers

packReq :: CoreBusReq -> BitVector 102
packReq CoreBusReq{..} =
  pack (cbrPcFetch, cbrDAddr, cbrDWdata, cbrDBe, cbrDRen, cbrFlush)

unpackReq :: BitVector 102 -> CoreBusReq
unpackReq bv =
  let (pc, da, dw, be, rd, fl) = unpack bv
   in CoreBusReq pc da dw be rd fl

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
