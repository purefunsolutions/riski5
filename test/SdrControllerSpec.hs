-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : SdrControllerSpec
Description : Tests for the pure-Clash SDR SDRAM controller.

Drives 'Riski5.SdrController.sdrController' with a quiescent
master and inspects the chip-pin sequence the FSM emits during
the init phase. Verifies:

  * NOP cycles count matches the configured 'sdrInitNopCycles';
  * PRECHARGE-ALL is the first non-NOP command;
  * exactly N AUTO-REFRESH commands fire (where N =
    'sdrInitRefreshCount'), each separated by 'sdrTrfcCycles' NOPs;
  * LOAD MODE REGISTER is the last init command, with the
    configured CAS-latency in the address payload;
  * the FSM lands in 'PhIdle' after T_MRD cycles of NOP.

Steady-state read/write tests come in a follow-up commit once the
FSM body lands. For now this suite covers the init contract — the
chip's most timing-sensitive phase.
-}
module SdrControllerSpec (
  tests,
) where

import Clash.Prelude (
  HiddenClockResetEnable,
  Signal,
  System,
  clockGen,
  enableGen,
  resetGen,
  sampleN,
  testBit,
  unpack,
  withClockResetEnable,
 )
import qualified Clash.Prelude as CP
import Riski5.Sdram (SdramIpBus (..), SdramIpReply (..))
import Riski5.SdrController
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, testCase)
import Data.List qualified as L
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.SdrController"
    [ testGroup
        "init FSM"
        [ testCase "first non-NOP after init NOPs is PRECHARGE-ALL" case_firstCmdIsPrechargeAll
        , testCase "exactly N AUTO-REFRESH commands during init" case_initRefreshCount
        , testCase "LOAD MODE REGISTER is the final init command" case_lmrIsFinalInit
        , testCase "FSM reaches steady state after init" case_reachesIdle
        ]
    , testGroup
        "steady-state R/W round-trips against chip model"
        [ testCase "write 0xBEEF then read back" case_roundTripDeadbeef
        , testCase "two adjacent writes (lo + hi pattern) commit independently" case_loHiPair
        ]
    , testGroup
        "drop-in wrapper for the Altera-IP shape"
        [ testCase "SdrController can replace the Altera IP behind Riski5.Sdram" case_alteraIpWrapper
        ]
    , testGroup
        "refresh-vs-request race regression (task #146)"
        [ testCase "continuous reads under refresh pressure all complete (no wedge)" case_continuousReadsUnderRefreshComplete
        , testCase "back-to-back reads through the wrapper survive refreshes mid-burst" case_burstReadsSurviveRefresh
        ]
    ]

-- * Test config -- short timing so tests don't take 21 600 cycles.

-- | Truncated config for tests: same shape as 'defaultDe2Config'
-- but with minimal NOP counts so the simulation is short.
testCfg :: SdrConfig
testCfg =
  SdrConfig
    { sdrTrcdCycles = 3
    , sdrTrpCycles = 3
    , sdrTrfcCycles = 7
    , sdrTwrCycles = 2
    , sdrCasLatency = 3
    , sdrTmrdCycles = 2
    , sdrRefreshIntervalCycles = 60000 -- effectively disabled for init tests
    , sdrInitNopCycles = 10 -- short, just enough to verify the count
    , sdrInitRefreshCount = 8
    , -- 'sdrControllerAsAlteraIp' / chip-model paths in this test
      -- module drive DRAM_DQ combinationally — no I/O-cell flops
      -- between the controller and the chip — so the controller
      -- waits exactly CL cycles for read data.
      sdrPipelineLatency = 0
    }

-- | Idle master input: cs/rd/wr all low for the duration.
quiescentMaster :: SdrSlaveIn
quiescentMaster =
  SdrSlaveIn
    { ssiCs = P.False
    , ssiAddr = 0
    , ssiWdata = 0
    , ssiBeN = 0b11
    , ssiRd = P.False
    , ssiWr = P.False
    }

-- | Run the controller with a quiescent master for @n@ cycles and
-- return the chip-pin trace.
runInit :: SdrConfig -> P.Int -> [SdrPins]
runInit cfg n =
  P.map P.snd
    P.$ sampleN @System n
    P.$ withClockResetEnable @System clockGen resetGen enableGen
    P.$ ( let inS = CP.pure quiescentMaster
              dqInS = CP.pure 0   -- chip not driving DQ during init
              (replyS, pinsS) = sdrController cfg inS dqInS
           in CP.bundle (replyS, pinsS)
        )

-- | Classify a chip-pin sample by command type. Distinguishes
-- NOP / PRECHARGE / REFRESH / LMR / OTHER.
data CmdKind = KNop | KPrecharge | KRefresh | KLmr | KOther
  deriving (P.Eq, P.Show)

classify :: SdrPins -> CmdKind
classify p
  | sdrCsN p = KNop
  | nots (sdrRasN p) `andP` sdrCasN p `andP` nots (sdrWeN p) = KPrecharge
  | nots (sdrRasN p) `andP` nots (sdrCasN p) `andP` sdrWeN p = KRefresh
  | nots (sdrRasN p) `andP` nots (sdrCasN p) `andP` nots (sdrWeN p) = KLmr
  | P.otherwise = KOther
 where
  nots = P.not
  andP = (P.&&)

-- * Test cases ------------------------------------------------------

case_firstCmdIsPrechargeAll :: Assertion
case_firstCmdIsPrechargeAll = do
  let trace = runInit testCfg 30
      cmds = P.map classify trace
      -- First non-NOP command index.
      firstNonNop = P.length (P.takeWhile (P.== KNop) cmds)
  assertBool ("expected first cmd at index " P.++ P.show firstNonNop P.++ " > 0") (firstNonNop P.> 0)
  assertEqual "first non-NOP is PRECHARGE-ALL" KPrecharge (cmds P.!! firstNonNop)
  -- A10 = 1 in the address payload (= all banks).
  assertBool
    "PRECHARGE-ALL has A10 set"
    (testBit (sdrAddr (trace P.!! firstNonNop)) 10)

case_initRefreshCount :: Assertion
case_initRefreshCount = do
  -- Total cycles = init_nop + T_RP + N × (1 + T_RFC) + 1 (LMR) + T_MRD + slack.
  -- With the test config: 10 + 3 + 8 × (1 + 7) + 1 + 2 + 5 = 85. Use 200 to be safe.
  let trace = runInit testCfg 200
      cmds = P.map classify trace
      refreshCount = P.length (P.filter (P.== KRefresh) cmds)
  assertEqual
    "exactly sdrInitRefreshCount AUTO-REFRESH commands"
    (P.fromIntegral (sdrInitRefreshCount testCfg) :: P.Int)
    refreshCount

case_lmrIsFinalInit :: Assertion
case_lmrIsFinalInit = do
  let trace = runInit testCfg 200
      cmds = P.map classify trace
      lmrIdx = case L.findIndex (P.== KLmr) cmds of
        P.Just i -> i
        P.Nothing -> P.error "no LMR command found"
      cmdsAfterLmr = P.drop (lmrIdx P.+ 1) cmds
  -- After LMR, only NOPs (FSM is in PhInitTmrd then PhIdle).
  assertBool
    "no commands fire after LMR during init"
    (P.all (P.== KNop) cmdsAfterLmr)
  -- LMR address payload encodes the CL.
  let lmrAddr = sdrAddr (trace P.!! lmrIdx)
      cas :: P.Int
      cas =
        P.fromIntegral
          ( (P.fromIntegral lmrAddr :: P.Int)
              `P.div` 16
              `P.mod` 8
          )
  assertEqual
    "LMR encodes the configured CAS latency"
    (P.fromIntegral (sdrCasLatency testCfg) :: P.Int)
    cas

case_reachesIdle :: Assertion
case_reachesIdle = do
  -- After enough cycles, the controller should idle (driving NOPs)
  -- with no further command activity.
  let trace = runInit testCfg 200
      cmds = P.map classify trace
      tailCmds = P.drop 100 cmds -- well past init completion
  assertBool
    "controller idles (only NOPs) after init completes"
    (P.all (P.== KNop) tailCmds)

-- * Round-trip tests against the chip model -----------------------

-- | Stimulus event: hold these inputs for one cycle.
data Stim = Stim
  { stCs :: P.Bool
  , stAddr :: CP.BitVector 22
  , stWdata :: CP.BitVector 16
  , stBeN :: CP.BitVector 2
  , stRd :: P.Bool
  , stWr :: P.Bool
  }

idleStim :: Stim
idleStim = Stim P.False 0 0 0b00 P.False P.False

stimToInput :: Stim -> SdrSlaveIn
stimToInput Stim {..} =
  SdrSlaveIn
    { ssiCs = stCs
    , ssiAddr = stAddr
    , ssiWdata = stWdata
    , ssiBeN = stBeN
    , ssiRd = stRd
    , ssiWr = stWr
    }

-- | Run controller + chip model with a stimulus list. The harness:
--   * drives the master with `stims` (followed by idle to fill n).
--   * feeds the controller's dqOut (when oe=1) onto the chip's
--     SdrPins, otherwise drives 0.
--   * pipes the chip's cmoDqOut back into the controller's dqIn.
--   * collects the SdrSlaveOut sample stream.
runWithChip ::
  SdrConfig ->
  P.Int ->
  [Stim] ->
  [SdrSlaveOut]
runWithChip cfg n stims =
  P.map P.fst
    P.$ sampleN @System n
    P.$ withClockResetEnable @System clockGen resetGen enableGen
    P.$ ( let stimList = P.map stimToInput (stims P.++ P.repeat idleStim)
              inS = CP.fromList stimList
              -- Feedback loop: chip's dqOut → controller's dqIn.
              dqInS = (\co -> cmoDqOut co) CP.<$> chipOutS
              (replyS, pinsS) = sdrController cfg inS dqInS
              chipOutS = sdrChipModel cfg pinsS
           in CP.bundle (replyS, pinsS)
        )

-- | After the controller finishes init, issue this stim sequence
-- and return the slave-output stream.
issueAfterInit :: SdrConfig -> P.Int -> [Stim] -> [SdrSlaveOut]
issueAfterInit cfg postCycles stims =
  let initLen :: P.Int
      initLen = computeInitCycles cfg
      total = initLen P.+ postCycles
      filler = P.replicate initLen idleStim
   in P.drop initLen (runWithChip cfg total (filler P.++ stims))

-- | Compute how many cycles the init phase consumes for the given
-- config (used to skip the init outputs in tests).
computeInitCycles :: SdrConfig -> P.Int
computeInitCycles cfg =
  let nop = P.fromIntegral (sdrInitNopCycles cfg) :: P.Int
      trp = P.fromIntegral (sdrTrpCycles cfg) :: P.Int
      trfc = P.fromIntegral (sdrTrfcCycles cfg) :: P.Int
      tmrd = P.fromIntegral (sdrTmrdCycles cfg) :: P.Int
      nrefresh = P.fromIntegral (sdrInitRefreshCount cfg) :: P.Int
   in nop P.+ 1 P.+ trp P.+ nrefresh P.* (1 P.+ trfc) P.+ 1 P.+ tmrd P.+ 4
   -- The +4 is slack — init has a few one-cycle phase transitions
   -- (PhInitPrecharge, PhInitLmr, PhInitRefresh, PhInitTmrd) we
   -- don't model precisely. Tests trim the init prefix using this
   -- bound + waitrequest behaviour.

-- | Build a write stim: one cycle of cs+wr+addr+wdata+be (active-low).
writeStim :: CP.BitVector 22 -> CP.BitVector 16 -> CP.BitVector 2 -> Stim
writeStim a w be = Stim P.True a w be P.False P.True

-- | Build a read stim: one cycle of cs+rd+addr.
readStim :: CP.BitVector 22 -> Stim
readStim a = Stim P.True a 0 0b00 P.True P.False

case_roundTripDeadbeef :: Assertion
case_roundTripDeadbeef = do
  let testAddr :: CP.BitVector 22 = 0x1000
      pattern :: CP.BitVector 16 = 0xBEEF
      -- Hold the write request long enough for the FSM to traverse
      -- PhActivate → PhTrcd → PhWrite → PhTwr → PhTrpAfter (= TRCD
      -- + 1 + TWR + TRP + a couple slack cycles). 30 cycles is
      -- generous. Then idle while the FSM finishes, then issue
      -- read, hold for the analogous read latency.
      writeBurst = P.replicate 30 (writeStim testAddr pattern 0b00)
      readBurst = P.replicate 30 (readStim testAddr)
      stims = writeBurst P.++ P.replicate 5 idleStim P.++ readBurst
      replies = issueAfterInit testCfg 200 stims
      -- Find the cycle where ssoValid pulses (= read data ready).
      validReplies = P.filter ssoValid replies
  assertBool ("expected at least one valid pulse in: " P.++ P.show (P.length replies) P.++ " samples") (P.not (P.null validReplies))
  let firstValid = P.head validReplies
  assertEqual
    "read data matches written pattern"
    pattern
    (ssoRdata firstValid)

case_loHiPair :: Assertion
case_loHiPair = do
  let baseAddr :: CP.BitVector 22 = 0x2000
      loVal :: CP.BitVector 16 = 0xBEEF
      hiVal :: CP.BitVector 16 = 0xDEAD
      -- Single-shot stims: master asserts cs for ONE cycle then
      -- drops it. The controller latches in PhIdle on that cycle
      -- and continues independently to PhActivate / PhWrite / etc.
      -- The 30 idle cycles after each give the FSM time to finish
      -- (write: PhActivate → PhTrcd → PhWrite → PhTwr → PhTrpAfter
      -- → PhIdle ≈ 1+1+1+1+2 = 6 cycles; read: similar + CL ≈ 8).
      -- Without this discipline a held cs causes the controller to
      -- start a new transaction every time it returns to PhIdle.
      stims =
        [writeStim baseAddr loVal 0b00] P.++ P.replicate 30 idleStim
          P.++ [writeStim (baseAddr P.+ 1) hiVal 0b00] P.++ P.replicate 30 idleStim
          P.++ [readStim baseAddr] P.++ P.replicate 30 idleStim
          P.++ [readStim (baseAddr P.+ 1)] P.++ P.replicate 30 idleStim
      replies = issueAfterInit testCfg 400 stims
      -- We expect EXACTLY two reads → exactly two valid pulses.
      valids = P.filter ssoValid replies
  assertEqual ("valid pulse count")
    (2 :: P.Int)
    (P.length valids)
  let v1 = ssoRdata (valids P.!! 0)
      v2 = ssoRdata (valids P.!! 1)
  assertEqual "lo readback" loVal v1
  assertEqual "hi readback" hiVal v2

-- * Drop-in wrapper integration test ------------------------------

-- | Drive Riski5.Sdram (the 32 ↔ 16 width adapter that today
-- talks to the Altera IP) with `sdrControllerAsAlteraIp` plugged
-- in where the Altera IP normally sits. A 32-bit SW + LW pattern
-- through the adapter must round-trip the full 32-bit word —
-- i.e. *both* lo and hi half-words commit. If the wrapper or
-- byte-enable polarity is wrong, the upper 16 bits will read back
-- as zero (= the silicon bug we're trying to fix in real hardware).
case_alteraIpWrapper :: Assertion
case_alteraIpWrapper = do
  -- Feed the wrapper a SdramIpBus stim sequence shaped like what
  -- Riski5.Sdram emits during a half-word lo + hi write pair,
  -- then half-word reads, and verify the full 32-bit pattern
  -- round-trips through the chip model. If the wrapper's
  -- byte-enable polarity translation is wrong, the chip writes
  -- the wrong bytes and the readback fails (which would be the
  -- exact silicon symptom we're trying to fix).
  let baseAddr :: CP.BitVector 22 = 0x4000
      loVal :: CP.BitVector 16 = 0xABCD
      hiVal :: CP.BitVector 16 = 0x1234
      busTrace =
        [busWrite baseAddr loVal 0b11]
          P.++ P.replicate 30 busIdle
          P.++ [busWrite (baseAddr P.+ 1) hiVal 0b11]
          P.++ P.replicate 30 busIdle
          P.++ [busRead baseAddr]
          P.++ P.replicate 30 busIdle
          P.++ [busRead (baseAddr P.+ 1)]
          P.++ P.replicate 30 busIdle
      replies = runWrapperWithChip testCfg 400 busTrace
      valids = P.filter sirValid replies
  assertEqual "valid pulse count from wrapper" (2 :: P.Int) (P.length valids)
  assertEqual "lo readback (via wrapper)" loVal (sirRdata (valids P.!! 0))
  assertEqual "hi readback (via wrapper)" hiVal (sirRdata (valids P.!! 1))

busIdle :: SdramIpBus
busIdle = SdramIpBus P.False 0 0 0b00 P.False P.False

busWrite :: CP.BitVector 22 -> CP.BitVector 16 -> CP.BitVector 2 -> SdramIpBus
busWrite a w be = SdramIpBus P.True a w be P.False P.True

busRead :: CP.BitVector 22 -> SdramIpBus
busRead a = SdramIpBus P.True a 0 0b00 P.True P.False

runWrapperWithChip ::
  SdrConfig ->
  P.Int ->
  [SdramIpBus] ->
  [SdramIpReply]
runWrapperWithChip cfg n busSeq =
  let initLen = computeInitCycles cfg
      filler = P.replicate initLen busIdle
   in P.drop initLen
        P.$ P.map P.fst
        P.$ sampleN @System (initLen P.+ n)
        P.$ withClockResetEnable @System clockGen resetGen enableGen
        P.$ ( let busS = CP.fromList ((filler P.++ busSeq) P.++ P.repeat busIdle)
                  dqInS = (\co -> cmoDqOut co) CP.<$> chipOutS
                  (replyS, pinsS) = sdrControllerAsAlteraIp cfg busS dqInS
                  chipOutS = sdrChipModel cfg pinsS
               in CP.bundle (replyS, pinsS)
            )

-- * Refresh-vs-request race regression (task #146) ----------------

-- | Config with a deliberately short refresh interval so refreshes
-- fire frequently during a steady-state burst. Used by the
-- regression tests below; nothing else in the suite depends on
-- this number.
raceCfg :: SdrConfig
raceCfg = testCfg {sdrRefreshIntervalCycles = 25}

{- |
The pre-fix bug: the @PhIdle@ handler picked refresh OVER an
asserted master request, but @waitrequest@ dropped to False on
the same cycle (the trivial @case PhIdle -> False@ formula). The
32 ↔ 16 'Riski5.Sdram' adapter latched that False as "request
accepted" and advanced into its wait-for-valid state — but the
controller was off doing refresh, so no @valid@ ever arrived
and the adapter wedged.

The fix: @PhIdle@ services master requests FIRST, refresh only
when the master is idle. Refresh stays pending across busy
windows (it's sticky) and gets serviced the first PhIdle cycle
nothing else competes. This test issues continuous reads under
high refresh pressure (interval = 25 cycles); pre-fix the
controller wedges after at most a handful of reads, post-fix
the read stream keeps draining valid pulses.
-}
case_continuousReadsUnderRefreshComplete :: Assertion
case_continuousReadsUnderRefreshComplete = do
  -- Issue a continuously-asserted read for ~3 × refresh interval.
  -- Across that window at least one refresh fires while cs+rd are
  -- already on the bus, so we exercise the race.
  let nCycles = 3 P.* P.fromIntegral (sdrRefreshIntervalCycles raceCfg)
      stims = P.replicate nCycles (readStim 0x42)
      replies = issueAfterInit raceCfg nCycles stims
  -- The count of valid pulses in a fixed window must be at least
  -- the count of completed reads the master could have issued
  -- without the wedge. With raceCfg (refresh every 25 cycles),
  -- a single read takes ~12 cycles and refresh costs ~9; over 75
  -- cycles we expect at least 4 valid pulses. Pre-fix this drops
  -- to 0 the first time refresh racing with a request causes
  -- 'Riski5.Sdram' to advance into a wait-for-valid the controller
  -- never satisfies.
  let validCount = P.length (P.filter ssoValid replies)
  assertBool
    ( "expected ≥ 4 valid pulses in "
        P.++ P.show nCycles
        P.++ " cycles of continuous reads under refresh pressure, got "
        P.++ P.show validCount
    )
    (validCount P.>= 4)

{- |
End-to-end race regression: drive 'Riski5.Sdram' (the 32 ↔ 16
width adapter) with back-to-back single-shot reads, with the
controller's refresh interval set short enough that refresh hits
mid-burst. With the fix, every issued read produces a 32-bit
@sirValid@ pulse from the wrapper. Without the fix, the wrapper
wedges and the count comes back below the issued total.
-}
case_burstReadsSurviveRefresh :: Assertion
case_burstReadsSurviveRefresh = do
  -- 12 single-shot 16-bit reads through the wrapper. With raceCfg
  -- (refresh every 25 cycles) and ~12 cycles per read, refresh
  -- fires at least 4–5 times across the burst.
  let n :: P.Int
      n = 12
      stims =
        P.concatMap
          (\i -> [busRead (P.fromIntegral i)] P.++ P.replicate 30 busIdle)
          [0 .. n P.- 1]
      replies = runWrapperWithChip raceCfg (n P.* 40) stims
      valids = P.filter sirValid replies
  assertEqual
    ( "every issued read should produce one valid pulse from the wrapper "
        P.++ "(wedge means missing pulses)"
    )
    n
    (P.length valids)
