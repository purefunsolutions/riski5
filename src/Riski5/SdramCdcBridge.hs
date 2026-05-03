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
Module      : Riski5.SdramCdcBridge
Description : Toggle-handshake CDC bridge between DomBus and DomSdram.

Sits between 'Riski5.Sdram.sdram' (the two-port adapter that lives
in DomBus) and 'Riski5.SdrController' (which moves to DomSdram in
the multi-PLL split). Equivalent in protocol to
@sim/riski5_sdram_cdc_bridge.v@ but written in Clash so it
type-checks against the same 'SdramIpBus' / 'SdramIpReply' records
the rest of the SoC speaks.

== Protocol — toggle handshake

Forward path (DomBus → DomSdram):
  1. Master in M_IDLE sees @sibCs = True@ on the input bus. Latches
     {addr, wdata, be, rd, wr} into stable registers and toggles
     @reqToggleBus@. Transitions to M_BUSY.
  2. Slave 2-FF synchronises @reqToggleBus@ → @reqSync2Sdram@.
     edge-detect produces a one-cycle pulse.
  3. On that pulse, slave samples the latched-bus registers
     (treated as quasi-static — master holds them stable for the
     entire M_BUSY window). Slave moves S_IDLE → S_REQ.
  4. Slave drives the latched bus onto its output until the
     controller's @sirWaitrequest@ goes False. For reads, slave
     transitions to S_AWAIT_VALID; for writes, S_DONE.
  5. S_AWAIT_VALID waits for @sirValid@, captures @sirRdata@ into
     @capRdataSdram@. Transitions to S_DONE.
  6. S_DONE toggles @doneToggleSdram@ and returns to S_IDLE.

Reverse path (DomSdram → DomBus):
  7. Master 2-FF synchronises @doneToggleSdram@ → @doneSync2Bus@.
     edge-detect produces one-cycle pulse @doneEdgeBus@.
  8. On @doneEdgeBus@, master 2-FF synchroniser of @capRdataSdram@
     is sampled (quasi-static — slave held it stable since S_DONE).
     For reads, value is latched into @mRdata@ and master moves
     to M_DONE_R; for writes, M_DONE_W.
  9. M_DONE_W / M_DONE_R drop @sirWaitrequest@ for one cycle so the
     adapter advances. M_DONE_R additionally pulses @sirValid@ in
     the next cycle (M_IDLE) so the adapter captures the read data.

== Latency

Per round-trip transaction (40 MHz bus, 100 MHz sdram, controller
internal latency excluded):
  - 1 clkBus cycle: M_IDLE → M_BUSY + req toggle
  - 2-3 clkSdram cycles: req synchroniser
  - N clkSdram cycles: controller round-trip
  - 1 clkSdram cycle: S_DONE + done toggle
  - 2-3 clkBus cycles: done synchroniser
  - 1 clkBus cycle: M_DONE → M_IDLE + valid pulse

Total ~6-7 clkBus + ~5 clkSdram + controller internal cycles.
At slow=40 MHz / fast=100 MHz that's ~150 ns + ~50 ns + controller
latency = ~200 ns + controller. Acceptable for SDRAM access; same
shape as the sim/riski5_sdram_cdc_bridge.v reference.

== Tied-domains shortcut

When @busDom@ and @sdramDom@ are electrically the same clock (as in
the existing socSim* helpers and the initial multi-PLL build where
all three PLLs run at 40 MHz), the whole CDC machinery is overhead
for nothing. The 'sdramCdcBridgeTied' variant skips the FSMs and
synchronisers, passing signals straight through. It's only legal
when the build system asserts the two domains share a clock tree.
Compile-time gate via type equality (busDom ~ sdramDom) keeps a
caller from accidentally using it with truly-different clocks.
-}
module Riski5.SdramCdcBridge (
  sdramCdcBridge,
  sdramCdcBridgeTied,
) where

import Clash.Explicit.Prelude hiding (not, (&&), (||))
import GHC.Generics (Generic)
import Prelude (not, (&&), (||))
import Riski5.Cdc (edgeDetect, syncBit, syncBitVector)
import Riski5.Sdram (SdramIpBus (..), SdramIpReply (..))

-- * Master FSM (DomBus side)

data MasterPhase
  = MIdle
  | MBusy
  | MDoneW -- write completed; drop waitrequest one cycle
  | MDoneR -- read completed; drop waitrequest, pulse valid next cycle
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

data MasterState = MasterState
  { mPhase :: MasterPhase
  , mLatAddr :: BitVector 22
  , mLatWdata :: BitVector 16
  , mLatBe :: BitVector 2
  , mLatRd :: Bool
  , mLatWr :: Bool
  , mReqToggle :: Bool
  , mRdata :: BitVector 16
  , mValid :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

masterInit :: MasterState
masterInit = MasterState MIdle 0 0 0 False False False 0 False

-- * Slave FSM (DomSdram side)

data SlavePhase
  = SIdle
  | SReq -- driving controller, waiting for !waitrequest
  | SAwaitValid -- read fired, waiting for valid
  | SDone -- toggle done back to master
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

data SlaveState = SlaveState
  { sPhase :: SlavePhase
  , sLatAddr :: BitVector 22
  , sLatWdata :: BitVector 16
  , sLatBe :: BitVector 2
  , sLatRd :: Bool
  , sLatWr :: Bool
  , sDoneToggle :: Bool
  , sCapRdata :: BitVector 16
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

slaveInit :: SlaveState
slaveInit = SlaveState SIdle 0 0 0 False False False 0

-- * Bridge

{- | Toggle-handshake bridge between a 'DomBus'-side master speaking
the @SdramIpBus@/@SdramIpReply@ protocol (i.e. 'Riski5.Sdram.sdram')
and a 'DomSdram'-side slave (i.e. the SDRAM controller's Avalon-MM
interface). Crosses both directions safely under the assumption
that the master holds its bus signals stable for the entire
@M_BUSY@ window — which 'Riski5.Sdram.sdram''s FSM does naturally.
-}
sdramCdcBridge ::
  forall busDom sdramDom.
  (KnownDomain busDom, KnownDomain sdramDom) =>
  Clock busDom ->
  Reset busDom ->
  Enable busDom ->
  Clock sdramDom ->
  Reset sdramDom ->
  Enable sdramDom ->
  -- | Master-side request bus (from Riski5.Sdram.sdram).
  Signal busDom SdramIpBus ->
  -- | Slave-side reply (from SdrController).
  Signal sdramDom SdramIpReply ->
  -- | (master-side reply to Riski5.Sdram, slave-side request to controller)
  ( Signal busDom SdramIpReply
  , Signal sdramDom SdramIpBus
  )
sdramCdcBridge clkB rstB enB clkS rstS enS busInB replyInS =
  (replyOutB, busOutS)
 where
  -- Forward toggle: master toggles on every M_IDLE→M_BUSY.
  reqToggleB = mReqToggle <$> masterStateB
  reqToggleS = syncBit clkB clkS rstS enS reqToggleB
  reqEdgeS = edgeDetect clkS rstS enS reqToggleS

  -- Reverse toggle: slave toggles on every S_DONE.
  doneToggleS = sDoneToggle <$> slaveStateS
  doneToggleB = syncBit clkS clkB rstB enB doneToggleS
  doneEdgeB = edgeDetect clkB rstB enB doneToggleB

  -- Captured read data crosses Sdram→Bus as a quasi-static bus
  -- (slave holds it stable from S_DONE until the next read fires).
  capRdataS = sCapRdata <$> slaveStateS
  capRdataB = syncBitVector clkS clkB rstB enB capRdataS

  -- Latched master bus crosses Bus→Sdram as a quasi-static bundle
  -- (master holds it stable for the entire M_BUSY window). Bundle
  -- as a single BitVector to share one synchroniser.
  latBundleB :: Signal busDom (BitVector 43)
  latBundleB = packLatched <$> masterStateB
  latBundleS = syncBitVector clkB clkS rstS enS latBundleB

  -- Master state machine.
  masterStateB :: Signal busDom MasterState
  masterStateB =
    register clkB rstB enB masterInit $
      masterStep
        <$> masterStateB
        <*> busInB
        <*> doneEdgeB
        <*> capRdataB

  -- Slave state machine.
  slaveStateS :: Signal sdramDom SlaveState
  slaveStateS =
    register clkS rstS enS slaveInit $
      slaveStep
        <$> slaveStateS
        <*> reqEdgeS
        <*> latBundleS
        <*> replyInS

  -- Master-side reply: waitrequest is high while M_BUSY; mValid
  -- is True for one cycle after a read completes; mRdata is held
  -- in the master state.
  replyOutB =
    fmap masterReply masterStateB

  -- Slave-side request: drive the controller from sLatched only
  -- when the slave is in SReq (driving phase).
  busOutS =
    fmap slaveBus slaveStateS

masterStep ::
  MasterState ->
  SdramIpBus ->
  Bool -> -- doneEdge
  BitVector 16 -> -- captured rdata (synchronised)
  MasterState
masterStep st@MasterState{..} bus doneEdge capR =
  case mPhase of
    MIdle
      | sibCs bus ->
          st
            { mPhase = MBusy
            , mLatAddr = sibAddr bus
            , mLatWdata = sibWdata bus
            , mLatBe = sibBe bus
            , mLatRd = sibRd bus
            , mLatWr = sibWr bus
            , mReqToggle = not mReqToggle
            , mValid = False
            }
      | otherwise -> st{mValid = False}
    MBusy
      | doneEdge ->
          if mLatRd
            then st{mPhase = MDoneR, mRdata = capR, mValid = False}
            else st{mPhase = MDoneW, mValid = False}
      | otherwise -> st{mValid = False}
    MDoneW -> st{mPhase = MIdle, mValid = False}
    MDoneR -> st{mPhase = MIdle, mValid = True}

slaveStep ::
  SlaveState ->
  Bool -> -- reqEdge
  BitVector 43 -> -- latched bundle (synchronised)
  SdramIpReply ->
  SlaveState
slaveStep st@SlaveState{..} reqEdge latBundle reply =
  case sPhase of
    SIdle
      | reqEdge ->
          let (a, w, be, rd, wr) = unpackLatched latBundle
           in st
                { sPhase = SReq
                , sLatAddr = a
                , sLatWdata = w
                , sLatBe = be
                , sLatRd = rd
                , sLatWr = wr
                }
      | otherwise -> st
    SReq
      | not (sirWaitrequest reply) ->
          if sLatRd
            then st{sPhase = SAwaitValid}
            else st{sPhase = SDone}
      | otherwise -> st
    SAwaitValid
      | sirValid reply -> st{sPhase = SDone, sCapRdata = sirRdata reply}
      | otherwise -> st
    SDone -> st{sPhase = SIdle, sDoneToggle = not sDoneToggle}

masterReply :: MasterState -> SdramIpReply
masterReply MasterState{..} =
  SdramIpReply
    { sirRdata = mRdata
    , sirValid = mValid
    , sirWaitrequest = mPhase == MBusy
    }

slaveBus :: SlaveState -> SdramIpBus
slaveBus SlaveState{..} =
  case sPhase of
    SReq ->
      SdramIpBus
        { sibCs = True
        , sibAddr = sLatAddr
        , sibWdata = sLatWdata
        , sibBe = sLatBe
        , sibRd = sLatRd
        , sibWr = sLatWr
        }
    _ ->
      SdramIpBus
        { sibCs = False
        , sibAddr = 0
        , sibWdata = 0
        , sibBe = 0
        , sibRd = False
        , sibWr = False
        }

-- | Bundle the latched-bus payload into a single 43-bit vector for
-- one shared synchroniser pair instead of one per field. Layout:
-- @{addr[21:0], wdata[15:0], be[1:0], rd, wr, pad}@.
packLatched :: MasterState -> BitVector 43
packLatched MasterState{..} =
  pack (mLatAddr, mLatWdata, mLatBe, mLatRd, mLatWr, low)
 where
  low = (0 :: BitVector 1)

unpackLatched ::
  BitVector 43 ->
  (BitVector 22, BitVector 16, BitVector 2, Bool, Bool)
unpackLatched bv =
  let (a, w, be, rd, wr, _ :: BitVector 1) = unpack bv
   in (a, w, be, rd, wr)

-- * Tied-domains passthrough

{- | Direct-wire bridge for the case when the bus and SDRAM domains
are electrically the same clock (the existing single-domain build
and the sim helpers that re-tie all three domains). Compile-time
gated by @busDom ~ sdramDom@ so a caller can't accidentally mis-tie
genuinely different clocks.

The tied bridge degrades to: master input bus → slave output (no
delay), slave input reply → master output (no delay). No FSM, no
synchronisers. Cycle-accurate equivalent to having no bridge at all.
-}
sdramCdcBridgeTied ::
  forall dom.
  (KnownDomain dom) =>
  Signal dom SdramIpBus ->
  Signal dom SdramIpReply ->
  ( Signal dom SdramIpReply
  , Signal dom SdramIpBus
  )
sdramCdcBridgeTied busInS replyInS = (replyInS, busInS)
