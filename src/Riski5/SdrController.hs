-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Riski5.SdrController
Description : Pure-Clash SDR SDRAM controller for the DE2's
              IS42S16400-7TL 8 MB chip.

See @docs/sdram-hi-half-write-bug.md@ for the wider context.
Replaces Altera's @altera_avalon_new_sdram_controller@ IP.

== Chip target

IS42S16400 family — 4M × 16-bit, 4 banks, 12-bit row, 8-bit
column. Datasheet timing (-7TL @ 108 MHz, period = 9.26 ns):

@
  T_RCD  = 21 ns →  3 cycles  (ACTIVATE → READ/WRITE)
  T_RP   = 21 ns →  3 cycles  (PRECHARGE recovery)
  T_RFC  = 60 ns →  7 cycles  (auto-refresh cycle)
  T_WR   = 14 ns →  2 cycles  (WRITE → PRECHARGE)
  T_MRD  = 2 cycles           (LOAD MODE REG → next command)
  CL     = 3 cycles           (READ → first data)
  T_REF  = 7.81 µs (= 4096 refreshes / 32 ms typical)
@

== Avalon-MM slave port (matches the Altera IP's pin shape)

The SDRAM 32 ↔ 16 width adapter ('Riski5.Sdram') sees the same
@az_*@ / @za_*@ signals it currently drives at the IP boundary,
so swapping IP ↔ this module is a single-instantiation change.

== Implementation status

- Init sequence: ✅ implemented (NOP × N → PRECHARGE-ALL → REFRESH × 8
  → LOAD MODE REGISTER → idle).
- Steady-state read/write: 🚧 stub (always asserts waitrequest).
- Background refresh: 🚧 stub.

The init FSM is testable against 'sdrChipModel' (the behavioral
chip stand-in below) before we layer the steady-state path on top.
-}
module Riski5.SdrController (
  -- * Configuration
  SdrConfig (..),
  defaultDe2Config,

  -- * Chip-side I/O bundle
  SdrPins (..),
  sdrIdleCmd,

  -- * Avalon-MM slave bundle (mirrors Riski5.Sdram.SdramIpBus +
  --   SdramIpReply for drop-in compatibility)
  SdrSlaveIn (..),
  SdrSlaveOut (..),

  -- * Controller entity
  sdrController,

  -- * FSM state (re-exported for tests)
  SdrPhase (..),
  SdrState (..),
  initState,

  -- * Chip behavioral model (sim only — for unit tests)
  ChipModelOut (..),
  sdrChipModel,
) where

import Clash.Prelude hiding ((||), (&&), not)
import qualified Clash.Prelude as CP
import Prelude ((||), (&&), not)

-- * Configuration ---------------------------------------------------

-- | Static configuration for the controller. Defaults match the
-- DE2's IS42S16400-7TL @ 108 MHz CL=3.
data SdrConfig = SdrConfig
  { sdrTrcdCycles :: Unsigned 4
  , sdrTrpCycles :: Unsigned 4
  , sdrTrfcCycles :: Unsigned 4
  , sdrTwrCycles :: Unsigned 4
  , sdrCasLatency :: Unsigned 4
  , sdrTmrdCycles :: Unsigned 4
  , sdrRefreshIntervalCycles :: Unsigned 16
  , sdrInitNopCycles :: Unsigned 16
  , sdrInitRefreshCount :: Unsigned 4
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (NFDataX)

defaultDe2Config :: SdrConfig
defaultDe2Config =
  SdrConfig
    { sdrTrcdCycles = 3
    , sdrTrpCycles = 3
    , sdrTrfcCycles = 7
    , sdrTwrCycles = 2
    , sdrCasLatency = 3
    , sdrTmrdCycles = 2
    , sdrRefreshIntervalCycles = 843
    , sdrInitNopCycles = 21600
    , sdrInitRefreshCount = 8
    }

-- * Chip-side I/O ---------------------------------------------------

-- | Chip-side pins. The Verilog top wrapper resolves @SDRAM_DQ@
-- (inout) from (sdrDqOut, sdrDqOe, sdrDqIn).
data SdrPins = SdrPins
  { sdrAddr :: BitVector 12
  , sdrBa :: BitVector 2
  , sdrCasN :: Bool
  , sdrCke :: Bool
  , sdrCsN :: Bool
  , sdrDqOut :: BitVector 16
  , sdrDqOe :: Bool
  , sdrDqm :: BitVector 2
  , sdrRasN :: Bool
  , sdrWeN :: Bool
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (NFDataX)

-- | Idle-cycle (deselect / NOP) chip pins. CKE held high; chip-
-- select de-asserted so the chip ignores command lines.
sdrIdleCmd :: SdrPins
sdrIdleCmd =
  SdrPins
    { sdrAddr = 0
    , sdrBa = 0
    , sdrCasN = True
    , sdrCke = True
    , sdrCsN = True -- deselected
    , sdrDqOut = 0
    , sdrDqOe = False
    , sdrDqm = 0b11 -- bytes masked when not driving
    , sdrRasN = True
    , sdrWeN = True
    }

-- | Build a NOP cmd (cs_n=0 but no command strobe). Equivalent to
-- 'sdrIdleCmd' for our purposes; kept separate so the FSM trace
-- distinguishes "deselected" from "selected, no command" if we
-- ever care.
sdrNopCmd :: SdrPins
sdrNopCmd = sdrIdleCmd

sdrPrechargeAllCmd :: SdrPins
sdrPrechargeAllCmd =
  sdrIdleCmd
    { sdrCsN = False
    , sdrRasN = False
    , sdrCasN = True
    , sdrWeN = False
    , sdrAddr = bit 10 -- A10 = 1 → all banks
    }

sdrAutoRefreshCmd :: SdrPins
sdrAutoRefreshCmd =
  sdrIdleCmd
    { sdrCsN = False
    , sdrRasN = False
    , sdrCasN = False
    , sdrWeN = True
    }

-- | LOAD MODE REGISTER. Programs CL, burst length, sequential / interleave.
-- Mode register bits (per JEDEC SDR SDRAM):
--   [2:0] burst length: 000=1, 001=2, 010=4, 011=8, 111=full page
--   [3]   burst type:  0=sequential, 1=interleave
--   [6:4] CAS latency: 010=2, 011=3
--   [8:7] op mode:     00 = standard
--   [9]   write burst: 0=programmed length, 1=single
sdrLoadModeRegCmd :: Unsigned 4 -> SdrPins
sdrLoadModeRegCmd cas =
  sdrIdleCmd
    { sdrCsN = False
    , sdrRasN = False
    , sdrCasN = False
    , sdrWeN = False
    , sdrBa = 0
    , -- BL=001 (=2; needed because the chip can't do BL=1 at high
      -- frequencies on some -7T variants — pick BL=2 for safety
      -- and ignore the 2nd word). CAS=cas. Burst type sequential.
      -- write-burst-length = "single" so writes commit one half-word
      -- per WRITE command (matches our access pattern; we don't
      -- want write bursts).
      sdrAddr =
        bit 9 -- write burst = single
          .|. (resize (pack cas) `shiftL` 4) -- CL bits [6:4]
          .|. 0b001 -- BL = 2
    }

-- * Avalon-MM slave -------------------------------------------------

data SdrSlaveIn = SdrSlaveIn
  { ssiCs :: Bool
  , ssiAddr :: BitVector 22
  , ssiWdata :: BitVector 16
  , ssiBeN :: BitVector 2 -- active-low
  , ssiRd :: Bool
  , ssiWr :: Bool
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (NFDataX)

data SdrSlaveOut = SdrSlaveOut
  { ssoRdata :: BitVector 16
  , ssoValid :: Bool
  , ssoWaitrequest :: Bool
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (NFDataX)

-- * FSM state -------------------------------------------------------

data SdrPhase
  = -- * Power-up init
    PhInitNop
  | PhInitPrecharge
  | PhInitTrp
  | PhInitRefresh
  | PhInitTrfc
  | PhInitLmr
  | PhInitTmrd
  | -- * Steady state
    PhIdle
  | PhActivate
  | PhTrcd
  | PhRead
  | PhCl
  | PhCapture
  | PhWrite
  | PhTwr
  | PhTrpAfter
  | -- * Background refresh
    PhRefresh
  | PhTrfc
  deriving stock (Generic, Eq, Show)
  deriving anyclass (NFDataX)

-- | Internal FSM state.
data SdrState = SdrState
  { sdrPhase :: SdrPhase
  , -- | Generic countdown counter — used by every wait phase
    -- (T_RCD, T_RP, T_RFC, T_WR, CL, T_MRD, init NOP).
    sdrTimer :: Unsigned 16
  , -- | Init refresh count remaining.
    sdrInitRefreshLeft :: Unsigned 4
  , -- | Cycle counter for periodic auto-refresh trigger.
    sdrRefreshClock :: Unsigned 16
  }
  deriving stock (Generic)
  deriving anyclass (NFDataX)

initState :: SdrConfig -> SdrState
initState cfg =
  SdrState
    { sdrPhase = PhInitNop
    , sdrTimer = resize (sdrInitNopCycles cfg)
    , sdrInitRefreshLeft = sdrInitRefreshCount cfg
    , sdrRefreshClock = 0
    }

-- * Controller entity ----------------------------------------------

{- |
The SDR SDRAM controller. Single Avalon-MM slave port + chip-side
pins. Init FSM is in place; steady-state read/write is a stub.
-}
sdrController ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  SdrConfig ->
  Signal dom SdrSlaveIn ->
  ( Signal dom SdrSlaveOut
  , Signal dom SdrPins
  )
sdrController cfg inS = (replyS, pinsS)
 where
  (replyS, pinsS) = unbundle (mealy step (initState cfg) inS)

  step :: SdrState -> SdrSlaveIn -> (SdrState, (SdrSlaveOut, SdrPins))
  step st i = (st', (sso, pins))
   where
    (st', pins) = advance cfg st i
    -- Until steady-state path is implemented, always assert
    -- waitrequest. Read data is meaningless in this stub.
    inSteady = case sdrPhase st of
      PhIdle -> True
      _ -> False
    sso =
      SdrSlaveOut
        { ssoRdata = 0
        , ssoValid = False
        , ssoWaitrequest = not inSteady || ssiCs i
        -- ^ While not idle, hold the master. While idle, only
        -- hold if the master is requesting (we don't service
        -- requests yet, so any master cs holds forever — visible
        -- in tests as a hang. Acceptable until phase-2 of this
        -- module lands the steady-state FSM.)
        }

-- | Advance the FSM by one cycle. Pure step function for tests
-- to drive the FSM directly without simulating the model.
advance :: SdrConfig -> SdrState -> SdrSlaveIn -> (SdrState, SdrPins)
advance cfg st _i = case sdrPhase st of
  PhInitNop ->
    if sdrTimer st == 0
      then
        ( st {sdrPhase = PhInitPrecharge}
        , sdrPrechargeAllCmd
        )
      else
        ( st {sdrTimer = sdrTimer st - 1}
        , sdrNopCmd
        )
  PhInitPrecharge ->
    -- ALL-banks precharge issued this cycle; wait T_RP.
    ( st
        { sdrPhase = PhInitTrp
        , sdrTimer = resize (sdrTrpCycles cfg) - 1
        }
    , sdrNopCmd
    )
  PhInitTrp ->
    if sdrTimer st == 0
      then
        ( st {sdrPhase = PhInitRefresh}
        , sdrAutoRefreshCmd
        )
      else
        ( st {sdrTimer = sdrTimer st - 1}
        , sdrNopCmd
        )
  PhInitRefresh ->
    -- Refresh issued this cycle; wait T_RFC then either issue
    -- another refresh or move on to LMR.
    ( st
        { sdrPhase = PhInitTrfc
        , sdrTimer = resize (sdrTrfcCycles cfg) - 1
        }
    , sdrNopCmd
    )
  PhInitTrfc ->
    if sdrTimer st == 0
      then
        if sdrInitRefreshLeft st > 1
          then
            ( st
                { sdrPhase = PhInitRefresh
                , sdrInitRefreshLeft = sdrInitRefreshLeft st - 1
                }
            , sdrAutoRefreshCmd
            )
          else
            ( st {sdrPhase = PhInitLmr}
            , sdrLoadModeRegCmd (sdrCasLatency cfg)
            )
      else
        ( st {sdrTimer = sdrTimer st - 1}
        , sdrNopCmd
        )
  PhInitLmr ->
    -- LMR issued this cycle; wait T_MRD.
    ( st
        { sdrPhase = PhInitTmrd
        , sdrTimer = resize (sdrTmrdCycles cfg) - 1
        }
    , sdrNopCmd
    )
  PhInitTmrd ->
    if sdrTimer st == 0
      then
        ( st {sdrPhase = PhIdle}
        , sdrNopCmd
        )
      else
        ( st {sdrTimer = sdrTimer st - 1}
        , sdrNopCmd
        )
  -- Steady-state phases: not implemented yet. Stay idle, drive NOPs.
  -- This ensures the controller is at least safe (no spurious
  -- commands) until the read/write path lands.
  _ -> (st {sdrPhase = PhIdle}, sdrNopCmd)

-- * Chip behavioral model -------------------------------------------

-- | Output bundle from the chip behavioral model — the chip's
-- response to commands. We model just enough to verify the
-- controller's command sequence is correct: row-bank state
-- tracking, command validation, and a small storage backing
-- (so we can also verify writes/reads commit correctly once
-- the steady-state FSM lands).
data ChipModelOut = ChipModelOut
  { cmoDqOut :: BitVector 16 -- chip → controller (read data)
  , cmoDqOe :: Bool -- chip drives DQ this cycle
  , cmoStateLog :: BitVector 4 -- 0 = idle, 1 = active, 2 = error, 3 = busy
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (NFDataX)

-- | Behavioral chip model. Tracks just enough state to validate
-- that the controller's command sequence respects the chip's
-- protocol. Sim-only; not synthesized.
sdrChipModel ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  Signal dom SdrPins ->
  Signal dom ChipModelOut
sdrChipModel _pinsS =
  -- Stub — chip model goes here as the FSM body matures. Returns
  -- "no read data, idle" by default so unit tests can drive the
  -- controller and check its command-pin sequence directly
  -- (the chip-protocol validation grows in a follow-up commit).
  pure
    ChipModelOut
      { cmoDqOut = 0
      , cmoDqOe = False
      , cmoStateLog = 0
      }
