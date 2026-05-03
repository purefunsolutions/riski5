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

== Address mapping

22-bit half-word Avalon-MM addr is split into:

@
  bits[7:0]   col   (8-bit column, lower bits = burst order)
  bits[9:8]   bank  (2-bit bank)
  bits[21:10] row   (12-bit row)
@

This puts adjacent half-word writes (the 32→16 adapter's lo + hi
in 'Riski5.Sdram') in the same row + bank, so a 32-bit write only
needs one ACTIVATE.

== Implementation status

- Init sequence: ✅
- Steady-state read/write: ✅ (uses auto-precharge so PRECHARGE is
  implicit per access).
- Background auto-refresh: ✅ (counter triggers at T_REF; refresh
  fires from PhIdle).
- Behavioral chip model ('sdrChipModel'): ✅ Vec-backed memory +
  CL-aware read response.
-}
module Riski5.SdrController (
  -- * Configuration
  SdrConfig (..),
  defaultDe2Config,
  defaultDe2ConfigForClockHz,

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

  -- * Drop-in wrapper for the Altera-IP shape (Riski5.Sdram)
  sdrControllerAsAlteraIp,

  -- * Wrapper variant that registers chip-side IO into FPGA flops
  --   (lets Quartus pack DRAM_* outputs into I/O cells)
  sdrControllerAsAlteraIpRegistered,
) where

import Riski5.Sdram (SdramIpBus (..), SdramIpReply (..))

import Clash.Prelude hiding ((||), (&&), not)
import qualified Clash.Prelude as CP
import Prelude ((||), (&&), not)
import qualified Prelude as P

-- * Configuration ---------------------------------------------------

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
  , -- | Extra cycles to wait between issuing READ and capturing
    -- DQ, on top of the chip's CL. Set this to the round-trip
    -- pipeline depth added by I/O-cell flops between the controller
    -- and the chip pins (1 cycle for FAST_OUTPUT_REGISTER on
    -- DRAM_* outputs + 1 cycle for FAST_INPUT_REGISTER on
    -- DRAM_DQ inputs = 2 total). Set 0 for back-to-back chip
    -- model tests where the controller drives the chip
    -- combinationally.
    sdrPipelineLatency :: Unsigned 4
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (NFDataX)

-- | DE2 IS42S16400-7TL chip config, parameterised by the bus clock
-- frequency in Hz so the cycle-count fields that have an absolute-
-- time constraint scale automatically. Use this when the SoC is
-- built at a non-default clock rate (e.g. @slowClock=true@ at
-- 30 MHz, @verySlowClock=true@ at 20 MHz, or a future
-- multi-PLL split where the SDRAM domain runs at its own rate).
--
-- Time-scaled fields:
--
--   * @sdrRefreshIntervalCycles@ — 4096 rows / 64 ms gives a
--     15.625 µs avg refresh interval per JEDEC. We target 15 µs
--     to leave a small safety margin, so cycles = clockHz × 15e-6.
--   * @sdrInitNopCycles@ — 100 µs power-up delay required by the
--     IS42S16400 spec. cycles = clockHz × 100e-6 + a small margin
--     to round up cleanly.
--
-- The other timings (T_RCD, T_RP, T_RFC, T_WR, T_MRD, CL) are
-- expressed in cycles and are already over-conservative at 40 MHz
-- — they remain safe at slower clocks too (a 3-cycle TRCD at
-- 40 MHz = 75 ns; at 20 MHz = 150 ns; both ≥ 20 ns datasheet
-- minimum). They stay constant.
defaultDe2ConfigForClockHz :: Int -> SdrConfig
defaultDe2ConfigForClockHz clockHz =
  SdrConfig
    { sdrTrcdCycles = 3
    , sdrTrpCycles = 3
    , sdrTrfcCycles = 7
    , sdrTwrCycles = 2
    , sdrCasLatency = 2
    -- ^ CL=2 (was 3 at startup of task #146). Empirically, programming
    --   the IS42S16400 mode register with CL=3 (A6:A4 = 011) put the
    --   chip into BL=2 INTERLEAVED mode despite the LMR's BL field
    --   (A2:A0=000) and single-write override (A9=1) — confirmed by
    --   the LSWP probe + the BL=2 hypothesis test on 2026-05-01:
    --   a single chip WRITE was bursting both col and col XOR 1 with
    --   the same data, and the lo+hi pair of a 32-bit master_write_32
    --   collapsed to (last write wins) = `0xdeaddead` for the
    --   `0xdeadbeef` test pattern. Switching the LMR to CL=2 (=
    --   A6:A4=010) made the chip behave as the LMR's other bits
    --   asked (BL=1, sequential, single-write), and every test
    --   pattern reads back correctly. At 40 MHz / 25 ns period
    --   either CL=2 or CL=3 satisfies t_AC, so CL=2 is just
    --   conservative. The controller's PhCl wait still uses
    --   `sdrCasLatency cfg + sdrPipelineLatency cfg - 1` so this
    --   change is self-consistent.
    , sdrTmrdCycles = 2
    , sdrRefreshIntervalCycles =
        -- 15 µs target = clockHz × 15 / 1_000_000. Integer division
        -- floors, which is fine — slightly faster refresh is always
        -- safe (only a power/perf concern, not a correctness one).
        -- At 40 MHz: 600. At 30 MHz: 450. At 20 MHz: 300.
        fromIntegral (clockHz P.* (15 :: P.Int) `P.div` 1_000_000)
    , sdrInitNopCycles =
        -- 100 µs spec minimum. Add a 100-cycle pad on top so even
        -- low clocks round up well above the threshold.
        -- At 40 MHz: 4100. At 30 MHz: 3100. At 20 MHz: 2100.
        fromIntegral (clockHz P.* (100 :: P.Int) `P.div` 1_000_000 P.+ 100)
    , sdrInitRefreshCount = 8
    , sdrPipelineLatency = 2 -- 1 cycle output reg + 1 cycle input reg
    -- ^ Matches 'sdrControllerAsAlteraIpRegistered' which adds an
    -- I/O-cell flop layer on the chip-side pins. With combinational
    -- pin output (raw 'sdrControllerAsAlteraIp'), set to 0.
    }

-- | 40 MHz default config — preserves prior behaviour for callers
-- that haven't been updated to pass an explicit frequency. All
-- existing test/firmware imports of @defaultDe2Config@ keep working
-- with no change.
--
-- Equivalent to @defaultDe2ConfigForClockHz 40_000_000@: yields
-- @sdrRefreshIntervalCycles = 600@, @sdrInitNopCycles = 4100@.
defaultDe2Config :: SdrConfig
defaultDe2Config = defaultDe2ConfigForClockHz 40_000_000

-- * Chip-side I/O ---------------------------------------------------

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

-- | Idle / NOP cycle. CKE held high; chip-select de-asserted.
sdrIdleCmd :: SdrPins
sdrIdleCmd =
  SdrPins
    { sdrAddr = 0
    , sdrBa = 0
    , sdrCasN = True
    , sdrCke = True
    , sdrCsN = True
    , sdrDqOut = 0
    , sdrDqOe = False
    , sdrDqm = 0b11
    , sdrRasN = True
    , sdrWeN = True
    }

sdrNopCmd :: SdrPins
sdrNopCmd = sdrIdleCmd

sdrPrechargeAllCmd :: SdrPins
sdrPrechargeAllCmd =
  sdrIdleCmd
    { sdrCsN = False
    , sdrRasN = False
    , sdrCasN = True
    , sdrWeN = False
    , sdrAddr = bit 10
    }

sdrAutoRefreshCmd :: SdrPins
sdrAutoRefreshCmd =
  sdrIdleCmd
    { sdrCsN = False
    , sdrRasN = False
    , sdrCasN = False
    , sdrWeN = True
    }

-- | LOAD MODE REGISTER. Sets:
--
--   * @A9 = 1@: single-bit write mode (writes are always BL=1
--     regardless of the burst-length field).
--   * @A6:A4 = cas@: CAS latency (010 = 2, 011 = 3).
--   * @A3 = 0@: sequential burst order (don't-care for BL=1 reads).
--   * @A2:A0 = 000@: read burst length = 1 beat. The earlier value
--     @001@ programmed BL=2 and made every READ return two beats
--     where we only sampled the first; the chip then sat in the
--     second-beat / auto-precharge window during the cycles the
--     controller assumed it was idle, which corrupted back-to-back
--     accesses on real silicon.
sdrLoadModeRegCmd :: Unsigned 4 -> SdrPins
sdrLoadModeRegCmd cas =
  sdrIdleCmd
    { sdrCsN = False
    , sdrRasN = False
    , sdrCasN = False
    , sdrWeN = False
    , sdrBa = 0
    , sdrAddr =
        bit 9
          .|. (resize (pack cas) `shiftL` 4)
          .|. 0b000
    }

-- | ACTIVATE row in bank.
sdrActivateCmd :: BitVector 2 -> BitVector 12 -> SdrPins
sdrActivateCmd ba row =
  sdrIdleCmd
    { sdrCsN = False
    , sdrRasN = False
    , sdrCasN = True
    , sdrWeN = True
    , sdrBa = ba
    , sdrAddr = row
    }

-- | READ with auto-precharge (A10=1). Column in addr bits[7:0].
-- DQM=0 (don't mask reads).
sdrReadCmd :: BitVector 2 -> BitVector 8 -> SdrPins
sdrReadCmd ba col =
  sdrIdleCmd
    { sdrCsN = False
    , sdrRasN = True
    , sdrCasN = False
    , sdrWeN = True
    , sdrBa = ba
    , sdrAddr = (bit 10) .|. resize col -- A10 = 1 → auto-precharge
    , sdrDqm = 0b00
    }

-- | WRITE with auto-precharge (A10=1). Column in addr bits[7:0].
-- DQM = byte-enable mask (active high — ~beN).
sdrWriteCmd :: BitVector 2 -> BitVector 8 -> BitVector 16 -> BitVector 2 -> SdrPins
sdrWriteCmd ba col wdata beN =
  sdrIdleCmd
    { sdrCsN = False
    , sdrRasN = True
    , sdrCasN = False
    , sdrWeN = False
    , sdrBa = ba
    , sdrAddr = (bit 10) .|. resize col
    , sdrDqOut = wdata
    , sdrDqOe = True
    , sdrDqm = beN -- chip's DQM is active-high; beN is also active-high (Avalon byte-enable's "n" suffix is for the IP convention)
    }

-- * Avalon-MM slave -------------------------------------------------

data SdrSlaveIn = SdrSlaveIn
  { ssiCs :: Bool
  , ssiAddr :: BitVector 22
  , ssiWdata :: BitVector 16
  , ssiBeN :: BitVector 2
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
  = PhInitNop
  | PhInitPrecharge
  | PhInitTrp
  | PhInitRefresh
  | PhInitTrfc
  | PhInitLmr
  | PhInitTmrd
  | PhIdle
  | PhActivate
  | PhTrcd
  | PhRead
  | PhCl
  | PhCapture
  | PhWrite
  | PhTwr
  | PhTrpAfter
  | PhRefresh
  | PhTrfc
  deriving stock (Generic, Eq, Show)
  deriving anyclass (NFDataX)

data SdrState = SdrState
  { sdrPhase :: SdrPhase
  , sdrTimer :: Unsigned 16
  , sdrInitRefreshLeft :: Unsigned 4
  , sdrRefreshClock :: Unsigned 16
  , sdrRefreshPending :: Bool
  , -- Latched master request, used by PhActivate / PhRead / PhWrite.
    sdrLatchedAddr :: BitVector 22
  , sdrLatchedWdata :: BitVector 16
  , sdrLatchedBeN :: BitVector 2
  , sdrLatchedIsWrite :: Bool
  , -- Read-data sample (set in PhCapture).
    sdrLatchedRdata :: BitVector 16
  , sdrLatchedValid :: Bool
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
    , sdrRefreshPending = P.False
    , sdrLatchedAddr = 0
    , sdrLatchedWdata = 0
    , sdrLatchedBeN = 0b11
    , sdrLatchedIsWrite = P.False
    , sdrLatchedRdata = 0
    , sdrLatchedValid = P.False
    }

-- * Address decomposition -----------------------------------------

addrBank :: BitVector 22 -> BitVector 2
addrBank a = slice d9 d8 a

addrRow :: BitVector 22 -> BitVector 12
addrRow a = slice d21 d10 a

addrCol :: BitVector 22 -> BitVector 8
addrCol a = slice d7 d0 a

-- * Controller entity ----------------------------------------------

{- |
The SDR SDRAM controller. Single Avalon-MM slave port + chip-side
pins + chip→controller DQ input.
-}
sdrController ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  SdrConfig ->
  -- | Master-side request.
  Signal dom SdrSlaveIn ->
  -- | Chip → FPGA DQ input (= what the chip drives during reads).
  Signal dom (BitVector 16) ->
  ( Signal dom SdrSlaveOut
  , Signal dom SdrPins
  )
sdrController cfg inS dqInS = (replyS, pinsS)
 where
  inputBundle = bundle (inS, dqInS)
  (replyS, pinsS) = unbundle (mealy step (initState cfg) inputBundle)

  step :: SdrState -> (SdrSlaveIn, BitVector 16) -> (SdrState, (SdrSlaveOut, SdrPins))
  step st (i, dqIn) = (st', (sso, pins))
   where
    (st', pins) = advance cfg st i dqIn
    -- waitrequest=False on the cycle the controller accepts the
    -- master's request (the PhIdle cycle that transitions to
    -- PhActivate). The previous version dropped waitrequest=False
    -- on EVERY PhIdle cycle, including the cycle where a pending
    -- refresh preempts the request and the controller transitions
    -- to PhRefresh instead. The 32↔16 'Riski5.Sdram' adapter
    -- interpreted that drop as "request accepted" and advanced
    -- from S{Read,Write}{Lo,Hi}Req to a wait state — but the
    -- controller never started the request (it serviced refresh
    -- instead), so no @valid@ pulse ever came back, and
    -- 'Riski5.Sdram' wedged in S{Read,Write}LoWait / SReadHiReq
    -- forever. Symptom on real silicon (task #146): a sustained
    -- back-to-back master_read_32 burst hung intermittently after
    -- ~one row of cells, with the JTAG-Master IP timing out at
    -- 60 s. The hang aligned with a refresh boundary: ~600 cycles
    -- of refresh interval / ~12 cycles per Avalon transaction =
    -- a ~2 % chance per transaction that refresh fires while
    -- 'Sdram' has a request in flight.
    -- waitrequest=True except when in PhIdle. Fix for the
    -- task #146 refresh-vs-request race lives in the PhIdle
    -- handler in 'advance' (it defers refresh by one transaction
    -- when the master is asserting), so wr stays exactly as the
    -- pre-fix code synthesised. Anything wider here perturbs
    -- Quartus's place-and-route enough to corrupt BRAM/SRAM
    -- access on the CoreMark variant, even when STA closes.
    wr = case sdrPhase st of
      PhIdle -> P.False
      _ -> P.True
    sso =
      SdrSlaveOut
        { ssoRdata = sdrLatchedRdata st
        , ssoValid = sdrLatchedValid st
        , ssoWaitrequest = wr
        }

-- | Advance the FSM by one cycle. Pure step function; tests can
-- drive directly without a chip model.
advance ::
  SdrConfig ->
  SdrState ->
  SdrSlaveIn ->
  -- | dqIn (chip → controller, used by PhCl → PhCapture)
  BitVector 16 ->
  (SdrState, SdrPins)
advance cfg st i dqIn =
  -- Clear any single-cycle valid pulse before the per-phase logic
  -- decides whether to set it again this cycle.
  let st0 = st {sdrLatchedValid = P.False}
   in case sdrPhase st0 of
        --
        -- INIT
        --
        PhInitNop ->
          if sdrTimer st0 == 0
            then (st0 {sdrPhase = PhInitPrecharge}, sdrPrechargeAllCmd)
            else (st0 {sdrTimer = sdrTimer st0 - 1}, sdrNopCmd)
        PhInitPrecharge ->
          ( st0
              { sdrPhase = PhInitTrp
              , sdrTimer = resize (sdrTrpCycles cfg) - 1
              }
          , sdrNopCmd
          )
        PhInitTrp ->
          if sdrTimer st0 == 0
            then (st0 {sdrPhase = PhInitRefresh}, sdrAutoRefreshCmd)
            else (st0 {sdrTimer = sdrTimer st0 - 1}, sdrNopCmd)
        PhInitRefresh ->
          ( st0
              { sdrPhase = PhInitTrfc
              , sdrTimer = resize (sdrTrfcCycles cfg) - 1
              }
          , sdrNopCmd
          )
        PhInitTrfc ->
          if sdrTimer st0 == 0
            then
              if sdrInitRefreshLeft st0 > 1
                then
                  ( st0
                      { sdrPhase = PhInitRefresh
                      , sdrInitRefreshLeft = sdrInitRefreshLeft st0 - 1
                      }
                  , sdrAutoRefreshCmd
                  )
                else
                  ( st0 {sdrPhase = PhInitLmr}
                  , sdrLoadModeRegCmd (sdrCasLatency cfg)
                  )
            else (st0 {sdrTimer = sdrTimer st0 - 1}, sdrNopCmd)
        PhInitLmr ->
          ( st0
              { sdrPhase = PhInitTmrd
              , sdrTimer = resize (sdrTmrdCycles cfg) - 1
              }
          , sdrNopCmd
          )
        PhInitTmrd ->
          if sdrTimer st0 == 0
            then (resetRefreshClock st0 {sdrPhase = PhIdle}, sdrNopCmd)
            else (st0 {sdrTimer = sdrTimer st0 - 1}, sdrNopCmd)
        --
        -- IDLE — pick refresh, master request, or stay idle.
        --
        -- Refresh is gated by `not masterReq` so it never preempts
        -- a request the master has on the bus. The wr signal
        -- (= ssoWaitrequest) is forced to False on this cycle by
        -- the trivial 'PhIdle -> False' formula above; if we
        -- preempted with refresh while the master had cs+rd/wr
        -- asserted, the 32 ↔ 16 'Riski5.Sdram' adapter would
        -- latch that drop as "request accepted" on its next clock
        -- edge, advance into a wait-for-valid state, and never
        -- get a valid back (controller went to refresh, not the
        -- read). Symptom on real silicon (task #146): a sustained
        -- back-to-back master_read_32 burst hung intermittently
        -- after ~one row of cells; refresh aligned with a request
        -- roughly every 50 chip transactions (= 600 cycle interval
        -- / ~12 cycles per transaction). With the gate, refresh
        -- stays pending (it's sticky) and fires the first PhIdle
        -- cycle the master is quiet — safe because the chip's
        -- per-row refresh budget (~32 ms cumulative) is huge
        -- compared to the longest plausible un-broken request
        -- burst (a 256-word kernel chunk = ~6 ms, well inside
        -- budget).
        --
        -- Implementation note: branch order is preserved from the
        -- pre-fix version (refresh-then-request-then-idle) to
        -- minimise the diff Clash emits to Quartus. Reordering or
        -- restructuring this case statement perturbs Quartus's
        -- place-and-route enough to corrupt BRAM/SRAM access on
        -- the CoreMark variant, even when STA closes (commit
        -- e4248e0 took a non-functional CoreMark hit from the
        -- "swap if-statements" version of this fix). The added
        -- @&& not masterReq@ on the refresh guard is small enough
        -- that Clash keeps wire numbering stable.
        PhIdle ->
          let st1 = tickRefresh cfg st0
              masterReq = ssiCs i && (ssiRd i || ssiWr i)
           in if sdrRefreshPending st1 && not masterReq
                then
                  ( st1
                      { sdrPhase = PhRefresh
                      , sdrRefreshPending = P.False
                      }
                  , sdrAutoRefreshCmd
                  )
                else
                  if masterReq
                    then
                      ( st1
                          { sdrPhase = PhActivate
                          , sdrLatchedAddr = ssiAddr i
                          , sdrLatchedWdata = ssiWdata i
                          , sdrLatchedBeN = ssiBeN i
                          , sdrLatchedIsWrite = ssiWr i
                          }
                      , sdrActivateCmd (addrBank (ssiAddr i)) (addrRow (ssiAddr i))
                      )
                    else (st1, sdrNopCmd)
        --
        -- READ / WRITE path
        --
        PhActivate ->
          ( st0
              { sdrPhase = PhTrcd
              , sdrTimer = resize (sdrTrcdCycles cfg) - 2
              -- ^ TRCD-2 NOPs in PhTrcd; ACTIVATE counted as cycle 0,
              -- READ/WRITE issues TRCD cycles after ACTIVATE.
              }
          , sdrNopCmd
          )
        PhTrcd ->
          if sdrTimer st0 == 0
            then
              if sdrLatchedIsWrite st0
                then (st0 {sdrPhase = PhWrite}, writeCmdFromState st0)
                else (st0 {sdrPhase = PhRead}, readCmdFromState st0)
            else (st0 {sdrTimer = sdrTimer st0 - 1}, sdrNopCmd)
        PhWrite ->
          ( st0
              { sdrPhase = PhTwr
              , sdrTimer = resize (sdrTwrCycles cfg) - 1
              }
          , sdrNopCmd
          )
        PhTwr ->
          if sdrTimer st0 == 0
            then
              ( st0
                  { sdrPhase = PhTrpAfter
                  , sdrTimer = resize (sdrTrpCycles cfg) - 1
                  }
              , sdrNopCmd
              )
            else (st0 {sdrTimer = sdrTimer st0 - 1}, sdrNopCmd)
        PhRead ->
          ( st0
              { sdrPhase = PhCl
              , sdrTimer = resize (sdrCasLatency cfg + sdrPipelineLatency cfg) - 1
              -- ^ READ counted as cycle 0; data on DQ at cycle CL.
              -- 'sdrPipelineLatency' adds round-trip cycles for any
              -- I/O-cell flops the wrapper inserts between this
              -- controller and the chip pins (see SdrConfig docs).
              }
          , sdrNopCmd
          )
        PhCl ->
          if sdrTimer st0 == 0
            then
              ( st0
                  { sdrPhase = PhCapture
                  , sdrLatchedRdata = dqIn
                  , sdrLatchedValid = P.True
                  }
              , sdrNopCmd
              )
            else (st0 {sdrTimer = sdrTimer st0 - 1}, sdrNopCmd)
        PhCapture ->
          ( st0
              { sdrPhase = PhTrpAfter
              , sdrTimer = resize (sdrTrpCycles cfg) - 1
              }
          , sdrNopCmd
          )
        PhTrpAfter ->
          if sdrTimer st0 == 0
            then (st0 {sdrPhase = PhIdle}, sdrNopCmd)
            else (st0 {sdrTimer = sdrTimer st0 - 1}, sdrNopCmd)
        --
        -- BACKGROUND REFRESH
        --
        PhRefresh ->
          ( st0
              { sdrPhase = PhTrfc
              , sdrTimer = resize (sdrTrfcCycles cfg) - 1
              }
          , sdrNopCmd
          )
        PhTrfc ->
          if sdrTimer st0 == 0
            then (resetRefreshClock st0 {sdrPhase = PhIdle}, sdrNopCmd)
            else (st0 {sdrTimer = sdrTimer st0 - 1}, sdrNopCmd)

-- | Increment the refresh counter; set the pending flag when it
-- crosses the configured interval. Always returns the (possibly
-- updated) state.
tickRefresh :: SdrConfig -> SdrState -> SdrState
tickRefresh cfg st =
  let next = sdrRefreshClock st + 1
   in if next >= sdrRefreshIntervalCycles cfg
        then
          st
            { sdrRefreshClock = 0
            , sdrRefreshPending = P.True
            }
        else st {sdrRefreshClock = next}

-- | Reset the refresh counter (called when a refresh has just
-- been issued).
resetRefreshClock :: SdrState -> SdrState
resetRefreshClock st = st {sdrRefreshClock = 0, sdrRefreshPending = P.False}

readCmdFromState :: SdrState -> SdrPins
readCmdFromState st =
  sdrReadCmd
    (addrBank (sdrLatchedAddr st))
    (addrCol (sdrLatchedAddr st))

writeCmdFromState :: SdrState -> SdrPins
writeCmdFromState st =
  sdrWriteCmd
    (addrBank (sdrLatchedAddr st))
    (addrCol (sdrLatchedAddr st))
    (sdrLatchedWdata st)
    (sdrLatchedBeN st)

-- * Chip behavioral model -------------------------------------------

-- | Output bundle from the chip behavioral model.
data ChipModelOut = ChipModelOut
  { cmoDqOut :: BitVector 16
  , cmoDqOe :: Bool
  -- ^ Currently always False — the model returns read data via
  -- cmoDqOut on the cycle the controller's PhCl wait expires;
  -- the controller's PhCl is wired to sample DQ then so dqOe is
  -- redundant in this sim path.
  , cmoStateLog :: BitVector 4
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (NFDataX)

-- | Behavioral chip model. Tracks per-bank active row + a small
-- Vec-backed memory. Read latency = CL (matches the controller's
-- PhCl wait). Sim-only.
sdrChipModel ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  SdrConfig ->
  Signal dom SdrPins ->
  Signal dom ChipModelOut
sdrChipModel cfg pinsS = outS
 where
  -- 1 KiB Vec backing — adequate for unit tests targeting a
  -- handful of addresses. Real hardware has 4M half-words; the
  -- model uses (addr `mod` 1024) so any test address maps somewhere.
  outS = mealy chipStep initChip pinsS

  initChip :: ChipState
  initChip =
    ChipState
      { csMem = repeat 0
      , csReadPipe = repeat 0
      , csReadValidPipe = repeat P.False
      , csActiveRow = repeat 0
      , csActiveBankValid = repeat P.False
      }

  chipStep :: ChipState -> SdrPins -> (ChipState, ChipModelOut)
  chipStep cs pins =
    let
      -- decode command
      cmd = decodeChipCmd pins
      -- Shift the read pipeline (oldest entry comes out, drop it).
      pipeShifted :: Vec 8 (BitVector 16)
      pipeShifted = drop d1 (csReadPipe cs) :< 0
      validShifted :: Vec 8 Bool
      validShifted = drop d1 (csReadValidPipe cs) :< P.False
      currOut = head (csReadPipe cs)
      currValid = head (csReadValidPipe cs)
      cs0 =
        cs
          { csReadPipe = pipeShifted
          , csReadValidPipe = validShifted
          }
      cs1 = case cmd of
        ChipActivate ba row ->
          cs0
            { csActiveRow = replace ba row (csActiveRow cs0)
            , csActiveBankValid = replace ba P.True (csActiveBankValid cs0)
            }
        ChipRead ba col ->
          let row = csActiveRow cs0 !! ba
              addr = chipFlatAddr ba row col
              memVal = csMem cs0 !! addr
              -- Schedule the read response at offset CL into the pipe.
              clIdx :: Index 8
              clIdx = fromIntegral (sdrCasLatency cfg)
              newPipe = replace clIdx memVal (csReadPipe cs0)
              newValid = replace clIdx P.True (csReadValidPipe cs0)
           in cs0 {csReadPipe = newPipe, csReadValidPipe = newValid}
        ChipWrite ba col wdata dqm ->
          let row = csActiveRow cs0 !! ba
              addr = chipFlatAddr ba row col
              old = csMem cs0 !! addr
              -- Active-high DQM: dqm[k]=1 means MASK byte k.
              new =
                ( if testBit dqm 0
                    then slice d7 d0 old
                    else slice d7 d0 wdata
                )
                  ++# ( if testBit dqm 1
                          then slice d15 d8 old
                          else slice d15 d8 wdata
                      )
              new16 =
                ( if testBit dqm 1
                    then slice d15 d8 old
                    else slice d15 d8 wdata
                )
                  ++# ( if testBit dqm 0
                          then slice d7 d0 old
                          else slice d7 d0 wdata
                      )
              _ = new -- avoid unused warning
           in cs0 {csMem = replace addr new16 (csMem cs0)}
        _ -> cs0
     in
      ( cs1
      , ChipModelOut
          { cmoDqOut = currOut
          , cmoDqOe = currValid
          , cmoStateLog = if currValid then 1 else 0
          }
      )

-- | Internal chip-model state.
data ChipState = ChipState
  { csMem :: Vec 1024 (BitVector 16)
  , csReadPipe :: Vec 8 (BitVector 16)
  -- ^ pipeline of pending read responses, shifted each cycle.
  -- Entry [k] is the read data due in k cycles. d8 covers any
  -- CL up to 7 (chip max).
  , csReadValidPipe :: Vec 8 Bool
  , csActiveRow :: Vec 4 (BitVector 12)
  -- ^ per-bank active row (one of 4 banks).
  , csActiveBankValid :: Vec 4 Bool
  }
  deriving stock (Generic)
  deriving anyclass (NFDataX)

-- | Flatten (bank, row, col) into a 1024-entry Vec index. Uses
-- only the lower 10 bits of the (row * 1024 + bank * 256 + col)
-- mapping so the model stays small. Tests target a few addresses
-- chosen so they don't collide.
chipFlatAddr :: Index 4 -> BitVector 12 -> BitVector 8 -> Index 1024
chipFlatAddr _ba row col =
  let rowU :: Unsigned 12 = unpack row
      colU :: Unsigned 8 = unpack col
      r2 :: Unsigned 2 = resize rowU
      flat :: Unsigned 10 = (resize r2 `shiftL` 8) .|. resize colU
   in fromIntegral flat

-- | Decoded chip command shape.
data ChipCmd
  = ChipNop
  | ChipActivate (Index 4) (BitVector 12)
  | ChipRead (Index 4) (BitVector 8)
  | ChipWrite (Index 4) (BitVector 8) (BitVector 16) (BitVector 2)
  | ChipPrechargeAll
  | ChipAutoRefresh
  | ChipLoadMode
  deriving (P.Eq, P.Show, Generic, NFDataX)

-- * Drop-in wrapper for the Altera IP shape ----------------------

{- |
Adapt 'sdrController' to the same port shape Riski5.Sdram already
expects from the Altera IP. Lets us swap the IP for our own
controller in 'Riski5.Soc' with a one-line change:

  -- before:
  --   sdramReplyS = siSdramReply <$> inS

  -- after:
  --   (sdramReplyS, sdrPinsS) = sdrControllerAsAlteraIp defaultDe2Config sdramBusS dqInS

The wrapper translates:

  * 'sibBe' (active-high byte enable from Sdram.hs) → 'ssiBeN'
    (active-low input expected by sdrController, which forwards it
    directly to the chip's active-high DQM mask: be=11 → DQM=00 →
    write both bytes).
  * 'sibRd' / 'sibWr' / 'sibCs' → 'ssiRd' / 'ssiWr' / 'ssiCs' (1:1).
  * 'SdrSlaveOut' → 'SdramIpReply' (1:1 except field names).
-}
sdrControllerAsAlteraIp ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  SdrConfig ->
  -- | Master-side request (Sdram.hs's busS output).
  Signal dom SdramIpBus ->
  -- | Chip → FPGA DQ (during reads).
  Signal dom (BitVector 16) ->
  ( -- | Slave reply (becomes Sdram.hs's replyS input).
    Signal dom SdramIpReply
  , -- | Chip-side pins (drive DRAM_* out of the SoC).
    Signal dom SdrPins
  )
sdrControllerAsAlteraIp cfg busS dqInS = (replyS, pinsS)
 where
  inS = adaptIn CP.<$> busS
  (sloS, pinsS) = sdrController cfg inS dqInS
  replyS = adaptOut CP.<$> sloS

  adaptIn :: SdramIpBus -> SdrSlaveIn
  adaptIn b =
    SdrSlaveIn
      { ssiCs = sibCs b
      , ssiAddr = sibAddr b
      , ssiWdata = sibWdata b
      , -- Sdram.hs gives sibBe ACTIVE-HIGH ("1 = write that byte").
        -- sdrController's ssiBeN is "value passed unchanged to the
        -- chip's DQM input" (chip DQM=1 = mask). So we need to
        -- INVERT sibBe → DQM. (For sibBe=11: DQM=00 = both bytes
        -- written; for sibBe=01: DQM=10 = only byte 0 written.)
        ssiBeN = complement (sibBe b)
      , ssiRd = sibRd b
      , ssiWr = sibWr b
      }

  adaptOut :: SdrSlaveOut -> SdramIpReply
  adaptOut o =
    SdramIpReply
      { sirRdata = ssoRdata o
      , sirValid = ssoValid o
      , sirWaitrequest = ssoWaitrequest o
      }

{- |
Same as 'sdrControllerAsAlteraIp' but inserts an extra clkBus-domain
register on the chip-side outputs and on the DQ input, so Quartus
can pack the boundary flops into Cyclone II I/O cells (with the
@FAST_OUTPUT_REGISTER@ / @FAST_OUTPUT_ENABLE_REGISTER@ /
@FAST_INPUT_REGISTER@ assignments in @Riski5.qsf@). The shorter,
fixed Tco out of the I/O register is what makes the board's setup
window predictable enough to honour SDC @set_output_delay@ /
@set_input_delay@ against the @+90°@-shifted @DRAM_CLK@ in
@Riski5.sdc@.

Costs:

  * One extra clkBus cycle of latency on every chip-bound signal
    (commands, address, write data, byte mask).
  * One extra clkBus cycle of latency on captured read data.
  * The controller's read-wait state ('PhCl') has to count
    @sdrCasLatency cfg + sdrPipelineLatency cfg - 1@ cycles
    instead of @sdrCasLatency cfg - 1@; set
    @sdrPipelineLatency = 2@ in 'SdrConfig' to compensate.

Use this wrapper for silicon (the DE2 SoC's 'Top.hs' does); use
the unregistered 'sdrControllerAsAlteraIp' for sim tests that
drive the chip model combinationally.
-}
sdrControllerAsAlteraIpRegistered ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  SdrConfig ->
  -- | Master-side request (Sdram.hs's busS output).
  Signal dom SdramIpBus ->
  -- | Chip → FPGA DQ (during reads).
  Signal dom (BitVector 16) ->
  ( -- | Slave reply (becomes Sdram.hs's replyS input).
    Signal dom SdramIpReply
  , -- | Chip-side pins (drive DRAM_* out of the SoC).
    Signal dom SdrPins
  )
sdrControllerAsAlteraIpRegistered cfg busS dqInRawS = (replyS, pinsRegisteredS)
 where
  -- Register the chip's DQ input so Quartus can park the
  -- input-side flop in the I/O cell ('FAST_INPUT_REGISTER ON' on
  -- DRAM_DQ in Riski5.qsf). One clkBus-cycle delay; matched by
  -- 'sdrPipelineLatency' in defaultDe2Config.
  dqInS = register 0 dqInRawS
  (replyS, pinsRawS) = sdrControllerAsAlteraIp cfg busS dqInS
  -- Register the chip-side pins so Quartus can park each output
  -- flop in the I/O cell ('FAST_OUTPUT_REGISTER ON' / OE on each
  -- DRAM_* pin in Riski5.qsf). One clkBus-cycle delay; matched by
  -- the same 'sdrPipelineLatency' field.
  pinsRegisteredS = register sdrIdleCmd pinsRawS

decodeChipCmd :: SdrPins -> ChipCmd
decodeChipCmd p
  | sdrCsN p = ChipNop
  | not (sdrRasN p) && sdrCasN p && sdrWeN p =
      ChipActivate (fromIntegral (unpack (sdrBa p) :: Unsigned 2)) (sdrAddr p)
  | sdrRasN p && not (sdrCasN p) && sdrWeN p =
      ChipRead (fromIntegral (unpack (sdrBa p) :: Unsigned 2)) (slice d7 d0 (sdrAddr p))
  | sdrRasN p && not (sdrCasN p) && not (sdrWeN p) =
      ChipWrite
        (fromIntegral (unpack (sdrBa p) :: Unsigned 2))
        (slice d7 d0 (sdrAddr p))
        (sdrDqOut p)
        (sdrDqm p)
  | not (sdrRasN p) && sdrCasN p && not (sdrWeN p) = ChipPrechargeAll
  | not (sdrRasN p) && not (sdrCasN p) && sdrWeN p = ChipAutoRefresh
  | not (sdrRasN p) && not (sdrCasN p) && not (sdrWeN p) = ChipLoadMode
  | P.otherwise = ChipNop
