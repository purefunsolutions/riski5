-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : SocSpec
Description : End-to-end SoC integration test.

Loads a small program into the SoC's BRAM via the parameterised
initial-contents vector, runs it through Clash's pure simulator,
and observes the JTAG UART TX byte stream + the LEDR output to
verify that the core, bus, BRAM, JTAG UART, LCD, and GPIO modules
all play together.

This is the highest-level Clash-side test before real hardware
bring-up. The firmware programs it runs are stepping stones
toward the 'Hello from Riski5' firmware proper ('firmware/phase1/'
once T18 lands).
-}
module SocSpec (
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
  repeat,
  resetGen,
  sampleN,
  withClockResetEnable,
 )
import Clash.Prelude qualified as CP
import Clash.Sized.Vector qualified as V
import Data.Foldable (toList)
import Riski5.Asm (Asm, assemble)
import Riski5.Asm qualified as Asm
import Riski5.ISA
import Riski5.MemMap (jtagUartBase)
import Riski5.Soc (SocInSim (..), SocOut (..), SocOutSim (..), socSim)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, assertFailure, testCase)
import Prelude (Either (..), IO, Int, Maybe (..), error, ($), (.))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Soc"
    [ testCase "firmware writes 'Hi' to the JTAG UART" case_hi
    , testCase "LEDR driven by a GPIO write becomes observable" case_ledr
    , testCase "SDRAM round-trip surfaces on the JTAG UART" case_sdramRoundTrip
    ]

-- * Catalog --------------------------------------------------------

{- |
Program: push 'H' then 'i' through the JTAG UART DATA register,
then spin. After simulation we collect all observed TX bytes and
verify the sequence is @\"Hi\"@.
-}
progHi :: Asm ()
progHi = do
  -- Base = 0x1000_0000 — needs LUI to construct (fits upper 20 bits
  -- exactly).
  Asm.lui x11 0x10000 -- x11 = 0x1000_0000
  Asm.addi x10 x0 0x48 -- x10 = 'H'
  Asm.emit (Sw x11 x10 0)
  -- \*UART = 'H'
  Asm.addi x10 x0 0x69 -- x10 = 'i'
  Asm.emit (Sw x11 x10 0)
  -- \*UART = 'i'
  spin <- Asm.label
  Asm.j spin

{- |
Program: drop a value into x2 and store it to the LEDR register
(GPIO base + 0 = 0x1000_0020). Assert the SoC's LEDR output
reflects that bit pattern after enough cycles.
-}
progLedr :: Asm ()
progLedr = do
  Asm.lui x11 0x10000 -- x11 = 0x1000_0000
  Asm.addi x11 x11 0x20 -- x11 = 0x1000_0020 (LEDR register)
  Asm.addi x10 x0 0x15 -- x10 = 0x15 (= 0b010101, visible on low LEDRs)
  Asm.emit (Sw x11 x10 0)
  -- \*LEDR = 0x15
  spin <- Asm.label
  Asm.j spin

{- |
SDRAM end-to-end round-trip. Writes a byte to SDRAM, reads it
back, then echoes it on the JTAG UART so the test can observe
the value. If the whole chain — core stall, SDRAM adapter FSM,
SDRAM IP sim model, bus read-mux — works, the UART TX stream
contains the byte we wrote.
-}
progSdramRoundTrip :: Asm ()
progSdramRoundTrip = do
  -- x11 = SDRAM base = 0x8000_0000
  Asm.lui x11 0x80000
  -- x13 = UART base = 0x1000_0000
  Asm.lui x13 0x10000
  -- Store a recognizable value to SDRAM[0..3].
  Asm.addi x10 x0 0x5A
  Asm.emit (Sw x11 x10 0)
  -- Load it back.
  Asm.emit (Lw x12 x11 0)
  -- Echo the low byte on the UART.
  Asm.emit (Sw x13 x12 0)
  spin <- Asm.label
  Asm.j spin

-- * Harness --------------------------------------------------------

{- | Simulate the SoC with the given program for @n@ cycles, returning
the observed output trace.
-}
runSoc :: Asm () -> Int -> [SocOutSim]
runSoc prog nCycles =
  case assemble prog of
    Left err -> error ("assemble failed: " P.++ P.show err)
    Right ws ->
      let progVec :: Vec 128 (BitVector 32)
          progVec =
            V.unsafeFromList (P.take 128 (ws P.++ P.repeat 0x0000_0013))
          dataVec :: Vec 128 (BitVector 32)
          dataVec = CP.repeat 0
          inputSig =
            fromList (P.repeat (SocInSim {sisSwitches = 0, sisKeys = 0xF, sisSramDqIn = 0}))
          go ::
            (HiddenClockResetEnable System) =>
            Signal System SocOutSim
          go = socSim progVec dataVec inputSig
       in sampleN @System nCycles $
            withClockResetEnable @System clockGen resetGen enableGen go

-- * Cases ----------------------------------------------------------

case_hi :: Assertion
case_hi = do
  let trace = runSoc progHi 30
      txBytes = [b | SocOutSim {sosUartTx = Just b} <- trace]
  case txBytes of
    [h, i_] -> do
      assertEqual "first byte = 'H'" 0x48 h
      assertEqual "second byte = 'i'" 0x69 i_
    other ->
      assertFailure ("expected 2 TX bytes, got " P.++ P.show other)

case_ledr :: Assertion
case_ledr = do
  let trace = runSoc progLedr 20
      ledrs = P.map (soLedR . sosOut) trace
  -- Somewhere in the first 20 cycles, LEDR should carry 0x15.
  assertEqual
    "LEDR contains 0x15"
    P.True
    (P.any (P.== 0x15) ledrs)

{- | Verify SDRAM access goes through the bus decoder, the 32 ↔ 16
width adapter, the SDRAM IP sim model, and comes back as an
observable UART byte. Acts as a mini end-to-end smoke test before
the hardware bring-up.
-}
case_sdramRoundTrip :: Assertion
case_sdramRoundTrip = do
  -- 50 cycles easily covers: 5 fetches + 1 SW (3) + 1 LW (5) +
  -- 1 SW (UART, 1 cycle) plus pipeline fills. Any trailing j-spin
  -- is harmless.
  let trace = runSoc progSdramRoundTrip 80
      txBytes = [b | SocOutSim {sosUartTx = Just b} <- trace]
  case txBytes of
    [b] -> assertEqual "UART TX reflects SDRAM round-trip byte" 0x5A b
    other ->
      assertFailure
        ( "expected exactly 1 TX byte (0x5A), got "
            P.++ P.show other
        )
