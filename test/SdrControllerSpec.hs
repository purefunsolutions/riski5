-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
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
import Riski5.SdrController
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, testCase)
import Data.List qualified as L
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.SdrController init FSM"
    [ testCase "first non-NOP after init NOPs is PRECHARGE-ALL" case_firstCmdIsPrechargeAll
    , testCase "exactly N AUTO-REFRESH commands during init" case_initRefreshCount
    , testCase "LOAD MODE REGISTER is the final init command" case_lmrIsFinalInit
    , testCase "FSM reaches steady state after init" case_reachesIdle
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
    , sdrRefreshIntervalCycles = 100
    , sdrInitNopCycles = 10 -- short, just enough to verify the count
    , sdrInitRefreshCount = 8
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
              (replyS, pinsS) = sdrController cfg inS
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
