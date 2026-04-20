-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}

{- |
Module      : SpikeDiffSpec
Description : Spike ↔ Riski5.Reference differential, a la CoreSimSpec.

Closes the final side of the triple-diff triangle. 'CoreSimSpec'
already checks @Riski5.Core ≡ Riski5.Reference@; this module
checks @Riski5.Reference ≡ Spike@ on the same style of programs.
If both hold, the transitive property @Riski5.Core ≡ Spike@ — the
thing we actually care about — follows for the catalogue.

== Why compare final reg files rather than per-retire traces

Spike's @--log-commits@ trace lives in a different PC space from
our interpreter (Spike boots via its reset ROM at @0x1000@ then
lands at @0x8000_0000@, whereas 'Riski5.Reference' starts at
@0x0@). A per-retire diff would need us to either rebase one side
or strip PC-sensitive fields. Final-register-file comparison
side-steps that: whichever PCs the two sides traversed, the
resulting GPR snapshot is identical iff they executed the same
byte stream with the same architectural semantics.

Memory writes aren't covered here. Spike's commit log reports
/addresses/ but not /values/ for stores, so a full memory diff
needs a different channel (e.g. Spike @-l@ with post-run
@mem@-dump). Phase-1 catalogue programs are pure-ALU by
construction, so no stores to diff.
-}
module SpikeDiffSpec (tests) where

import Clash.Prelude (BitVector, KnownNat, Unsigned, unpack)
import Data.Either qualified as DE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Word (Word32, Word8)
import Riski5.Asm (
  Asm,
  addi,
  assemble,
  beq,
  bne,
  labelUnplaced,
  li,
  nop,
  placeAt,
 )
import Riski5.Asm qualified as Asm
import Riski5.ISA
import Riski5.Reference qualified as Ref
import Riski5.SpikeDriver (
  SpikeCommit (..),
  SpikeOptions (..),
  defaultSpikeOptions,
  firmwareCommits,
  runSpike,
 )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Riski5.Reference ≡ Spike (final reg-file diff)"
    (map mkCase catalog)
 where
  mkCase (name, prog, nSteps) =
    testCase name (diffReferenceVsSpike prog nSteps)

-- * Catalog
--
-- Mirrors CoreSimSpec's programs but limited to pure-ALU sequences:
-- Spike's commit log has no @mem@-write /value/ field, so store-
-- exercising programs can't be diffed via reg-file-only compare.

catalog :: [(String, Asm (), Int)]
catalog =
  [ ("ADDI sequence — single register", progAddi, 3)
  , ("LUI + ADDI — 32-bit constant", progLuiAddi, 2)
  , ("ADD / SUB — register arithmetic", progAddSub, 4)
  , ("XOR / OR / AND — bitwise ops", progBitwise, 6)
  , ("SLL / SRL / SRA — shifts", progShifts, 6)
  , ("BEQ (taken) skips a write", progBeqTaken, 2)
  , ("BNE (not taken) falls through", progBneNotTaken, 3)
  , ("SLTI — signed compare-set", progSlti, 4)
  , ("Backward branch loop counter", progLoop, 7)
  ]

progAddi :: Asm ()
progAddi = do
  addi x1 x0 10
  addi x2 x0 20
  addi x3 x0 30

progLuiAddi :: Asm ()
progLuiAddi = li x10 0x1234_5678

progAddSub :: Asm ()
progAddSub = do
  addi x1 x0 100
  addi x2 x0 25
  Asm.add x3 x1 x2
  Asm.sub x4 x1 x2

progBitwise :: Asm ()
progBitwise = do
  addi x1 x0 0x55
  addi x2 x0 0x33
  Asm.xori x3 x1 0x33
  Asm.ori x4 x1 0x0F
  Asm.andi x5 x1 0x0F
  Asm.sltiu x6 x1 0

progShifts :: Asm ()
progShifts = do
  addi x1 x0 0x7
  Asm.slli x2 x1 3
  addi x3 x0 (-4)
  Asm.srai x4 x3 1
  Asm.srli x5 x3 1
  nop

progBeqTaken :: Asm ()
progBeqTaken = do
  skipL <- labelUnplaced
  beq x0 x0 skipL
  addi x1 x0 99
  placeAt skipL

progBneNotTaken :: Asm ()
progBneNotTaken = do
  end <- labelUnplaced
  addi x1 x0 5
  bne x1 x1 end
  addi x2 x0 7
  placeAt end

progSlti :: Asm ()
progSlti = do
  addi x1 x0 (-5)
  Asm.slti x2 x1 0
  addi x3 x0 5
  Asm.slti x4 x3 0

progLoop :: Asm ()
progLoop = do
  addi x1 x0 3
  loopL <- Asm.label
  addi x1 x1 (-1)
  bne x1 x0 loopL

-- * The diff

diffReferenceVsSpike :: Asm () -> Int -> Assertion
diffReferenceVsSpike prog nSteps = do
  let ws = DE.fromRight (error "assemble failed") (assemble prog)
      instrs = map bvToWord32 ws
  spikeRegs <- runOnSpike instrs nSteps
  let refRegs = runOnReference ws nSteps
      nonZero = Map.filter (/= 0) -- zero-initialised regs don't diff
  assertEqual
    "final register file (non-zero GPRs only)"
    (nonZero refRegs)
    (nonZero spikeRegs)

-- * Spike runner

{- | Run the program through Spike, collect commits, reduce the
register-write stream to a final @Map reg value@.

Spike's boot ROM executes 5 instructions before jumping to our
firmware; 'firmwareCommits' drops those. Then we need the first
@nSteps@ firmware commits so we can compare against the Reference
run, which was told exactly @nSteps@ steps.

Spike's commit budget (@spikeMaxCommits@) is set to
@5 boot-rom + nSteps@ so the driver terminates immediately after
the last relevant retire — no wallclock wait.
-}
runOnSpike :: [Word32] -> Int -> IO (Map Word32 Word32)
runOnSpike instrs nSteps = do
  let opts =
        defaultSpikeOptions
          { spikeMaxCommits = bootRomRetires + nSteps
          , -- Cut the catch-all deadline down from the default
            -- 3 s to 500 ms. Small catalog programs retire in
            -- milliseconds; the deadline only matters for
            -- programs whose final instruction doesn't emit a
            -- commit (e.g. a taken branch past the end of our
            -- linked section), where Spike then spins quietly
            -- rather than tripping maxCommits.
            spikeTimeoutMillis = 500
          }
      bootRomRetires = 5
      base = bvBase opts
  commits <- runSpike opts instrs
  let fw = take nSteps (firmwareCommits base (length instrs) commits)
  pure (foldl' applyCommit Map.empty fw)
 where
  bvBase :: SpikeOptions -> Word32
  bvBase SpikeOptions {spikeBaseAddr = a} = a

  applyCommit :: Map Word32 Word32 -> SpikeCommit -> Map Word32 Word32
  applyCommit m SpikeCommit {scRegWrite = Just (rd, v)}
    | rd /= 0 =
        Map.insert (bvToWord32 (resizeReg rd)) v m
  applyCommit m _ = m

  resizeReg :: BitVector 5 -> BitVector 32
  resizeReg b = fromIntegral (fromIntegral (unpack b :: Unsigned 5) :: Word32)

-- * Reference runner

{- | Execute @nSteps@ on the Reference; return the final GPR file
keyed by a plain 'Word32' so the map matches 'runOnSpike''s shape.
-}
runOnReference :: [BitVector 32] -> Int -> Map Word32 Word32
runOnReference ws nSteps =
  let initState = loadProgram ws
      (finalState, _trap) = Ref.run nSteps initState
   in Map.mapKeys bvToWord32 (Ref.regs finalState)

{- | Lay the program bytes out in Reference memory starting at
address 0. Matches CoreSimSpec's loader so tests written once
translate across.
-}
loadProgram :: [BitVector 32] -> Ref.MachineState
loadProgram ws =
  foldl' writeWord Ref.initial (zip [0, 4 ..] ws)
 where
  writeWord s (addr, w) =
    let w32 :: Word32
        w32 = bvToWord32 w
     in s
          { Ref.memory =
              Map.insert addr (byte (0 :: Int) w32) $
                Map.insert (addr + 1) (byte 1 w32) $
                  Map.insert (addr + 2) (byte 2 w32) $
                    Map.insert (addr + 3) (byte 3 w32) (Ref.memory s)
          }
  byte :: Int -> Word32 -> Word8
  byte k w = fromIntegral ((w `div` (256 ^ k)) `mod` 256)

-- * Conversion helpers

bvToWord32 :: (KnownNat n) => BitVector n -> Word32
bvToWord32 b = fromIntegral (toInteger b)
