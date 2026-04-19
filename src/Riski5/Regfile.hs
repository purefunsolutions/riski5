-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Riski5.Regfile
Description : Async-read RV32I integer register file (x0..x31).

The phase-1 core is pipelineless: one instruction retires per clock
with the single concession that the instruction memory fetch
absorbs a one-cycle BRAM latency (the @pc@ latched at cycle N−1
arrives decoded at cycle N). The register file can't add another
cycle of latency on top of that without turning the design into a
real two-stage pipeline, so this module implements the 32 × 32
integer register file as a **register-array with asynchronous
reads**:

* Storage: a @'Vec' 32 ('BitVector' 32)@ held in a single
  'Clash.Prelude.register', i.e. 1024 flip-flops total.
* Reads: combinational 32:1 selects on the current @rs1@ / @rs2@
  addresses — value available **in the same clock cycle** the
  address is presented.
* Writes: applied on the clock edge via the normal register-next
  function. @x0@ writes are dropped.

Cost on EP2C35: ~1024 flip-flops (each LE has one anyway) plus two
32:1 muxes on 32-bit data ≈ 250–350 LEs of mux logic. In exchange
we free up the two M4K blocks the earlier implementation used.

Revisit when we pipeline the core: a real 2- or 5-stage pipeline
can tolerate synchronous-read BRAMs for the regfile again, since
the regfile read naturally aligns with an ID or EX pipeline stage.
Until then, keeping reads async is the simplest way to honour
\"one instruction retires per clock\" without adding hazard logic.
-}
module Riski5.Regfile (
  regfile,
) where

import Clash.Prelude hiding (repeat, (!!))
import Clash.Prelude qualified as CP

{- | 32×32 register file with **combinational** reads.

@regfile rs1 rs2 wr@ returns @(rs1Data, rs2Data)@ — the values at
addresses @rs1@ and @rs2@ at the current clock cycle. @wr@ is
@Just (rd, wdata)@ for a write this cycle, @Nothing@ otherwise;
writes to @x0@ are dropped.
-}
regfile ::
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
regfile rs1 rs2 wr = (rs1Data, rs2Data)
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
