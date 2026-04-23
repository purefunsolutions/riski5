-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : CoreMarkSimSpec
Description : Real-CoreMark-bytes sim — Phase-2B diagnostic probe (__disabled__).

__Not currently registered in "Spec"__ — the sim-harness doesn't
reproduce the silicon bitstream's behaviour yet (even baseline
regfileAsync produces zero UART output in 50k cycles, while the
real bitstream prints its banner within milliseconds). Something
about the sim wrapper — most likely 'socSimFull''s finite-FIFO
UART drain model, or the @sramChipSim@ 512 KB vector's timing,
or a clock-domain nuance — makes CoreMark hang in sim even
without the phase-2B patch. Until that sim/silicon divergence is
fixed, this module is kept in-tree (via 'riski5.cabal''s
@other-modules@) but not wired into 'Test.Tasty.defaultMain' so
@cabal test@ stays green.

__Original intent.__ Load the EEMBC CoreMark 1.01 image
(cross-compiled by @pkgs/coremark/package.nix@ and frozen into
'CoreMarkRealBytes') into 'Riski5.Soc.socSimFull' and run the
Clash sim long enough to observe the first few UART bytes. With
the phase-2B patch applied: if the sim hangs (no UART in N
cycles), we've reproduced the silicon bug in a diffable form.
If it still passes, the bug is physical-timing / synthesis-
specific and needs Quartus SignalTap on the real DE2.

__Diagnostic next steps.__ Before re-enabling:

  1. Figure out why baseline CoreMark sim produces zero output.
     Candidates: (a) 'jtagUartAlteraSim' drain-gap model is too
     strict for CoreMark's WSPACE-poll pattern; (b) 'sramChipSim'
     has a functional bug that corrupts CoreMark's stack /
     .data / BSS; (c) CoreMark's init code depends on something
     (GPIO reset signal? CSR init state?) that 'socSimFull'
     doesn't model correctly.
  2. Likely first experiment: rebuild the module against a
     simpler UART sim ('jtagUartSim' — infinite FIFO, constant
     ready), keeping SRAM + BRAM + mcycle plumbing intact. If
     that produces output, the finite-FIFO UART model is to
     blame.
  3. Second experiment: shrink 'sramInit' to 32 K half-words and
     see whether the early boot path reaches any UART write.
     If not, the SRAM chip model is at fault (not the size).
  4. Once the baseline sim produces output, re-apply the P2-B
     patch and compare: if with-P2-B produces nothing but
     without-P2-B produces the banner, we've reproduced the hang.
-}
module CoreMarkSimSpec (
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
import CoreMarkRealBytes (coreMarkRealBytes)
import Data.List (isPrefixOf)
import Riski5.Soc (SocInFull (..), SocOutSim (..), socSimFull)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase)
import Prelude (Int, Maybe (..), String, ($), (++), (.))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "CoreMark real-bytes sim (Phase 2B probe)"
    [ testCase "firmware emits some UART output within 500k cycles" case_emits
    , testCase "firmware emits the CoreMark banner within 500k cycles" case_banner
    ]

-- * Harness --------------------------------------------------------

runCoreMark :: Int -> [CP.BitVector 8]
runCoreMark nCycles =
  let progVec :: Vec 4096 (BitVector 32)
      progVec =
        V.unsafeFromList
          (P.take 4096 (coreMarkRealBytes ++ P.repeat 0x0000_0013))
      dataVec :: Vec 1 (BitVector 32)
      dataVec = CP.repeat 0
      -- Full 512 KB of SRAM to match the real board — CoreMark puts
      -- its stack pointer at 0x2008_0000 (top of 512 KB), so the
      -- vector size matters: @sramChipSim@ wraps addresses modulo
      -- the vector length, and a too-small vec would alias stack
      -- writes back into BSS. 262144 half-words × 2 bytes = 512 KB.
      sramInit :: Vec 262144 (BitVector 16)
      sramInit = CP.repeat 0
      inputSig =
        fromList (P.repeat SocInFull {sifSwitches = 0, sifKeys = 0xF})
      go ::
        (HiddenClockResetEnable System) =>
        Signal System SocOutSim
      go = socSimFull progVec dataVec sramInit inputSig
      trace =
        sampleN @System nCycles $
          withClockResetEnable @System clockGen resetGen enableGen go
   in [b | SocOutSim {sosUartTx = Just b} <- trace]

-- * Cases ----------------------------------------------------------

bytesToString :: [CP.BitVector 8] -> String
bytesToString = P.map (P.toEnum . P.fromIntegral)

-- | Keep this a knob — 50k is enough for the BSS-init + .data-init
-- + portable_init paths to complete on a working sim without
-- taking minutes; 500k is enough for the CoreMark banner to fully
-- print. The large-Vec SRAM model makes each sim cycle expensive.
nCycles :: Int
nCycles = 50000

{- | Loose smoke check: by 'nCycles', CoreMark's startup code
should have at least reached @portable_init@ → first
@ee_printf@ → first @uart_send_char@ call. If no bytes land,
the firmware is stuck somewhere in the init path.
-}
case_emits :: Assertion
case_emits = do
  let bytes = runCoreMark nCycles
  assertBool
    ( "expected ≥ 1 UART byte in "
        ++ P.show nCycles
        ++ " cycles; got "
        ++ P.show (P.length bytes)
        ++ " — firmware may be hung. First 32 bytes: "
        ++ P.show (P.take 32 bytes)
    )
    (P.length bytes P.>= 1)

{- | Stronger check: by 'nCycles', the @2K performance run
parameters for coremark.\\n@ banner (from @core_main.c@'s first
@ee_printf@) should have landed verbatim on the UART stream.
If the prefix doesn't match, the firmware either hung mid-banner
or emitted garbage — either way, diagnostic value.
-}
case_banner :: Assertion
case_banner = do
  let bytes = runCoreMark nCycles
      got = bytesToString bytes
      expected = "2K performance run parameters for coremark.\n"
  assertBool
    ( "expected CoreMark banner at start of UART stream; got prefix "
        ++ P.show (P.take 80 got)
    )
    (expected `isPrefixOf` got)
