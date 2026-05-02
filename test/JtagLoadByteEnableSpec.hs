-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : JtagLoadByteEnableSpec
Description : Regression test for the L-3 JTAG-load byteenable bug.

Pinned 2026-05-01: 'Riski5.Soc.jtagMuxedSdram' previously hard-coded
the SDRAM bus byteenable to @0xF@ whenever the JTAG-load arbiter
owned the bus, ignoring the JTAG-Master IP's @master_byteenable@
output. That silently promoted every @master_write_8@ /
@master_write_16@ from system-console into a full 32-bit chip write
with whatever stale bytes the IP had left in the upper lanes — the
LSWP pin-capture probe (commit 3d3dcb2) caught it on silicon by
reporting @write_count += 2@ for what should have been a single
chip write.

This spec exercises @soc@ at the SocInSim boundary, drives the
JTAG-load path with a sub-word write (@sisJtagLoadBe = 0b0011@),
and asserts that the byteenable that emerges on @soSdramBus.sibBe@
matches what we drove — not the old hard-coded @0xF@.
-}
module JtagLoadByteEnableSpec (
  tests,
) where

import Clash.Prelude (
  BitVector,
  System,
  fromList,
  sampleN,
 )
import Clash.Sized.Vector qualified as V
import Riski5.Sdram (SdramIpBus (..))
import Riski5.Soc (SocOut (..), SocOutSim (..), defaultSocInSim, SocInSim (..), socSim)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)
import Prelude (Bool (..), Maybe (..), filter, head, map, take, ($), (.), (==), (>))
import Prelude qualified as P

-- | Drive the JTAG-load path for a fixed number of cycles. The
-- arbiter ('jtagMuxOwnerS') needs a few cycles to switch to JTAG
-- ownership and the SDRAM controller's init takes ~4150 cycles
-- (NOP + PRECHARGE-ALL + 8 refreshes + LMR + T_MRD), so we let the
-- sim run long enough that the SDRAM controller is in PhIdle
-- when the JTAG request arrives. 6000 cycles is comfortably past
-- the controller's init floor.
runJtagLoad ::
  -- | sisJtagLoadBe (per-cycle byteenable)
  BitVector 4 ->
  -- | sisJtagLoadWdata
  BitVector 32 ->
  [SocOutSim]
runJtagLoad be wdata =
  let -- We need *at least* one prog/data slot to satisfy socSim's
      -- length>0 KnownNat constraints, and 16 fits comfortably.
      progVec = V.repeat 0 :: V.Vec 16 (BitVector 32)
      dataVec = V.repeat 0 :: V.Vec 16 (BitVector 32)
      -- Drive JTAG-load mode + write request continuously from
      -- cycle 0 onward. The arbiter's sticky-FSM sees jtagReqS=True
      -- the same cycle it sees mode=True, transitions to JmxJtag
      -- on the first sdramRawReady=True (which the SdrController
      -- reaches once init completes).
      stim = defaultSocInSim
        { sisJtagLoadMode = True
        , sisJtagLoadAddr = 0x80700100 -- arbitrary SDRAM address
        , sisJtagLoadWdata = wdata
        , sisJtagLoadWe = True
        , sisJtagLoadBe = be
        }
      -- Tcl-blink-style, just constant `stim`. socSim consumes a
      -- Signal so we use 'fromList' over a (constant, finite) list.
      sig = fromList (P.replicate 6000 stim)
      sample = sampleN @System 6000 (socSim progVec dataVec sig)
   in sample

-- | Filter the 6000-cycle SocOutSim trace down to the cycles where
-- the SDRAM bus was actually being driven by JTAG (sibCs && sibWr).
-- These are the cycles 'jtagMuxedSdram' has handed the bus over to
-- the JTAG path — the cycles where the byteenable bug surfaced.
sdramJtagDriveCycles :: [SocOutSim] -> [SdramIpBus]
sdramJtagDriveCycles =
  filter (\b -> sibCs b P.&& sibWr b)
    . map (soSdramBus . sosOut)

tests :: TestTree
tests =
  testGroup
    "Riski5.Soc.jtagMuxedSdram byteenable propagation"
    [ testCase "lo-half byteenable 0b0011 reaches sibBe (regression for hard-coded 0xF)" $ do
        let trace = sdramJtagDriveCycles (runJtagLoad 0b0011 0xDEADBEEF)
        assertBool
          ("expected at least one cycle with sibCs && sibWr; got "
            P.++ P.show (P.length trace))
          (P.length trace > 0)
        let firstBe = sibBe (head trace)
        assertEqual
          "sibBe on the JTAG-driven cycle"
          (0b11 :: BitVector 2)
          firstBe

    , testCase "hi-half byteenable 0b1100 reaches sibBe" $ do
        let trace = sdramJtagDriveCycles (runJtagLoad 0b1100 0xDEADBEEF)
        assertBool
          ("expected at least one cycle with sibCs && sibWr; got "
            P.++ P.show (P.length trace))
          (P.length trace > 0)
        let firstBe = sibBe (head trace)
        assertEqual
          "sibBe on the JTAG-driven cycle"
          (0b11 :: BitVector 2)
          firstBe

    , testCase "single-byte byteenable 0b0001 reaches sibBe" $ do
        let trace = sdramJtagDriveCycles (runJtagLoad 0b0001 0xDEADBEEF)
        assertBool
          ("expected at least one cycle with sibCs && sibWr; got "
            P.++ P.show (P.length trace))
          (P.length trace > 0)
        let firstBe = sibBe (head trace)
        assertEqual
          "sibBe on the JTAG-driven cycle"
          (0b01 :: BitVector 2)
          firstBe

    , testCase "full word byteenable 0b1111 reaches sibBe (no regression for the masked path)" $ do
        let trace = sdramJtagDriveCycles (runJtagLoad 0b1111 0xDEADBEEF)
        assertBool
          ("expected at least one cycle with sibCs && sibWr; got "
            P.++ P.show (P.length trace))
          (P.length trace > 0)
        let firstBe = sibBe (head trace)
        assertEqual
          "sibBe on the JTAG-driven cycle"
          (0b11 :: BitVector 2)
          firstBe
    ]
