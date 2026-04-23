-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : UartBackpressureSpec
Description : Regression cover for the CM-4 Altera-JTAG-UART deadlock.

Brings the CM-4 silicon lesson into @cabal test@ so whoever touches
@firmware/phase2/coremark-port/core_portme.c::uart_send_char@ next
can't quietly re-introduce the back-to-back-@sw@ pattern that hung
the real Altera IP at every 64-byte FIFO boundary.

The tests run against 'Riski5.Soc.socSimAlteraUart', which wires
'Riski5.JtagUart.jtagUartAlteraSim' (the Altera-IP-faithful model
with a 64-byte TX FIFO + drain-gap requirement) in as the UART.
Two firmware images exercise the contract:

  * __@deadlockProg@__ — 80 unrolled @sw@ instructions to the UART
    @DATA@ register with no @WSPACE@ poll in between. On a faithful
    model this fills the FIFO after 64 writes, raises waitrequest,
    the core stalls with @av_write=1@ sustained, and the drain
    model refuses to advance. Test asserts the TX stream accepts
    __at most__ 64 bytes regardless of how long we run the sim —
    i.e. the bug reproduces.

  * __@polledProg@__ — poll @WSPACE@ (bits [31:16] of CONTROL)
    before every write, exactly the CM-2-port pattern. Each poll
    is a @lw@ transaction (no write on that cycle), which gives
    the drain model its required gap. Test asserts all 80 bytes
    land on the TX stream — i.e. the fix actually fixes it.

Neither test needs Quartus or silicon — pure Clash @sampleN@ over
@socSimAlteraUart@. They catch the regression in CI before the
next bring-up instead of weeks later on the DE2.

See 'Riski5.JtagUart.jtagUartAlteraSim' for the model's internal
rationale, and @docs/perf/coremark-2026-04-23.md@ for the
silicon-side discovery that motivated the fix.
-}
module UartBackpressureSpec (
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
import Riski5.Soc (SocInSim (..), SocOutSim (..), socSimAlteraUart)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, testCase)
import Control.Monad (replicateM_)
import Prelude (Either (..), Int, Maybe (..), error, ($), (++), (==))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "UART back-pressure (Altera IP faithful sim)"
    [ testCase "80 back-to-back sw's stall at the 64-byte FIFO (deadlock reproduces)" case_deadlock
    , testCase "80 WSPACE-polled sw's land every byte on the TX stream" case_polled
    ]

-- * Constants ------------------------------------------------------

-- | How many writes each firmware attempts. Needs to exceed the
-- 64-byte FIFO so 'deadlockProg' actually runs into the full
-- condition; 80 gives 16 bytes of margin past the boundary.
nWrites :: Int
nWrites = 80

uartDataBase :: CP.BitVector 20
uartDataBase = 0x10000

-- * Firmware images ------------------------------------------------

{- | 80 unrolled @sw@ instructions to @0x1000_0000@, writing the
constant byte @0x41@ ('A') each time. No poll, no gap — the
pipeline's steady-state is one @sw@ per cycle, so @av_write@ is
continuously asserted across the stall that fires at write 65.
-}
deadlockProg :: Asm ()
deadlockProg = do
  lui x10 uartDataBase -- a0 = 0x1000_0000
  addi x11 x0 0x41 -- a1 = 'A'
  replicateM_ nWrites $ emit (Sw x10 x11 0)
  spin <- label
  j spin

{- | Same total write count, but with a @WSPACE@ poll before each
one. The poll is a @lw@ from @0x1000_0004@ (CONTROL); WSPACE lives
in bits [31:16]. If it's zero we branch back to poll again. Each
@lw@ naturally has @av_write=0@ on its X cycle, giving the drain
model its required gap.
-}
polledProg :: Asm ()
polledProg = do
  lui x10 uartDataBase -- a0 = UART DATA
  addi x12 x10 4 -- a2 = UART CTL = 0x1000_0004
  addi x11 x0 0x41 -- a1 = 'A'
  replicateM_ nWrites $ do
    poll <- label
    emit (Lw x13 x12 0) -- a3 = *(CTL)
    srli x13 x13 16 -- a3 = WSPACE
    beqz x13 poll -- spin while WSPACE = 0
    emit (Sw x10 x11 0) -- sw a1, 0(a0)
  spin <- label
  j spin

-- * Assembly helpers -----------------------------------------------

assembleOrFail :: P.String -> Asm () -> [BitVector 32]
assembleOrFail nm prog = case assemble prog of
  Left err -> error (nm ++ " failed to assemble: " ++ P.show err)
  Right ws -> ws

deadlockWords :: [BitVector 32]
deadlockWords = assembleOrFail "deadlockProg" deadlockProg

polledWords :: [BitVector 32]
polledWords = assembleOrFail "polledProg" polledProg

-- * Harness --------------------------------------------------------

{- | Clash-simulate 'socSimAlteraUart' on a given firmware image
for @nCycles@, returning the list of TX bytes the UART model
accepted (i.e. wrote into its FIFO — one element per @sw@ that
committed through the finite-FIFO back-pressure contract).

Images larger than 256 instructions truncate; the phase-1 progVec
size of 256 words is plenty of headroom for both firmwares at
@nWrites=80@ (deadlock: ~82 insts, polled: ~482 insts — widen the
vec below if 'nWrites' ever grows past the polled program's
in-loop expansion factor).
-}
runSoc :: [BitVector 32] -> Int -> [CP.BitVector 8]
runSoc progWords nCycles =
  let progVec :: Vec 512 (BitVector 32)
      progVec =
        V.unsafeFromList
          (P.take 512 (progWords ++ P.repeat 0x0000_0013))
      dataVec :: Vec 64 (BitVector 32)
      dataVec = CP.repeat 0
      inputSig =
        fromList (P.repeat SocInSim {sisSwitches = 0, sisKeys = 0xF, sisSramDqIn = 0})
      go ::
        (HiddenClockResetEnable System) =>
        Signal System SocOutSim
      go = socSimAlteraUart progVec dataVec inputSig
      trace =
        sampleN @System nCycles $
          withClockResetEnable @System clockGen resetGen enableGen go
   in [b | SocOutSim {sosUartTx = Just b} <- trace]

-- * Cases ----------------------------------------------------------

case_deadlock :: Assertion
case_deadlock = do
  -- Run long enough that if the model were wrong (accepted
  -- everything regardless), all 80 writes would land. 2000 cycles
  -- is generous: with the 5-stage pipeline at 1 IPC steady-state,
  -- 82 instructions retire in ~88 cycles once warmed up. Any byte
  -- count >64 is a model bug; any byte count <64 is a test bug
  -- (not enough cycles to drain the setup + fill the FIFO).
  let bytes = runSoc deadlockWords 2000
  assertEqual "exactly 64 bytes fit into the FIFO before waitrequest hangs" 64 (P.length bytes)
  assertBool "every accepted byte is the 'A' constant" (P.all (== 0x41) bytes)

case_polled :: Assertion
case_polled = do
  -- Polled firmware spends many cycles per byte (inner poll loop
  -- + sw). Budget: ~6 cycles per poll-loop iteration steady-state
  -- × nWrites = ~480 cycles, plus pipeline warm-up and drain
  -- back-pressure — give 4000 cycles to finish comfortably.
  let bytes = runSoc polledWords 4000
  assertEqual "all 80 bytes land on the TX stream" nWrites (P.length bytes)
  assertBool "every accepted byte is the 'A' constant" (P.all (== 0x41) bytes)
