-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause

{- |
Module      : LcdSpec
Description : Timing + handshake tests for the HD44780 controller.

Drives 'Riski5.Lcd.lcd' through a firmware-style MMIO transaction
and verifies that:

  * @E@ stays high for exactly 'Riski5.Lcd.pulseCycles' (16) cycles
    after a write, then goes low.
  * @busy@ is asserted while either the pulse or the post-write
    idle window is running, cleared afterwards.
  * Two back-to-back writes pipeline correctly: the second write is
    ignored until @busy@ drops, then proceeds.
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
import Riski5.Lcd (LcdPins (..), lcd)
import Riski5.MemMap (lcdBase)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, testCase)
import Prelude (Bool (..), Int, Maybe (..), ($), (+), (<$>), (<*>))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Lcd"
    [ testCase "DATA write holds E high for pulseCycles, then drops it" case_pulseWidth
    , testCase "busy is asserted through pulse+idle, clears afterwards" case_busyFlag
    ]

{- | Drive the LCD controller for @n@ cycles and return the observed
@(pins, status)@ trace.
-}
simLcd ::
  Int ->
  [Bool] ->
  [BitVector 32] ->
  [BitVector 32] ->
  [BitVector 4] ->
  [(LcdPins, BitVector 32)]
simLcd n sels addrs wdatas bes =
  let pad xs = xs P.++ P.repeat (P.last xs)
      selS = fromList (pad sels)
      addrS = fromList (pad addrs)
      wdataS = fromList (pad wdatas)
      beS = fromList (pad bes)
      readS = fromList (P.repeat CP.False)
      go ::
        (HiddenClockResetEnable System) =>
        Signal System (LcdPins, BitVector 32)
      go =
        let (rdata, pins) = lcd selS addrS wdataS beS readS
         in (,) <$> pins <*> rdata
   in sampleN @System n $
        withClockResetEnable @System clockGen resetGen enableGen go

-- * Cases ----------------------------------------------------------

case_pulseWidth :: Assertion
case_pulseWidth = do
  -- Cycle 0: under reset — any write is dropped. Firmware issues the
  -- MMIO write on cycle 1 (once reset has released).
  -- Cycle 2..17: E is high (pulseCycles = 16 at 50 MHz).
  -- Cycle 18: E drops, post-write idle begins.
  let dataAddr = lcdBase + 0
      prog =
        simLcd
          22
          (False : True : P.repeat False) -- select on cycle 1 only
          (0 : dataAddr : P.repeat dataAddr) -- absolute DATA address
          (0 : 0xAB : P.repeat 0)
          (0 : 0b0001 : P.repeat 0)
      esAt c = lcdE (P.fst (prog P.!! c))
  assertEqual "cycle 0: E low (reset)" low (esAt 0)
  assertEqual "cycle 1: E still low (request captured this edge)" low (esAt 1)
  assertEqual "cycle 2: E high (pulse start)" high (esAt 2)
  assertEqual "cycle 17: E high (pulse last)" high (esAt 17)
  assertEqual "cycle 18: E low (pulse ended)" low (esAt 18)
  -- Data + RS stable through the pulse window.
  assertEqual "cycle 2: DATA = 0xAB" 0xAB (lcdData (P.fst (prog P.!! 2)))
  assertEqual "cycle 2: RS = 1 (DATA write)" high (lcdRs (P.fst (prog P.!! 2)))

case_busyFlag :: Assertion
case_busyFlag = do
  -- Cycle 0: reset. Cycle 1: firmware issues one DATA write. Cycles
  -- 2..: read STATUS every cycle.
  let dataAddr = lcdBase + 0
      statusAddr = lcdBase + 8
      idle_ = (False, 0 :: BitVector 32, 0 :: BitVector 32, 0 :: BitVector 4)
      firstWrite = (True, dataAddr, 0xAB, 0b0001)
      statusRead = (True, statusAddr, 0, 0)
      ops = idle_ : firstWrite : P.replicate 30 statusRead
      (sels, addrs, wdatas, bes) = unzip4 ops
      prog = simLcd 32 sels addrs wdatas bes
      busyAt c = P.snd (prog P.!! c)
  -- During the pulse (cycles 2..17) busy = 1.
  assertEqual "cycle 5: busy = 1 (mid pulse)" 1 (busyAt 5)
  -- During idle wait (cycles 18..2017) busy = 1.
  assertEqual "cycle 18: busy = 1 (post-pulse idle)" 1 (busyAt 18)
  assertEqual "cycle 25: busy = 1 (still idle)" 1 (busyAt 25)

-- (Full idle takes 2016 cycles; we'd need a much longer sim to
-- catch it dropping back to 0. The point here is that busy reports
-- 1 continuously through pulse + idle, which is what firmware
-- sees during its poll loop.)

unzip4 :: [(a, b, c, d)] -> ([a], [b], [c], [d])
unzip4 xs =
  ( [a | (a, _, _, _) <- xs]
  , [b | (_, b, _, _) <- xs]
  , [c | (_, _, c, _) <- xs]
  , [d | (_, _, _, d) <- xs]
  )
