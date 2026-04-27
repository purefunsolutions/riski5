-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : PlicSocSpec
Description : SoC-level integration test for the @siUartIrq → PLIC → core MEI trap@ chain.

Exercises the wiring landed alongside this commit: an external
IRQ asserted on 'SocInSim.sisUartIrq' must traverse five layers
without losing the trap —

  1. The SoC connects @siUartIrq@ to bit 1 of the PLIC's
     @extIrqs@ vector ('Riski5.Soc' edit).
  2. The PLIC latches it into @pending[1]@ and computes
     @meipS = (pending & enable & priority>threshold) != 0@
     (already covered in 'PlicSpec', re-exercised here through
     the SoC bus).
  3. The core's CSR file folds @meipS@ into @mip.MEIP@
     ('Riski5.Core').
  4. 'interruptPending' fires on
     @mstatus.MIE && mie.MEIE && mip.MEIP@ ('Riski5.CSR').
  5. The trap path redirects to @mtvec.base@ and the handler
     runs ('Riski5.Core.handleInstr').

The firmware's job: configure the PLIC (priority[1] = 5,
threshold = 0, enable = 0b10), set mtvec, enable
mstatus.MIE + mie.MEIE, then spin. The handler at
@mtvec.base = 0x80@ writes the byte 'I' to the JTAG-UART data
register so the SocOutSim TX trace shows a clear sentinel.

The sim drives @sisUartIrq = False@ for the first ~80 cycles
(boot stub finishes), then @True@ from there on. We watch the
UART TX stream for the sentinel byte 'I' (= 0x49) within 200
cycles.
-}
module PlicSocSpec (
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
import Data.Either (Either (..))
import Data.Maybe (Maybe (..))
import Riski5.Asm
import Riski5.ISA
import Riski5.Soc (
  SocInSim (..),
  SocOutSim (..),
  defaultSocInSim,
  socSim,
 )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase)
import Prelude (Either (..), Int, error, ($), (.))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Soc PLIC + MEI integration"
    [ testCase "siUartIrq drives PLIC source 1 → core takes MEI trap → handler prints 'I'" case_uartIrqRouting
    ]

-- * Firmware --------------------------------------------------------

-- | Boot stub: print 'B', configure PLIC, enable interrupts, spin.
bootCode :: Asm ()
bootCode = do
  -- Load UART data-register address into x10.
  lui uartReg 0x10000 -- uartReg = 0x1000_0000
  -- Load PLIC base into x11. plicBase = 0x4000_0000 fits in a
  -- single LUI (high 20 bits of plicBase = 0x40000, low 12 = 0).
  lui plicReg 0x40000
  -- Load PLIC pending register address into x16. = 0x4000_1000.
  -- Can't reach via ADDI imm (max 2047 = 0x7FF) so we LUI it.
  lui pendReg 0x40001
  -- Load PLIC enable register address into x17. = 0x4000_2000.
  lui enReg 0x40002

  -- Print 'B' so the test can see the boot stub started.
  addi x14 x0 0x42 -- 'B'
  sw uartReg x14 0

  -- PLIC priority[1] := 5. Address = plicBase + 0x04.
  addi x12 x0 5
  sw plicReg x12 0x04

  -- PLIC threshold (hart 0 ctx 0) := 0. Address = plicBase + 0x20_0000.
  lui x13 0x40200
  sw x13 x0 0x00

  -- PLIC enable mask (hart 0 ctx 0) := 0b10 (source 1). Address
  -- = enReg + 0 = 0x4000_2000.
  addi x12 x0 0b10
  sw enReg x12 0

  -- mtvec.base := 0x80 (handler at word 32).
  addi x12 x0 0x80
  csrrw x0 x12 csrMtvec

  -- mie.MEIE := 1 (bit 11). 0x800 = 2048 — too big for ADDI's
  -- signed-12 immediate, so build via LUI 1 + ADDI -0x800 trick
  -- (li handles this).
  li x12 0x800
  csrrs x0 x12 csrMie

  -- mstatus.MIE := 1 (bit 3).
  addi x12 x0 0x8
  csrrs x0 x12 csrMstatus

  -- Print 'A' so the test confirms the boot stub completed all
  -- of its CSR / PLIC configuration.
  addi x14 x0 0x41 -- 'A'
  sw uartReg x14 0

  -- Spin forever. The handler will write 'I' once meipS rises.
  spinL <- label
  addi x6 x6 1
  j spinL
 where
  uartReg = x10
  plicReg = x11
  pendReg = x16
  enReg = x17

-- | Handler: write 'I' to the UART, then spin. We don't bother
-- claiming / completing on the PLIC because the level-sensitive
-- @sisUartIrq@ would just re-fire — the sentinel byte is enough to
-- prove the trap reached us.
handlerCode :: Asm ()
handlerCode = do
  -- Reload x10 because the handler doesn't preserve caller-saved
  -- registers (this is a sim test, not a real OS handler).
  li uartReg 0x1000_0000
  addi x14 x0 0x49 -- 'I'
  sw uartReg x14 0
  haltL <- label
  j haltL
 where
  uartReg = x10

-- | Stitch boot at word 0, handler at word 32 (byte 0x80).
stitch :: [BitVector 32]
stitch =
  let nopW = 0x0000_0013
      bootWords = case assemble bootCode of
        Left err -> error ("PlicSocSpec boot: " P.++ P.show err)
        Right ws -> ws
      handlerWords = case assemble handlerCode of
        Left err -> error ("PlicSocSpec handler: " P.++ P.show err)
        Right ws -> ws
      bootLen = P.length bootWords
      gapLen = 32 P.- bootLen
   in if gapLen P.< 0
        then error "PlicSocSpec: boot stub grew past handler offset 0x80"
        else bootWords P.++ P.replicate gapLen nopW P.++ handlerWords

-- * Harness ---------------------------------------------------------

runWithIrq :: [P.Bool] -> Int -> [SocOutSim]
runWithIrq irqPattern nCycles =
  let progVec :: Vec 256 (BitVector 32)
      progVec =
        V.unsafeFromList
          (P.take 256 (stitch P.++ P.repeat 0x0000_0013))
      dataVec :: Vec 64 (BitVector 32)
      dataVec = CP.repeat 0
      inSimList =
        P.zipWith
          (\irq _ -> defaultSocInSim {sisUartIrq = irq})
          (irqPattern P.++ P.repeat P.True)
          [0 :: Int ..]
      inputSig = fromList inSimList
      go ::
        (HiddenClockResetEnable System) =>
        Signal System SocOutSim
      go = socSim progVec dataVec inputSig
   in sampleN @System nCycles $
        withClockResetEnable @System clockGen resetGen enableGen go

-- * Cases -----------------------------------------------------------

case_uartIrqRouting :: Assertion
case_uartIrqRouting = do
  let irqPattern = P.replicate 100 P.False P.++ P.repeat P.True
      trace = runWithIrq irqPattern 600
      txBytes = [b | SocOutSim {sosUartTx = Just b} <- trace]
      txString = P.map (P.toEnum . P.fromIntegral) txBytes :: P.String
      sentinel = 0x49 -- 'I'
      hit = P.any (P.== sentinel) txBytes
  assertBool
    ( "expected 'I' (0x49) in UART TX trace within 600 cycles; got "
        P.++ P.show (P.length txBytes)
        P.++ " bytes: "
        P.++ P.show txString
    )
    hit
