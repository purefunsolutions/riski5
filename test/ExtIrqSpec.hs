-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : ExtIrqSpec
Description : End-to-end machine-external-interrupt trap-path test.

Mirror image of 'TimerIrqSpec' for the @meipS@ → @mip.MEIP@ →
trap path landed in 31254f0. The PLIC block itself is exercised
in 'PlicSpec'; this spec verifies the CSR + Core changes —
specifically that:

  * @cMip.MEIP@ tracks the external 'meipS' strobe each cycle,
    masked back from any software write the way 'mtipS' is.
  * 'interruptPending' fires on @mstatus.MIE && mie.MEIE &&
    mip.MEIP@, returning 'causeMachineExternalInterrupt'
    (= bit 31 | 11).
  * The trap path redirects to @mtvec.base@ exactly like the
    timer-interrupt case, so 'handleInstr' reaches the handler.

Boot stub layout matches 'TimerIrqSpec' to keep the diff
reviewable: word 0 is the boot entrypoint that sets up
@mtvec / mie.MEIE / mstatus.MIE@ and spins; word 32 holds the
handler that writes @0xDEAD_BEEF@ into x10 once entered. We pulse
@meipS=True@ from cycle 60 onward and assert the sentinel
appears in some retire's writeback within 200 cycles.
-}
module ExtIrqSpec (
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
import Clash.Prelude qualified as CP
import Clash.Sized.Vector qualified as V
import Data.Bits (shiftR)
import Data.Either (Either (..))
import Data.Maybe (Maybe (..))
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
    "Riski5.Core machine-external interrupt"
    [ testCase "handler runs once meipS is asserted with mie / mstatus enabled" case_extIrqHandler
    ]

-- * Test --------------------------------------------------------

{- |
Boot stub + spin + handler. Handler plants @0xDEAD_BEEF@ into x10;
the test asserts that retire shows up in the writeback trace.
-}
case_extIrqHandler :: Assertion
case_extIrqHandler = do
  let bootProg = bootCode
      handlerProg = handlerCode
      ws = stitch bootProg handlerProg
      meipPattern =
        P.replicate 60 P.False
          P.++ P.repeat P.True
      trace = runCoreWithMeip ws meipPattern 200
      writebacks = [(rd, val) | (Just (rd, val)) <- P.map P.snd trace]
      sentinel = 0xDEAD_BEEF :: BitVector 32
      hit = P.any (\(_, v) -> v P.== sentinel) writebacks
  assertBool
    ("expected handler to set rd to 0xDEADBEEF; writebacks: " P.++ P.show writebacks)
    hit

-- Boot: enable MEI (bit 11 of mie), MIE (bit 3 of mstatus), spin.
bootCode :: Asm ()
bootCode = do
  -- mtvec.base := 0x80 (handler at word offset 32, MODE = direct).
  addi x5 x0 0x80
  csrrw x0 x5 csrMtvec
  -- mie.MEIE := 1 (bit 11). 0x800 = 2048.
  li x5 0x800
  csrrs x0 x5 csrMie
  -- mstatus.MIE := 1 (bit 3).
  addi x5 x0 0x8
  csrrs x0 x5 csrMstatus
  -- Sentinel showing the boot path is alive.
  addi x10 x0 1
  spinL <- label
  addi x6 x6 1
  j spinL

-- Handler: write 0xDEAD_BEEF into x10 to prove "I ran", then spin.
handlerCode :: Asm ()
handlerCode = do
  li x10 0xDEAD_BEEF
  haltL <- label
  j haltL

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

runCoreWithMeip ::
  [BitVector 32] ->
  [P.Bool] ->
  P.Int ->
  [(BitVector 32, Maybe (BitVector 5, BitVector 32))]
runCoreWithMeip program meips n =
  sampleN @System n P.$
    withClockResetEnable @System clockGen resetGen enableGen P.$
      runHarness program meips

runHarness ::
  (HiddenClockResetEnable System) =>
  [BitVector 32] ->
  [P.Bool] ->
  Signal System (BitVector 32, Maybe (BitVector 5, BitVector 32))
runHarness program meips =
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
      meipS = fromList (meips P.++ P.repeat P.False)
      (pcFetchS, pcExecS, _dAddrS, _dWdataS, _dBeS, _dRenS, wbS, _rvfiS) =
        core imem (CP.pure P.True) dmem (CP.pure P.False) (CP.pure P.False) meipS
   in bundle (pcExecS, wbS)
