-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : AvalonMmSpec
Description : Unit tests for the Avalon-MM master-side bus shim.

'Riski5.AvalonMm' is a record + a handful of one-line helpers, so
the tests here are likewise small: they pin the master-side →
strobe-signal mapping ('avRead' / 'avWrite') and round-trip the
combinator that bundles parallel signals into an 'AvalonMmBus'
value. The payoff is that a future refactor of the shim (adding
a field, changing the @byteenable = 0 ⇒ no write@ convention,
etc.) breaks a test instead of silently propagating into the
JTAG UART and SDRAM IP wrappers.
-}
module AvalonMmSpec (
  tests,
) where

import Clash.Prelude (BitVector, Signal, System, fromList, sampleN)
import Riski5.AvalonMm (
  AvalonMmBus (..),
  AvalonMmReply (..),
  avRead,
  avWrite,
  mkAvalonMmBus,
  mkAvalonMmReply,
 )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, testCase)
import Prelude (Bool (..), Int, ($))
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.AvalonMm"
    [ testCase "avRead is sel ∧ re" case_avRead
    , testCase "avWrite is sel ∧ (be /= 0)" case_avWrite
    , testCase "avWrite is false when be = 0, even with sel" case_avWriteNoBe
    , testCase "avRead is false when deselected" case_avReadNoSel
    , testCase "mkAvalonMmBus round-trips field values" case_busRoundTrip
    , testCase "mkAvalonMmReply round-trips field values" case_replyRoundTrip
    ]

-- * avRead / avWrite strobe helpers --------------------------------

-- | The only "interesting" logic in the shim is the derivation of
-- active-high read/write strobes from the master-side fields. These
-- four cases lock the truth table.
case_avRead :: Assertion
case_avRead =
  assertBool "sel ∧ re should drive read high" $
    avRead
      AvalonMmBus
        { ambSel = True
        , ambAddr = 0x1000_0000
        , ambWdata = 0
        , ambBe = 0
        , ambRe = True
        }

case_avWrite :: Assertion
case_avWrite =
  assertBool "sel ∧ any byte-enable bit should drive write high" $
    avWrite
      AvalonMmBus
        { ambSel = True
        , ambAddr = 0x1000_0000
        , ambWdata = 0xDEAD_BEEF
        , ambBe = 0b0001
        , ambRe = False
        }

case_avWriteNoBe :: Assertion
case_avWriteNoBe =
  assertBool "be = 0 must not register as a write, even when selected" $
    P.not $
      avWrite
        AvalonMmBus
          { ambSel = True
          , ambAddr = 0x1000_0000
          , ambWdata = 0xDEAD_BEEF
          , ambBe = 0
          , ambRe = False
          }

case_avReadNoSel :: Assertion
case_avReadNoSel =
  assertBool "deselected bus must not register as a read even with re high" $
    P.not $
      avRead
        AvalonMmBus
          { ambSel = False
          , ambAddr = 0
          , ambWdata = 0
          , ambBe = 0
          , ambRe = True
          }

-- * Signal bundling round-trips -----------------------------------

-- | Feed three distinct cycle-samples into 'mkAvalonMmBus' and
-- verify every field comes out the other side unchanged. Catches
-- an accidental field swap inside the helper.
case_busRoundTrip :: Assertion
case_busRoundTrip = do
  let sels = [True, False, True]
      addrs = [0x2000_0000, 0x2000_0004, 0x2000_0008] :: [BitVector 32]
      wdata = [0x1111_1111, 0x2222_2222, 0x3333_3333] :: [BitVector 32]
      bes = [0b1111, 0b0000, 0b0011] :: [BitVector 4]
      res = [False, True, True]
      busS :: Signal System AvalonMmBus
      busS =
        mkAvalonMmBus
          (fromList sels)
          (fromList addrs)
          (fromList wdata)
          (fromList bes)
          (fromList res)
      observed = sampleN (3 :: Int) busS
  assertEqual "ambSel" sels (P.map ambSel observed)
  assertEqual "ambAddr" addrs (P.map ambAddr observed)
  assertEqual "ambWdata" wdata (P.map ambWdata observed)
  assertEqual "ambBe" bes (P.map ambBe observed)
  assertEqual "ambRe" res (P.map ambRe observed)

case_replyRoundTrip :: Assertion
case_replyRoundTrip = do
  let rdata = [0xAAAA_AAAA, 0xBBBB_BBBB] :: [BitVector 32]
      ready = [False, True]
      replyS :: Signal System AvalonMmReply
      replyS = mkAvalonMmReply (fromList rdata) (fromList ready)
      observed = sampleN (2 :: Int) replyS
  assertEqual "armRdata" rdata (P.map armRdata observed)
  assertEqual "armReady" ready (P.map armReady observed)
