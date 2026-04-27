-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : PlicSpec
Description : Sim tests for the SiFive-PLIC-1.0.0-compatible interrupt controller.

Five things to pin down:

  1. Priority register write / read round-trip — software can set
     a 4-bit priority for source N and read the same value back.

  2. Enable register write / read round-trip — same shape, just
     for the enable mask.

  3. External IRQ → pending — driving @extIrqs@ for one cycle
     latches @pending[i]@.

  4. meipS — fires combinationally when a pending bit is set, the
     matching enable bit is set, the matching priority > threshold,
     and the source isn't 0 (reserved).

  5. Claim / complete — reading the claim register returns the
     selected source ID and clears its pending bit; writing the same
     ID to complete is a no-op-shaped clear (idempotent).
-}
module PlicSpec (
  tests,
) where

import Clash.Prelude (
  BitVector,
  HiddenClockResetEnable,
  Signal,
  System,
  bundle,
  clockGen,
  enableGen,
  fromList,
  resetGen,
  sampleN,
  withClockResetEnable,
  (+),
 )
import Clash.Prelude qualified as CP
import Riski5.MemMap (plicBase)
import Riski5.Plic (PlicSources, plic)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, testCase)
import Prelude qualified as P

tests :: TestTree
tests =
  testGroup
    "Riski5.Plic"
    [ testCase "priority write / read round-trip" case_priorityRoundtrip
    , testCase "enable write / read round-trip" case_enableRoundtrip
    , testCase "external IRQ latches pending" case_pendingLatches
    , testCase "meipS rises when pending+enable+priority>threshold" case_meipRises
    , testCase "claim returns highest-priority pending source" case_claimReturnsId
    , testCase "claim clears the returned pending bit" case_claimClearsPending
    ]

-- * Helpers ---------------------------------------------------------

{- | Drive the PLIC for @n@ cycles with the given streams; return the
trace of @(rdata, meip)@ samples.
-}
runPlic ::
  P.Int ->
  [P.Bool] ->
  [BitVector 32] ->
  [BitVector 32] ->
  [BitVector 4] ->
  [BitVector PlicSources] ->
  [(BitVector 32, P.Bool)]
runPlic n sels addrs wdatas bes irqs =
  let go ::
        (HiddenClockResetEnable System) =>
        Signal System (BitVector 32, P.Bool)
      go =
        let selS = fromList (sels P.++ P.repeat P.False)
            addrS = fromList (addrs P.++ P.repeat 0)
            wdataS = fromList (wdatas P.++ P.repeat 0)
            beS = fromList (bes P.++ P.repeat 0)
            renS = CP.pure P.False
            irqsS = fromList (irqs P.++ P.repeat 0)
            (rdata, meip) = plic selS addrS wdataS beS renS irqsS
         in bundle (rdata, meip)
   in sampleN @System n P.$
        withClockResetEnable @System clockGen resetGen enableGen go

-- * Cases -----------------------------------------------------------

-- Write priority for source 1 = 5, read it back.
case_priorityRoundtrip :: Assertion
case_priorityRoundtrip = do
  -- Cycle 0: reset.
  -- Cycle 1: write 5 to priority[1] (offset 0x04).
  -- Cycle 2: idle.
  -- Cycle 3: read priority[1].
  let sels = [P.False, P.True, P.False, P.True] P.++ P.repeat P.False
      addrs = [0, plicBase + 0x04, 0, plicBase + 0x04] P.++ P.repeat 0
      wdatas = [0, 5, 0, 0] P.++ P.repeat 0
      bes = [0, 0xF, 0, 0] P.++ P.repeat 0
      irqs = P.repeat 0
      trace = runPlic 6 sels addrs wdatas bes irqs
      (rd, _) = trace P.!! 3
  assertEqual "priority[1] reads back 5" 5 rd

-- Write enable mask, read it back.
case_enableRoundtrip :: Assertion
case_enableRoundtrip = do
  let sels = [P.False, P.True, P.False, P.True] P.++ P.repeat P.False
      addrs = [0, plicBase + 0x2000, 0, plicBase + 0x2000] P.++ P.repeat 0
      -- 0x2 enables source 1 (bit 1); bit 0 is forced to 0 for
      -- source 0 reserved.
      wdatas = [0, 0xFE, 0, 0] P.++ P.repeat 0
      bes = [0, 0xF, 0, 0] P.++ P.repeat 0
      irqs = P.repeat 0
      trace = runPlic 6 sels addrs wdatas bes irqs
      (rd, _) = trace P.!! 3
  assertEqual "enable mask reads back 0xFE (bit 0 forced low)" 0xFE rd

-- Driving an IRQ on source 1 (bit 1) sets pending[1].
case_pendingLatches :: Assertion
case_pendingLatches = do
  -- Cycle 0: reset.
  -- Cycle 1: drive irqs = 0b0000_0010 (source 1).
  -- Cycle 2: stop driving; pending should still be 0b0000_0010.
  -- Cycle 3: read pending register.
  let sels = [P.False, P.False, P.False, P.True] P.++ P.repeat P.False
      addrs = [0, 0, 0, plicBase + 0x1000] P.++ P.repeat 0
      wdatas = P.repeat 0
      bes = P.repeat 0
      irqs = [0, 0b10, 0, 0] P.++ P.repeat 0
      trace = runPlic 6 sels addrs wdatas bes irqs
      (rd, _) = trace P.!! 3
  assertEqual "pending = 0b10 after source-1 IRQ" 0b10 rd

-- Configure: priority[1]=3, threshold=0, enable=0x2, then drive IRQ
-- on source 1. meipS should rise once pending[1] latches.
case_meipRises :: Assertion
case_meipRises = do
  -- Cycle 0: reset.
  -- Cycle 1: write priority[1] = 3.
  -- Cycle 2: write enable = 0xFE (enables sources 1..7).
  -- Cycle 3: drive IRQ on source 1.
  -- Cycle 4..: idle. meipS should be True from cycle 4 onward.
  let sels = [P.False, P.True, P.True, P.False] P.++ P.repeat P.False
      addrs = [0, plicBase + 0x04, plicBase + 0x2000, 0] P.++ P.repeat 0
      wdatas = [0, 3, 0xFE, 0] P.++ P.repeat 0
      bes = [0, 0xF, 0xF, 0] P.++ P.repeat 0
      irqs = [0, 0, 0, 0b10] P.++ P.repeat 0b10
      trace = runPlic 8 sels addrs wdatas bes irqs
      meips = P.map P.snd trace
  assertBool
    ("expected meipS to rise within 8 cycles, got: " P.++ P.show meips)
    (P.or (P.drop 4 meips))

-- Configure two sources, drive both, verify claim returns the
-- highest-priority one (source 2 with priority 5 wins over source
-- 1 with priority 3).
case_claimReturnsId :: Assertion
case_claimReturnsId = do
  -- Cycle 0: reset.
  -- Cycle 1: priority[1] = 3.
  -- Cycle 2: priority[2] = 5.
  -- Cycle 3: enable = 0xFE.
  -- Cycle 4: drive irqs = 0b110 (sources 1 and 2).
  -- Cycle 5: keep driving so pending stays.
  -- Cycle 6: read claim — should return 2.
  let sels =
        [ P.False
        , P.True
        , P.True
        , P.True
        , P.False
        , P.False
        , P.True
        ]
          P.++ P.repeat P.False
      addrs =
        [ 0
        , plicBase + 0x04
        , plicBase + 0x08
        , plicBase + 0x2000
        , 0
        , 0
        , plicBase + 0x20_0004
        ]
          P.++ P.repeat 0
      wdatas = [0, 3, 5, 0xFE, 0, 0, 0] P.++ P.repeat 0
      bes = [0, 0xF, 0xF, 0xF, 0, 0, 0] P.++ P.repeat 0
      irqs = P.replicate 4 0 P.++ P.repeat 0b110
      trace = runPlic 8 sels addrs wdatas bes irqs
      (rd, _) = trace P.!! 6
  assertEqual "claim returns source-2 (highest priority)" 2 rd

-- A claim read clears the pending bit of the returned source.
case_claimClearsPending :: Assertion
case_claimClearsPending = do
  -- Cycle 0: reset.
  -- Cycle 1: priority[1] = 3.
  -- Cycle 2: enable = 0xFE.
  -- Cycle 3: pulse irqs = 0b10 once (just one cycle so we don't
  --          re-set pending after the claim clears it).
  -- Cycle 4: idle.
  -- Cycle 5: claim — returns 1, clears pending[1].
  -- Cycle 6: idle so the pending state advances past the clear edge.
  -- Cycle 7: read pending — should be 0.
  let sels =
        [ P.False
        , P.True
        , P.True
        , P.False
        , P.False
        , P.True
        , P.False
        , P.True
        ]
          P.++ P.repeat P.False
      addrs =
        [ 0
        , plicBase + 0x04
        , plicBase + 0x2000
        , 0
        , 0
        , plicBase + 0x20_0004
        , 0
        , plicBase + 0x1000
        ]
          P.++ P.repeat 0
      wdatas = [0, 3, 0xFE, 0, 0, 0, 0, 0] P.++ P.repeat 0
      bes = [0, 0xF, 0xF, 0, 0, 0, 0, 0] P.++ P.repeat 0
      irqs = [0, 0, 0, 0b10] P.++ P.repeat 0
      trace = runPlic 12 sels addrs wdatas bes irqs
      (rdPending, _) = trace P.!! 7
  assertEqual "pending = 0 after claim clears source 1" 0 rdPending
