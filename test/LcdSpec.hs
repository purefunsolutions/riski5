-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : LcdSpec
Description : Timing + handshake tests for the self-timed HD44780
              controller.

The controller owns HD44780 timing — at reset it runs a Vcc-settle
window, then the wake / init sequence, and only then accepts user
writes. So every test here uses 'Riski5.Lcd.lcdWith' with a tiny
@LcdParams@ (all cycle counts scaled down) so the boot sequence
completes in a few hundred simulation cycles instead of the
1.5-million-cycle 30 ms needed on real hardware.

The invariants we verify:

  * After the short configured boot sequence, @busy@ drops and
    @E@ has pulsed once per BootStep (7 pulses total:
    3 × 0x30 wake + 0x38 + 0x0C + 0x06 + 0x01).
  * Once in @Ready@, a user DATA write holds @E@ high for
    @paramPulseCycles@ after @paramSetupCycles@ of data setup.
  * STATUS bit 1 (irq_pending) latches on the busy-falling edge
    and clears on a W1C write.
  * CTRL bit 0 enables the IRQ output.
-}
module LcdSpec (
  tests,
) where

import Clash.Prelude (
  BitVector,
  HiddenClockResetEnable,
  Signal,
  System,
  clockGen,
  enableGen,
  fromList,
  high,
  low,
  resetGen,
  sampleN,
  withClockResetEnable,
 )
import Clash.Prelude qualified as CP
import Riski5.Lcd (
  LcdParams (..),
  LcdPins (..),
  defaultParams,
  lcdWith,
 )
import Riski5.MemMap (lcdBase)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, testCase)
import Prelude (Bool (..), Int, Maybe (..), fst, snd, zip3, ($), (+), (-), (<$>), (<*>), (<=), (==), (>))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Lcd"
    [ testCase "boot sequence pulses E exactly 7 times, then drops busy" case_bootSequence
    , testCase "user DATA write respects setup+pulse timing" case_userPulseWidth
    , testCase "IRQ pending latches on busy-falling, clears on W1C" case_irqLatching
    , testCase "CTRL[0] gates the IRQ output" case_irqEnable
    ]

-- | Tiny timing parameters so the boot sequence finishes fast in sim.
smallParams :: LcdParams
smallParams =
  LcdParams
    { paramStartupCycles = 4
    , paramSetupCycles = 2
    , paramPulseCycles = 3
    , paramWake1Wait = 4
    , paramWake23Wait = 3
    , paramShortWait = 3
    , paramLongWait = 5
    }

-- | One simulated cycle of inputs (per-field lists avoid the need for
-- an NFDataX instance over a bundle type).
type Drive = (Bool, BitVector 32, BitVector 32, BitVector 4, Bool)

-- | Idle drive reads STATUS every cycle: 'dSel=True', @addr=STATUS@,
-- @be=0@, @read=True@. Good for observing busy + irq_pending
-- continuously without injecting spurious writes.
idle :: Drive
idle = (True, lcdBase + 8, 0, 0, True)

writeAt :: BitVector 32 -> BitVector 32 -> Drive
writeAt a w = (True, a, w, 0b0001, False)

simLcd ::
  LcdParams ->
  Int ->
  [Drive] ->
  [(LcdPins, BitVector 32, Bool)]
simLcd params n drives =
  let pad xs = xs P.++ P.repeat idle
      padded = pad drives
      selS = fromList [a | (a, _, _, _, _) <- padded]
      addrS = fromList [b | (_, b, _, _, _) <- padded]
      wdataS = fromList [c | (_, _, c, _, _) <- padded]
      beS = fromList [d | (_, _, _, d, _) <- padded]
      readS = fromList [e | (_, _, _, _, e) <- padded]
      go ::
        (HiddenClockResetEnable System) =>
        Signal System (LcdPins, BitVector 32, Bool)
      go =
        let (rdata, pins, irq) = lcdWith params selS addrS wdataS beS readS
         in (,,) <$> pins <*> rdata <*> irq
   in sampleN @System n $
        withClockResetEnable @System clockGen resetGen enableGen go

pulseEdges :: [LcdPins] -> [Int]
pulseEdges pinsList =
  let es = P.zipWith (\a b -> (lcdE a, lcdE b)) pinsList (P.tail pinsList)
      indexed = P.zip [0 :: Int ..] es
   in [i + 1 | (i, (prev, cur)) <- indexed, prev == low, cur == high]

-- * Cases ----------------------------------------------------------

case_bootSequence :: Assertion
case_bootSequence = do
  -- Run long enough for: startup(4) + 7 × (setup(2)+pulse(3)+wait(≤5)) + margin.
  -- Worst-case per step is 2+3+5 = 10 cycles; 7 × 10 = 70; plus startup 4 + reset = 75.
  -- Run 120 cycles to be safe.
  let trace = simLcd smallParams 120 []
      pins = [p | (p, _, _) <- trace]
      status = [s | (_, s, _) <- trace]
      busyAt c = status P.!! c CP..&. 0x1
      edges = pulseEdges pins
  assertEqual "7 E rising edges in the boot sequence" 7 (P.length edges)
  -- busy=1 throughout the boot, drops after the last Clear's Wait.
  assertEqual "cycle 0: busy=1 (still in StartupSettle)" 1 (busyAt 0)
  assertEqual "cycle 3: busy=1 (last StartupSettle cycle)" 1 (busyAt 3)
  -- After 120 cycles we should be well past the sequence.
  assertEqual "cycle 119: busy=0 (boot finished)" 0 (busyAt 119)
  -- And the seven emitted bytes, in order: 0x30, 0x30, 0x30, 0x38, 0x0C, 0x06, 0x01.
  let bytesAt edge = lcdData (pins P.!! edge)
      expected = [0x30, 0x30, 0x30, 0x38, 0x0C, 0x06, 0x01 :: BitVector 8]
      actual = P.map bytesAt edges
  assertEqual "boot-sequence byte order" expected actual

case_userPulseWidth :: Assertion
case_userPulseWidth = do
  -- Same short startup; we issue a DATA write at cycle 200 (safely after boot).
  let writeCycle = 200 :: Int
      n = writeCycle + 1 + P.fromIntegral (paramSetupCycles smallParams)
            + P.fromIntegral (paramPulseCycles smallParams)
            + P.fromIntegral (paramShortWait smallParams) + 5
      dataAddr = lcdBase + 0
      drives = P.replicate writeCycle idle P.++ [writeAt dataAddr 0xAB]
      trace = simLcd smallParams n drives
      pins = [p | (p, _, _) <- trace]
      esAt c = lcdE (pins P.!! c)
      dataAt c = lcdData (pins P.!! c)
      rsAt c = lcdRs (pins P.!! c)
      statusAt c = snd3 (trace P.!! c)
  -- Cycle writeCycle: write latched. State enters Emit/Setup next edge.
  -- Cycle writeCycle+1 .. writeCycle+setupCycles: Setup phase, E low, data stable.
  assertEqual "E still low during Setup" low (esAt (writeCycle + 1))
  assertEqual "E still low at end of Setup" low (esAt (writeCycle + 2))
  assertEqual "data latched at Setup entry" 0xAB (dataAt (writeCycle + 1))
  assertEqual "RS=high (DATA write)" high (rsAt (writeCycle + 1))
  -- Cycle writeCycle+setupCycles+1 .. writeCycle+setupCycles+pulseCycles: Pulse.
  let pulseStart = writeCycle + 1 + P.fromIntegral (paramSetupCycles smallParams)
      pulseEnd = pulseStart + P.fromIntegral (paramPulseCycles smallParams) - 1
  assertEqual "E high at pulse start" high (esAt pulseStart)
  assertEqual "E high at pulse end" high (esAt pulseEnd)
  assertEqual "E drops the cycle after pulse" low (esAt (pulseEnd + 1))
  -- STATUS busy should be 1 through pulse, 0 again at end of run.
  let busyBit s = s CP..&. 0x1
  assertEqual "busy=1 during pulse" 1 (busyBit (statusAt pulseStart))
  assertEqual "busy=0 at end of run (post-wait elapsed)" 0 (busyBit (statusAt (n - 1)))
 where
  snd3 (_, b, _) = b

case_irqLatching :: Assertion
case_irqLatching = do
  -- Boot takes <120 cycles. During boot, busy falls 7 times (between
  -- BootStep N's Wait and BootStep (N+1)'s Setup on each boundary)
  -- — but actually we engineered the FSM to go directly from Wait→
  -- Setup of the next boot step, so busy stays 1 throughout. The
  -- only busy-falling edge in the boot is the final Clear's Wait→
  -- Ready transition. Let's verify that + one user transaction.
  let statusAddr = lcdBase + 8
      trace1 = simLcd smallParams 200 []
      statusReads = [(i, s) | (i, (_, s, _)) <- P.zip [0 :: Int ..] trace1]
      -- irq_pending is STATUS bit 1.
      pendingAt i = (P.snd (statusReads P.!! i) CP..&. 0x2) == 2
  assertBool "STATUS[1]=0 immediately after reset" (P.not (pendingAt 0))
  assertBool "STATUS[1]=1 after boot completes" (pendingAt 199)
  -- Now: do a W1C of STATUS[1] and verify it clears.
  let clearCycle = 199 :: Int
      drives = P.replicate clearCycle idle P.++ [writeAt statusAddr 0x2]
      trace2 = simLcd smallParams (clearCycle + 5) drives
      statusAfter i = snd3 (trace2 P.!! i)
      pend i = (statusAfter i CP..&. 0x2) == 2
  assertBool "STATUS[1]=1 the cycle of the W1C write" (pend clearCycle)
  assertBool "STATUS[1]=0 one cycle after the W1C" (P.not (pend (clearCycle + 1)))
 where
  snd3 (_, b, _) = b

case_irqEnable :: Assertion
case_irqEnable = do
  -- With CTRL[0]=0 (reset default), IRQ output never asserts.
  let trace1 = simLcd smallParams 200 []
      irqs1 = [irq | (_, _, irq) <- trace1]
  assertBool "IRQ stays low when CTRL[0]=0" (P.all P.not irqs1)
  -- Write CTRL[0]=1 on cycle 5 (well after the 1-cycle reset pulse
  -- so the register actually latches), then read CTRL back on
  -- cycle 7 to confirm. Then let boot finish and verify IRQ asserts.
  let ctrlAddr = lcdBase + 12
      ctrlRead = (True, ctrlAddr, 0, 0, True)
      drives =
        P.replicate 5 idle
          P.++ [writeAt ctrlAddr 0x1]
          P.++ P.replicate 3 ctrlRead
          P.++ P.repeat idle
      trace2 = simLcd smallParams 200 drives
      rdataAt c = let (_, r, _) = trace2 P.!! c in r
      irqAt c = let (_, _, i) = trace2 P.!! c in i
  assertEqual "CTRL reads back 1 two cycles after the CTRL[0]:=1 write" 1 (rdataAt 7)
  -- Boot finishes around cycle 63; IRQ should be asserted at some
  -- cycle ≥ 64 and stay on until W1C.
  let irqs2 = P.map irqAt [0 .. 199]
  assertBool "IRQ asserts once boot completes with CTRL[0]=1" (P.or irqs2)
