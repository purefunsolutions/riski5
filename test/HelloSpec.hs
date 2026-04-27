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
Description : Whole-SoC UART print sim — minimal inline firmware.

Runs a tiny inline @Asm@ program through the full SoC (core + bus
+ BRAM + JTAG UART) and asserts the JTAG UART TX stream spells
@hello, world\\n@. The firmware is generated per-test, same pattern
as every other test in this suite: no LCD wake-up, no SRAM access,
no 1.5 M cycles of HD44780-spec delays.

The hardware-side @Hello@ firmware (which does initialise the LCD
and runs the SRAM self-test) lives at @firmware/phase1/Hello.hs@
and is consumed only by @app/Top.hs@ at synthesis time — never at
test time.
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
import Riski5.Asm
import Riski5.ISA
import Riski5.Soc (SocInSim (..), SocOutSim (..), socSim)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, testCase)
import Prelude (Either (..), Int, Maybe (..), String, error, ($), (.))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Hello firmware"
    [ testCase "UART TX stream spells 'hello, world\\n'" case_uart
    ]

-- * Inline firmware ------------------------------------------------

{- |
Minimal UART-only firmware: load the JTAG UART base address,
stream the @hello, world\\n@ bytes through the data register,
spin forever. No LCD / SRAM / delays — just the core + bus +
UART path exercised end-to-end.
-}
helloProg :: Asm ()
helloProg = do
  -- UART DATA register base = 0x1000_0000. The upper 20 bits fit
  -- exactly in LUI's immediate, so we can load via a single LUI.
  lui uartReg 0x10000 -- uartReg = 0x1000_0000
  P.mapM_ writeChar "hello, world\n"
  spin <- label
  j spin
 where
  uartReg :: Reg
  uartReg = x11
  tmpReg :: Reg
  tmpReg = x10
  writeChar :: P.Char -> Asm ()
  writeChar c = do
    addi tmpReg x0 (P.fromIntegral (P.fromEnum c))
    emit (Sw uartReg tmpReg 0)

helloProgWords :: [BitVector 32]
helloProgWords = case assemble helloProg of
  Left err -> error ("helloProg failed to assemble: " P.++ P.show err)
  Right ws -> ws

-- * Harness --------------------------------------------------------

runHelloSoc :: Int -> [SocOutSim]
runHelloSoc nCycles =
  let progVec :: Vec 128 (BitVector 32)
      progVec =
        V.unsafeFromList
          (P.take 128 (helloProgWords P.++ P.repeat 0x0000_0013))
      dataVec :: Vec 64 (BitVector 32)
      dataVec = CP.repeat 0
      inputSig =
        fromList (P.repeat SocInSim {sisSwitches = 0, sisKeys = 0xF, sisSramDqIn = 0, sisUartIrq = P.False})
      go ::
        (HiddenClockResetEnable System) =>
        Signal System SocOutSim
      go = socSim progVec dataVec inputSig
   in sampleN @System nCycles $
        withClockResetEnable @System clockGen resetGen enableGen go

-- * Cases ----------------------------------------------------------

case_uart :: Assertion
case_uart = do
  -- Program is ~16 instructions (1 LUI + 13 addi/sw pairs + 1 jump).
  -- The pipelined core retires roughly one per cycle, so 200 cycles
  -- is plenty.
  let trace = runHelloSoc 200
      txBytes = [b | SocOutSim {sosUartTx = Just b} <- trace]
      txString :: String
      txString = P.map (P.toEnum . P.fromIntegral) txBytes
  assertEqual ("UART TX bytes (got " P.++ P.show (P.length txBytes) P.++ ")") "hello, world\n" txString
