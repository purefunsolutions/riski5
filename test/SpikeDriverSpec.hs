-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}

{- |
Module      : SpikeDriverSpec
Description : Smoke tests for 'Riski5.SpikeDriver'.

Verifies the three things the driver can fail at independently:

  1. 'parseCommitLine' correctly pulls fields out of the
     @core N: P 0xPC (0xINSN)…@ format the Spike @--log-commits@
     flag emits — tested against hand-written reference lines.
  2. The @as + ld + spike@ toolchain on the devshell is present
     and functional — tested by assembling a 3-instruction
     program via 'Riski5.Asm' and running it through 'runSpike'.
  3. 'firmwareCommits' correctly strips Spike's boot-ROM prelude
     (the five instructions at @0x1000@ that read the DTB and
     jump to our entry) so downstream triple-diff sees only our
     code.

This is the last purely-mechanical layer before 'test/SpikeDiffSpec.hs'
can land. Triple-diff needs 'Riski5.Reference' and the Clash core
to produce the same information in a matching shape; that spec
comes next.
-}
module SpikeDriverSpec (tests) where

import Clash.Prelude (BitVector)
import Data.Either qualified as DE
import Data.Word (Word32)
import Riski5.Asm (addi, assemble)
import Riski5.ISA (x0, x1, x2)
import Riski5.SpikeDriver (
  SpikeCommit (..),
  SpikeOptions (..),
  defaultSpikeOptions,
  firmwareCommits,
  parseCommitLine,
  runSpike,
 )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Riski5.SpikeDriver"
    [ parserTests
    , invocationTests
    ]

-- * Pure parser

parserTests :: TestTree
parserTests =
  testGroup
    "parseCommitLine"
    [ testCase "AUIPC boot-ROM line: writes x5 = 0x1000" $
        parseCommitLine "core   0: 3 0x00001000 (0x00000297) x5  0x00001000"
          @?= Just
            SpikeCommit
              { scPc = 0x0000_1000
              , scInsn = 0x0000_0297
              , scRegWrite = Just (5, 0x0000_1000)
              , scMemAddr = Nothing
              }
    , testCase "LW boot-ROM line: writes x5 and touches mem" $
        parseCommitLine "core   0: 3 0x0000100c (0x0182a283) x5  0x80000000 mem 0x00001018"
          @?= Just
            SpikeCommit
              { scPc = 0x0000_100c
              , scInsn = 0x0182_a283
              , scRegWrite = Just (5, 0x8000_0000)
              , scMemAddr = Just 0x0000_1018
              }
    , testCase "JALR line: no register write, no mem" $
        parseCommitLine "core   0: 3 0x00001010 (0x00028067)"
          @?= Just
            SpikeCommit
              { scPc = 0x0000_1010
              , scInsn = 0x0002_8067
              , scRegWrite = Nothing
              , scMemAddr = Nothing
              }
    , testCase "non-commit line (tohost warning) rejected" $
        parseCommitLine "warning: tohost and fromhost symbols not in ELF; can't communicate with target"
          @?= Nothing
    , testCase "non-commit line (empty) rejected" $
        parseCommitLine "" @?= Nothing
    , testCase "exception trap line rejected" $
        parseCommitLine "core   0: exception trap_store_access_fault, epc 0x80000024"
          @?= Nothing
    ]

-- * Running spike end-to-end

invocationTests :: TestTree
invocationTests =
  testGroup
    "runSpike on a 2-instruction ALU program"
    [ testCase "firmware retires both ADDIs with correct rd/value" $ do
        -- ADDI x1, x0, 42 ; ADDI x2, x0, 7
        -- We deliberately skip ECALL: spike doesn't emit a
        -- --log-commits line for the trapping instruction itself,
        -- and the subsequent trap handler silently re-traps at
        -- mtvec=0, tying up the driver's read loop until the
        -- wallclock timeout fires. A pure-ALU sequence gives a
        -- clean, fast verification that 'runSpike' ↔ 'parseCommitLine'
        -- wire up end-to-end.
        let program :: [BitVector 32]
            program =
              DE.fromRight
                (error "assemble failed")
                ( assemble $ do
                    addi x1 x0 42
                    addi x2 x0 7
                )
            w32 :: BitVector 32 -> Word32
            w32 b = fromIntegral (toInteger b)
            instrs = map w32 program
            -- 5 boot-ROM retires + our 2 firmware retires = 7
            -- total. Setting maxCommits to exactly the expected
            -- count lets runSpike terminate the moment the last
            -- commit arrives, rather than waiting for the
            -- wallclock timeout.
            opts = defaultSpikeOptions {spikeMaxCommits = 7}
            base = spikeBaseAddr opts
            spikeBaseAddr :: SpikeOptions -> Word32
            spikeBaseAddr SpikeOptions {spikeBaseAddr = a} = a
        commits <- runSpike opts instrs
        let fw = firmwareCommits base (length instrs) commits
        assertBool
          ( "expected 5 boot-ROM commits before our firmware, got "
              <> show (length commits - length fw)
          )
          (length commits - length fw == 5)
        case fw of
          [c0, c1] -> do
            assertEqual "first retire at baseAddr" base (scPc c0)
            assertEqual "first ADDI writes x1 ← 42" (Just (1, 42)) (scRegWrite c0)
            assertEqual "second retire at baseAddr+4" (base + 4) (scPc c1)
            assertEqual "second ADDI writes x2 ← 7" (Just (2, 7)) (scRegWrite c1)
          _ ->
            fail
              ( "expected exactly 2 firmware commits, got "
                  <> show (length fw)
                  <> ": "
                  <> show fw
              )
    ]

