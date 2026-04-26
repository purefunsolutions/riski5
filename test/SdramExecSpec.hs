-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : SdramExecSpec
Description : SDRAM-execution architectural contract — 1 B + 1 S per iteration.

The SDRAM-execution counterpart to 'SramExecSpec'. The
@riski5-core-sdramexec@ bitstream's @HelloSdramExec@ firmware is
expected to produce a strictly @BSBSBS…@ byte stream — one @B@
written from BRAM-resident bring-up, one @S@ written by the
SDRAM-resident @sw@. Anything else (extra @S@ bytes per
iteration, infinite @B@ stream, mid-iteration garbage) is a
regression in the SDRAM-fetch path.

The test exercises the architectural contract in Verilator-free
Clash sim by running @HelloSdramExec@ through 'socSimFullWith'
with @enableSdramFetch=True@ (the @sdramexec@ bitstream's flag).
Since the @sdramIpSim@ model has 1-cycle valid latency and the
'Riski5.Sdram' adapter does two 16-bit Avalon transactions per
32-bit word, each SDRAM op takes ~4-5 cycles — comfortably below
the 6000-cycle bound used here for ~80 iterations of headroom.

Same byte-slicing approach as 'SramExecSpec' so the assertion
shape is "every complete iteration has exactly one @B@ and one
@S@". The last (potentially partial) iteration is dropped.
-}
module SdramExecSpec (
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
import HelloSdramExec (helloSdramExecFirmwareWords)
import Riski5.Soc (SocInFull (..), SocOutSim (..), socSimFullWith)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase)
import Prelude
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "SDRAM-exec architectural contract (HelloSdramExec)"
    [ testCase "HelloSdramExec — each iteration prints exactly 1 B and 1 S" case_oneSperBperIteration
    ]

-- * Test --------------------------------------------------------------

{- | Run the @HelloSdramExec@ firmware through 'socSimFullWith' with
@enableSdramFetch=True@. Slice the captured TX byte stream into
"iterations" (each starting at a 'B' byte = 0x42) and assert that
each iteration has exactly one 'S' byte (= 0x53) before the next
'B'.
-}
case_oneSperBperIteration :: Assertion
case_oneSperBperIteration = do
  let bytes :: [BitVector 8]
      bytes = runSoc helloSdramExecFirmwareWords 6000

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
  goPre [] = []
  goPre (b : rest)
    | b == 0x42 = goIter (1 :: Int) (0 :: Int) rest
    | otherwise = goPre rest

  goIter !nB !nS [] = [(nB, nS)]
  goIter !nB !nS (b : rest)
    | b == 0x42 = (nB, nS) : goIter 1 0 rest
    | b == 0x53 = goIter nB (nS + 1) rest
    | otherwise = goIter nB nS rest

-- * Harness ------------------------------------------------------------

runSoc :: [BitVector 32] -> Int -> [BitVector 8]
runSoc codeWords nCycles =
  let progVec :: Vec 4096 (BitVector 32)
      progVec = V.unsafeFromList (take 4096 (codeWords ++ P.repeat 0x0000_0013))

      dataVec :: Vec 1 (BitVector 32)
      dataVec = CP.repeat 0

      -- 256 K half-words = 512 KB. Unused by HelloSdramExec
      -- (firmware only touches BRAM + UART + SDRAM) but
      -- 'socSimFullWith' wires an SRAM model anyway.
      sramInit :: Vec 262144 (BitVector 16)
      sramInit = CP.repeat 0

      inputSig :: Signal System SocInFull
      inputSig =
        fromList (P.repeat SocInFull {sifSwitches = 0, sifKeys = 0xF})

      go :: (HiddenClockResetEnable System) => Signal System SocOutSim
      go = socSimFullWith False True progVec dataVec sramInit inputSig

      trace =
        sampleN @System nCycles $
          withClockResetEnable @System clockGen resetGen enableGen go
   in [b | SocOutSim {sosUartTx = Just b} <- trace]
