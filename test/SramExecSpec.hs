-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : SramExecSpec
Description : Reproduces the 1:3 B:S sramexec UART-multi-write bug in sim.

The @riski5-core-sramexec@ bitstream produces a @BSSS@ (1 B, 3 S)
byte stream on silicon every iteration of @HelloSramExec@:

  * 'B' is written once by the BRAM-resident bring-up code.
  * Then a JALR redirects to SRAM[0].
  * SRAM[0] = @sw x14, 0(x10)@ writes 'S' to the UART.
  * SRAM[4] = @ebreak@ — traps to @mtvec=0@, restart firmware.

Architectural retire pattern: 1B + 1S per iteration. Silicon shows
1B + 3S. Root cause: the SW at SRAM[0] sits in X-stage with
@dBeOutS@ asserted while the IF stage is mid-multi-cycle SRAM
fetch on @ebreak@ at SRAM[4]. The Altera JTAG-UART IP (and our
'jtagUartAlteraSim' model) commits a byte every cycle the master
holds @wr=True@ with FIFO not full — so each fetch-stall cycle past
the first is another spurious UART transaction.

This spec runs HelloSramExec through 'socSimFullWith' with
@enableSramFetch=True@ (the sramexec bitstream's flag) and asserts
the architectural 1:1 ratio. Without a master-side gating fix in
'Riski5.Soc', the test fails with byte-counts > 1 per S-block,
mirroring the 'BSSS' silicon symptom; with the fix, the test
passes 1:1.
-}
module SramExecSpec (
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
import HelloSramExec (helloSramExecFirmwareWords)
import Riski5.Soc (SocInFull (..), SocOutSim (..), socSimFullWith)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase)
import Prelude
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "SRAM-exec UART multi-write (1:3 B:S diagnostic)"
    [ testCase "HelloSramExec — each iteration prints exactly 1 B and 1 S" case_oneSperBperIteration
    ]

-- * Test --------------------------------------------------------------

{- | Run the @HelloSramExec@ firmware through 'socSimFullWith' with
@enableSramFetch=True@. Slice the captured TX byte stream into
"iterations" (each starting at a 'B' byte = 0x42) and assert that
each iteration has exactly one 'S' byte (= 0x53) before the next
'B'.

Why the slicing instead of a fixed expected list: the sim runs for
a bounded cycle count and may end mid-iteration; iteration count
varies with sim length and any future pipeline tuning. The
__architectural__ contract is "1 B per iteration, 1 S per
iteration" and that's exactly what the slicing tests.
-}
case_oneSperBperIteration :: Assertion
case_oneSperBperIteration = do
  let bytes :: [BitVector 8]
      bytes = runSoc helloSramExecFirmwareWords 4000

      iters :: [(Int, Int)] -- (numB, numS)
      iters = sliceByB bytes

      -- Drop the last (possibly partial) iteration.
      complete :: [(Int, Int)]
      complete = if length iters > 1 then take (length iters - 1) iters else iters

      bad :: [(Int, Int)]
      bad = [it | it <- complete, fst it /= 1 || snd it /= 1]

      msg :: String
      msg =
        "Expected 1 B + 1 S per iteration, got "
          ++ show iters
          ++ " (first "
          ++ show (min 6 (length iters))
          ++ " iterations: "
          ++ show (take 6 iters)
          ++ "). Total complete iterations checked: "
          ++ show (length complete)
          ++ ". Bad iterations: "
          ++ show bad
          ++ ". Raw bytes prefix: "
          ++ show (take 30 bytes)

  assertBool msg (length complete > 0 && null bad)

-- * Helpers ------------------------------------------------------------

-- | Slice a byte stream into iterations starting at each 'B' byte.
-- Returns a list of @(numB, numS)@ counts per iteration.
sliceByB :: [BitVector 8] -> [(Int, Int)]
sliceByB = goPre
 where
  -- Drop bytes before the first B. Anything before isn't part of an
  -- iteration we can score — the firmware might emit warm-up bytes
  -- (in practice it doesn't, but defensively skip).
  goPre [] = []
  goPre (b : rest)
    | b == 0x42 = goIter (1 :: Int) (0 :: Int) rest
    | otherwise = goPre rest

  -- Inside an iteration: count B's (always 1 expected) and S's, then
  -- close the iteration when we see the next B.
  goIter !nB !nS [] = [(nB, nS)]
  goIter !nB !nS (b : rest)
    | b == 0x42 = (nB, nS) : goIter 1 0 rest -- next iteration starts
    | b == 0x53 = goIter nB (nS + 1) rest
    | otherwise = goIter nB nS rest

-- * Harness ------------------------------------------------------------

runSoc :: [BitVector 32] -> Int -> [BitVector 8]
runSoc codeWords nCycles =
  let progVec :: Vec 4096 (BitVector 32)
      progVec = V.unsafeFromList (take 4096 (codeWords ++ P.repeat 0x0000_0013))

      dataVec :: Vec 1 (BitVector 32)
      dataVec = CP.repeat 0

      -- 256 K half-words = 512 KB — full DE2 SRAM.
      sramInit :: Vec 262144 (BitVector 16)
      sramInit = CP.repeat 0

      inputSig :: Signal System SocInFull
      inputSig =
        fromList (P.repeat SocInFull {sifSwitches = 0, sifKeys = 0xF})

      go :: (HiddenClockResetEnable System) => Signal System SocOutSim
      go = socSimFullWith True progVec dataVec sramInit inputSig

      trace =
        sampleN @System nCycles $
          withClockResetEnable @System clockGen resetGen enableGen go
   in [b | SocOutSim {sosUartTx = Just b} <- trace]
