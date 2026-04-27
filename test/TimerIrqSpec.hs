-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : TimerIrqSpec
Description : End-to-end machine-timer-interrupt firing test.

The CLINT block ('Riski5.Clint') and the core's CSR + trap path
together implement the RISC-V machine-timer interrupt. This spec
puts them in front of a hand-rolled boot stub that:

  1. Sets @mtvec.base@ to a known handler PC.
  2. Writes @mtimecmp@ to a small value so it fires within a few
     dozen cycles.
  3. Sets @mie.MTIE@ and @mstatus.MIE@ to enable timer interrupts.
  4. Spins in a loop incrementing a counter.

The handler at @mtvec.base@:

  1. Writes a sentinel value (@0xCAFE_BABE@) to a known register
     (x10) so the test can verify it ran.
  2. Spins forever (we don't bother with @mret@ here — the test
     just observes the writeback once and stops).

Driving @mtipS@ externally with a manually-set sequence is simpler
than wiring the actual 'Riski5.Clint' here; we pulse @mtipS=True@
on a chosen cycle and check the core takes the trap.
-}
module TimerIrqSpec (
  tests,
) where

import Clash.Prelude (
  BitVector,
  HiddenClockResetEnable,
  Index,
  Signal,
  System,
  Vec,
  bundle,
  clockGen,
  enableGen,
  fromList,
  resetGen,
  sampleN,
  unpack,
  withClockResetEnable,
  (!!),
 )
import Data.Either (Either (..))
import Data.Maybe (Maybe (..))
import Clash.Prelude qualified as CP
import Clash.Sized.Vector qualified as V
import Data.Bits (shiftR)
import Riski5.Asm (
  Asm,
  addi,
  assemble,
  csrrs,
  csrrw,
  j,
  label,
  li,
 )
import Riski5.Core (core)
import Riski5.ISA
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase)
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Core machine-timer interrupt"
    [ testCase "handler runs once mtipS is asserted with mie / mstatus enabled" case_timerIrqHandler
    ]

-- * Test --------------------------------------------------------

{- |
Boot stub + spinning main + timer-interrupt handler. The handler
plants @0xCAFE_BABE@ into x10 — once we observe that retirement, we
know the trap fired and the handler ran.

Layout:

  word 0–N  : boot stub + spinning main loop (PC starts at 0)
  word M    : @mtvec.base = 0x80@ marker — the handler lives at
              byte address 0x80 in the program vector (word index 32).

We assemble two pieces and stitch them at fixed offsets so the
@mtvec@ math is exact.
-}
case_timerIrqHandler :: Assertion
case_timerIrqHandler = do
  let bootProg = bootCode
      handlerProg = handlerCode
      ws = stitch bootProg handlerProg
      -- Drive mtipS=False initially, then pulse True from cycle 60
      -- onwards — well past pipeline fill so the boot stub has
      -- finished setting mtvec / mie / mstatus.
      mtipPattern =
        P.replicate 60 P.False
          P.++ P.repeat P.True
      trace = runCoreWithMtip ws mtipPattern 200
      writebacks = [(rd, val) | (Just (rd, val)) <- P.map P.snd trace]
      sentinel = 0xCAFE_BABE :: BitVector 32
      hit = P.any (\(_, v) -> v P.== sentinel) writebacks
  assertBool
    ("expected handler to set rd to 0xCAFEBABE; writebacks: " P.++ P.show writebacks)
    hit

-- Boot code: write mtvec, mtimecmp, mie, mstatus; then spin.
bootCode :: Asm ()
bootCode = do
  -- mtvec.base := 0x80 (handler at word offset 32). MODE = 0 (direct).
  addi x5 x0 0x80
  csrrw x0 x5 csrMtvec
  -- mie.MTIE := 1 (bit 7).
  addi x5 x0 0x80
  csrrs x0 x5 csrMie
  -- mstatus.MIE := 1 (bit 3).
  addi x5 x0 0x8
  csrrs x0 x5 csrMstatus
  -- Spin counter loop. Drive a known register to a non-handler
  -- value so we can distinguish the boot path from the handler.
  addi x10 x0 1 -- x10 := 1 in the boot path (handler will overwrite to 0xCAFEBABE)
  spinL <- label
  addi x6 x6 1
  j spinL

-- Handler code: writes 0xCAFE_BABE into x10 to signal "I ran", then
-- spins. No mret — the test stops the moment it sees the sentinel.
handlerCode :: Asm ()
handlerCode = do
  li x10 0xCAFE_BABE
  haltL <- label
  j haltL

{- | Stitch boot and handler at fixed offsets: boot at word 0,
handler at word 32 (byte offset 0x80). NOPs fill any gap between
the end of boot and word 32.
-}
stitch :: Asm () -> Asm () -> [BitVector 32]
stitch bootP handlerP =
  let nop_ = 0x0000_0013
      bootWords = case assemble bootP of
        Left err -> P.error ("stitch boot: " P.++ P.show err)
        Right ws -> ws
      handlerWords = case assemble handlerP of
        Left err -> P.error ("stitch handler: " P.++ P.show err)
        Right ws -> ws
      bootLen = P.length bootWords
      gapLen = 32 P.- bootLen
   in if gapLen P.< 0
        then P.error "boot code grew past handler offset 0x80"
        else
          bootWords
            P.++ P.replicate gapLen nop_
            P.++ handlerWords

-- * Sim harness -------------------------------------------------

type ProgSize = 64

runCoreWithMtip ::
  [BitVector 32] ->
  [P.Bool] ->
  P.Int ->
  [(BitVector 32, Maybe (BitVector 5, BitVector 32))]
runCoreWithMtip program mtips n =
  sampleN @System n P.$
    withClockResetEnable @System clockGen resetGen enableGen P.$
      runHarness program mtips

runHarness ::
  (HiddenClockResetEnable System) =>
  [BitVector 32] ->
  [P.Bool] ->
  Signal System (BitVector 32, Maybe (BitVector 5, BitVector 32))
runHarness program mtips =
  let progVec :: Vec ProgSize (BitVector 32)
      progVec = V.unsafeFromList (P.take 64 padded)
      padded = program P.++ P.repeat 0x0000_0013
      pcToIdx :: BitVector 32 -> Index ProgSize
      pcToIdx pc =
        let w :: CP.Unsigned 32
            w = unpack (pc `shiftR` 2)
         in P.fromIntegral (w `P.mod` 64)
      imem = CP.register 0x0000_0013 (P.fmap (\pc -> progVec !! pcToIdx pc) pcFetchS)
      dmem = CP.pure 0
      mtipS = fromList (mtips P.++ P.repeat P.False)
      (pcFetchS, pcExecS, _dAddrS, _dWdataS, _dBeS, _dRenS, wbS, _rvfiS) =
        core imem (CP.pure P.True) dmem (CP.pure P.False) mtipS (CP.pure P.False)
   in bundle (pcExecS, wbS)
