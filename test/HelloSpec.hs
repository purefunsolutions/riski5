-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : HelloSpec
Description : End-to-end SoC simulation of the Hello firmware.

Drives the full SoC with the @Hello@ firmware, sampling enough
cycles for every LCD write to complete (each LCD character spends
~2 000 cycles in the busy-wait window), and asserts the observed
JTAG UART TX stream spells @hello, world\n@. Catches any
divergence between the firmware's MMIO addresses and the SoC's
bus decoder, plus timing regressions in the LCD / UART
peripherals.
-}
module HelloSpec (
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
import Data.Foldable (toList)
import Hello qualified
import Riski5.Soc (SocIn (..), SocOut (..), soc)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, testCase)
import Prelude (Int, Maybe (..), String, ($), (.))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Hello firmware"
    [ testCase "UART TX stream spells 'hello, world\\n'" case_uart
    ]

{- | Simulate the SoC running the Hello firmware for @n@ cycles and
return the observed output trace.
-}
runHelloSoc :: Int -> [SocOut]
runHelloSoc nCycles =
  let progVec :: Vec 256 (BitVector 32)
      progVec =
        V.unsafeFromList
          (P.take 256 (Hello.helloFirmwareWords P.++ P.repeat 0x0000_0013))
      dataVec :: Vec 64 (BitVector 32)
      dataVec = CP.repeat 0
      inputSig =
        fromList (P.repeat SocIn {siSwitches = 0, siKeys = 0xF, siSramDqIn = 0})
      go ::
        (HiddenClockResetEnable System) =>
        Signal System SocOut
      go = soc progVec dataVec inputSig
   in sampleN @System nCycles $
        withClockResetEnable @System clockGen resetGen enableGen go

-- * Cases ----------------------------------------------------------

case_uart :: Assertion
case_uart = do
  -- After the hardware-required HD44780 wake sequence + post-Clear
  -- pause, the firmware spends ~1.35 M cycles in software delay
  -- loops before any UART writes happen. We sample 2 M cycles to
  -- give the LCD-string + UART-string phases plenty of headroom.
  let trace = runHelloSoc 2_000_000
      txBytes = [b | SocOut {soUartTx = Just b} <- trace]
      txString :: String
      txString = P.map (P.toEnum . P.fromIntegral) txBytes
  assertEqual "UART TX bytes as string" "hello, world\n" txString
