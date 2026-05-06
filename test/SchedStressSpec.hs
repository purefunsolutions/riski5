-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : SchedStressSpec
Description : Verifies the 'HelloSchedStress' two-task context switch
              firmware in pure-Haskell sim (task #64).

The 'HelloSchedStress' firmware is a minimal cooperative scheduler:
two tasks share an SRAM-backed 14-word context block (ra, sp, s0..s11
— the same field set the kernel saves in @__switch_to@) and yield to
each other via a 'switch_to(curr_ctx, next_ctx)' routine that mirrors
the kernel's @__switch_to@ instruction sequence.

In pure-Haskell sim the firmware should reach a steady state of
@A b . A b . A b . …@ after the @B@ boot byte, where each round
trip prints:

  - @A@   from task 0 just before it switches to task 1
  - @b@   from task 1 just before it switches back to task 0
  - @.@   from task 0 right after resuming, marking the round trip

The test runs for 20 K cycles and asserts at least 5 successful
@A b .@ round trips. If the firmware works in pure-Haskell sim but
hangs on Verilator hwsim or silicon, that's evidence the bug is in
the synthesised core's wake-from-sleep path — exactly the symptom
isolated in #64's 1B-cycle Linux-boot trace.
-}
module SchedStressSpec (
  tests,
) where

import Clash.Prelude (
  BitVector,
  HiddenClockResetEnable,
  Signal,
  System,
  Vec,
  clockGen,
  enableGen,
  fromList,
  resetGen,
  sampleN,
  withClockResetEnable,
 )
import Clash.Prelude qualified as CP
import Clash.Sized.Vector qualified as V
import Data.List qualified as L
import HelloSchedStress (helloSchedStressFirmwareWords)
import Riski5.Soc (SocInFull (..), SocOutSim (..), socSimFullWith)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase)
import Prelude
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "SchedStress"
    [ testCase "two tasks complete >=5 round trips of A b ." case_roundtrips
    ]

-- * Cases ----------------------------------------------------------

case_roundtrips :: Assertion
case_roundtrips = do
  let bytes = runSoc helloSchedStressFirmwareWords 20000
      str = P.map (P.toEnum . P.fromIntegral) bytes :: String
      -- Every successful round trip is the literal "Ab." substring
      -- (task-0 emits A then yields, task-1 emits b then yields back,
      -- task-0 resumes and emits .). We don't care about the leading
      -- 'B' boot byte or any partial trailing iteration.
      countOccurrences :: String -> String -> Int
      countOccurrences needle =
        length . filter ((== needle) . P.take (length needle)) . L.tails
      n = countOccurrences "Ab." str
  assertBool
    ( "Expected >=5 'Ab.' round trips in "
        ++ show (length bytes)
        ++ " UART bytes (got "
        ++ show n
        ++ "). First 80 bytes: "
        ++ show (P.take 80 str)
    )
    (n >= 5)

-- * Harness --------------------------------------------------------

runSoc :: [BitVector 32] -> Int -> [BitVector 8]
runSoc codeWords nCycles =
  let progVec :: Vec 1024 (BitVector 32)
      progVec =
        V.unsafeFromList
          (P.take 1024 (codeWords ++ P.repeat 0x0000_0013))

      dataVec :: Vec 1 (BitVector 32)
      dataVec = CP.repeat 0

      -- 256 K half-words = 512 KB — full DE2 SRAM.
      sramInit :: Vec 262144 (BitVector 16)
      sramInit = CP.repeat 0

      inputSig :: Signal System SocInFull
      inputSig =
        fromList (P.repeat SocInFull {sifSwitches = 0, sifKeys = 0xF})

      go :: (HiddenClockResetEnable System) => Signal System SocOutSim
      go = socSimFullWith False False progVec dataVec sramInit inputSig

      trace =
        sampleN @System nCycles $
          withClockResetEnable @System clockGen resetGen enableGen go
   in [b | SocOutSim {sosUartTx = Just b} <- trace]
