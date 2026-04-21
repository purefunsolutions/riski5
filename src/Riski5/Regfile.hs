-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Riski5.Regfile
Description : RV32I integer register file (x0..x31), two backings.

The register file ships as two interchangeable implementations with
identical black-box semantics (x0 hard-wired to zero, writes drop
to x0) but different read latencies and FPGA-mapping costs. The
choice is a pipeline-shape decision: the async (LE) version fits
any core that consumes rs1 / rs2 combinationally within the same
stage they were decoded; the sync (BRAM) version adds one cycle
of read latency, which fits any pipeline with a dedicated decode
stage that issues the read one cycle before execute consumes it.

== 'regfileAsync' — generic, combinational reads

Storage: a @'Vec' 32 ('BitVector' 32)@ in a single
'Clash.Prelude.register' — 1024 flip-flops.
Reads: combinational 32:1 selects on the current @rs1@ / @rs2@
addresses — value available __in the same clock cycle__ the address
is presented.
Writes: applied on the clock edge; @x0@ writes dropped.

Cost on EP2C35: ~1024 FFs (each LE has one anyway) + two 32:1 read
muxes on 32-bit data ≈ 250–350 LEs of mux logic. Uses __zero M4K
blocks__. Portable to any FPGA or ASIC — it's just registers +
combinational mux trees, no vendor primitives.

The pre-pipeline (2-stage F+X) riski5 core uses this one because
the X stage consumes rs1 / rs2 combinationally: the cycle that
decodes the instruction is also the cycle that runs the ALU.

== 'regfileSync' — Cyclone II M4K-friendly, 1-cycle read latency

Storage: two parallel 'Clash.Prelude.blockRamPow2' instances (one
per read port), writes replicated to both. Each instance is a
32 × 32-bit memory — Clash / Quartus maps each to one M4K on
Cyclone II (M4K natively supports 128 × 36, so 32 × 32 fits
comfortably). Two read ports = two M4Ks.
Reads: address presented at cycle N is latched on edge N→N+1;
output reflecting @memory[addr_N]@ appears at cycle N+1.
Writes: applied on the clock edge; @x0@ writes dropped at the
input filter so slot 0 stays zero forever (and reads of x0
naturally return zero from a cleared slot).

Cost on EP2C35: __two M4K blocks__ (≈ 2 % of the 105-block pool)
plus a handful of LUTs for the x0-write filter. The ~300-LE mux
tree of the async variant goes away, freeing area for everything
else. Same module works on any FPGA or ASIC with true-dual-port
SRAM macros — Xilinx BlockRAM, Lattice EBR, Microsemi LSRAM, ASIC
single-port SRAM macros of the right aspect ratio. Clash's
'blockRamPow2' is a vendor-neutral abstraction; the Cyclone II
M4K mapping happens downstream in Quartus's RAM-inference.

Fits naturally into a pipelined core with a dedicated D (decode)
stage: D issues rs1 / rs2 addresses at cycle N, the ID/EX pipeline
register captures the control signals at edge N→N+1, and X at
cycle N+1 consumes the blockRam's output directly. Same-cycle
WB→D forwarding is the pipeline's job, not this module's — we
just expose the raw 1-cycle-delayed read.

See 'Riski5.Core' for which backing the shipping core selects.

== Why both? Portability vs FPGA efficiency

A fully portable design would just use 'regfileAsync' — it relies
on nothing vendor-specific and synthesises cleanly on any target.
An FPGA-optimal design on Cyclone II wants 'regfileSync' to trade
~300 LEs of mux for ~0 LEs + 2 M4K (the M4K pool is abundant on
this part). Keeping both, with matching black-box semantics
modulo the latency, is the cheapest way to let a single core
source-tree swap between targets.
-}
module Riski5.Regfile (
  -- * Backing choice
  RegfileBacking (..),

  -- * Default (backward-compat): async
  regfile,

  -- * Explicit variants
  regfileAsync,
  regfileSync,
) where

import Clash.Prelude hiding (repeat, (!!))
import Clash.Prelude qualified as CP

{- | Which regfile implementation to instantiate. Value-level today;
promoted to a type-level @'DataKinds'@ tag once 'Riski5.Core.Config'
gains an @ccRegfile@ field that Clash can specialise on.

The two variants expose the same interface shape
(@rs1 → rs2 → wr → (rs1Data, rs2Data)@) but differ in read
latency: 'RfAsync' returns data the same cycle the address is
presented, 'RfSync' returns data one cycle later. Callers that
swap between them almost always need to also change the pipeline
stage at which reads are issued.
-}
data RegfileBacking
  = -- | Register-array with combinational reads. Portable, no
    -- vendor primitives, ~1024 FFs + 2×(32:1-mux). The phase-1
    -- pipelineless / F+X core picks this.
    RfAsync
  | -- | Synchronous-read BRAM (Cyclone II M4K on the DE2, Xilinx
    -- BlockRAM elsewhere). 1-cycle read latency, ~0 LEs, 2 M4K.
    -- The 5-stage F|D|X|M|W core picks this once its D stage
    -- issues reads a cycle ahead of X.
    RfSync
  deriving stock (Eq, Show)

{- | Default regfile — backwards-compat alias for 'regfileAsync'.

Existing call sites (@Riski5.Core@'s 2-stage kernel,
@test/RegfileSpec.hs@) continue to use this without change; a
pipelined core explicitly names 'regfileAsync' or 'regfileSync'
so the latency contract is visible at the import.
-}
regfile ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  Signal dom (BitVector 5) ->
  Signal dom (BitVector 5) ->
  Signal dom (Maybe (BitVector 5, BitVector 32)) ->
  (Signal dom (BitVector 32), Signal dom (BitVector 32))
regfile = regfileAsync

{- | 32×32 register file with combinational (same-cycle) reads.

@regfileAsync rs1 rs2 wr@ returns @(rs1Data, rs2Data)@ — the values
at addresses @rs1@ and @rs2@ at the current clock cycle. @wr@ is
@Just (rd, wdata)@ for a write this cycle, @Nothing@ otherwise;
writes to @x0@ are dropped.

Implementation: single 'register'-held 'Vec' 32 of 'BitVector' 32.
Zero FPGA vendor dependency — synthesises the same on Cyclone II,
Spartan-7, iCE40, ASIC. The cost on Cyclone II EP2C35 is ~1024
FFs (effectively free because each LE has one already) plus two
combinational 32:1 multiplexer trees (~250–350 LEs of logic). No
M4K consumed.
-}
regfileAsync ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  -- | rs1 address
  Signal dom (BitVector 5) ->
  -- | rs2 address
  Signal dom (BitVector 5) ->
  -- | write port: @Just (rd, value)@ or @Nothing@
  Signal dom (Maybe (BitVector 5, BitVector 32)) ->
  -- | @(rs1Data, rs2Data)@, available the same cycle the address is presented
  (Signal dom (BitVector 32), Signal dom (BitVector 32))
regfileAsync rs1 rs2 wr = (rs1Data, rs2Data)
 where
  regs :: Signal dom (Vec 32 (BitVector 32))
  regs = register (CP.repeat 0) (applyWrite <$> regs <*> wr)

  applyWrite :: Vec 32 (BitVector 32) -> Maybe (BitVector 5, BitVector 32) -> Vec 32 (BitVector 32)
  applyWrite rs Nothing = rs
  applyWrite rs (Just (a, v))
    | a == 0 = rs
    | otherwise = replace (unpack a :: Unsigned 5) v rs

  rs1Data = readRf <$> regs <*> rs1
  rs2Data = readRf <$> regs <*> rs2

  readRf :: Vec 32 (BitVector 32) -> BitVector 5 -> BitVector 32
  readRf rs a
    | a == 0 = 0
    | otherwise = rs CP.!! (unpack a :: Unsigned 5)

{- | 32×32 register file with __synchronous__ reads (1-cycle latency).

@regfileSync rs1 rs2 wr@ presents the read addresses at cycle N;
the corresponding data appears on the output at cycle N+1. @wr@
semantics are identical to 'regfileAsync' — writes to @x0@ are
dropped, non-x0 writes commit on the clock edge.

Implementation: two parallel 'blockRamPow2' instances (one per
read port), writes replicated to both so they stay in lock-step.
On Cyclone II each maps to one M4K block (the natural @32 × 32@
shape fits comfortably into M4K's 4608-bit capacity); on Xilinx
parts they map to BlockRAM; on ASIC they map to vendor SRAM macros
of the appropriate aspect ratio. Zero LEs of read-mux logic — the
BRAMs own the read path.

__Semantics of same-cycle read-after-write.__ Clash's
'blockRamPow2' is read-first: if cycle N both writes rd=a and
reads rs=a, the output at cycle N+1 reflects memory __before__
the write. Pipelined cores above this module own the forwarding
logic that covers this; this module just exposes the raw BRAM
read.

Use this when the pipeline has a dedicated decode stage that can
issue reads a cycle before execute consumes them (classic 5-stage
F|D|X|M|W or deeper). The 2-stage F+X core can't — its X stage
reads rs1 / rs2 combinationally in the same cycle it runs the ALU.
-}
regfileSync ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  -- | rs1 address (latched on the clock edge)
  Signal dom (BitVector 5) ->
  -- | rs2 address (latched on the clock edge)
  Signal dom (BitVector 5) ->
  -- | write port: @Just (rd, value)@ or @Nothing@
  Signal dom (Maybe (BitVector 5, BitVector 32)) ->
  -- | @(rs1Data, rs2Data)@ — values from addresses presented on the __previous__ cycle
  (Signal dom (BitVector 32), Signal dom (BitVector 32))
regfileSync rs1 rs2 wr = (rs1Data, rs2Data)
 where
  -- Initial memory — all zeros, so reads of any register before
  -- the first write return 0 (including x0 permanently).
  initMem :: Vec 32 (BitVector 32)
  initMem = CP.repeat 0

  -- Drop x0 writes at the input filter so slot 0 stays 0 forever.
  -- Reads of x0 then naturally return 0 from a never-written slot.
  -- Converts the ISA-level 'BitVector 5' address to the
  -- 'Unsigned 5' 'blockRamPow2' wants.
  wrFiltered :: Signal dom (Maybe (Unsigned 5, BitVector 32))
  wrFiltered = fmap filterWrite wr
   where
    filterWrite :: Maybe (BitVector 5, BitVector 32) -> Maybe (Unsigned 5, BitVector 32)
    filterWrite Nothing = Nothing
    filterWrite (Just (a, _)) | a == 0 = Nothing
    filterWrite (Just (a, v)) = Just (unpack a, v)

  rs1Idx, rs2Idx :: Signal dom (Unsigned 5)
  rs1Idx = fmap unpack rs1
  rs2Idx = fmap unpack rs2

  -- Two parallel blockRams with identical write streams — one per
  -- read port. Quartus maps each to a separate M4K block on
  -- Cyclone II. Synthesis-level vendor inference, not a hard
  -- dependency on any primitive.
  rs1Data = blockRamPow2 initMem rs1Idx wrFiltered
  rs2Data = blockRamPow2 initMem rs2Idx wrFiltered
