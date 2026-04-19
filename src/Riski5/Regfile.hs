-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE FlexibleContexts #-}

{- |
Module      : Riski5.Regfile
Description : RV32I integer register file (x0..x31) on M4K block RAM.

Two read ports and one write port, mapped to Cyclone II M4K blocks
via Clash's 'blockRam' primitive. One M4K block per read port (two
total): Quartus can infer a single true-dual-port RAM for this
pattern, but the explicit duplication is portable and costs nothing
on this part — we have 105 M4Ks on the device and the register file
is the cheapest possible use of two of them.

@x0@ is hardwired to zero, implemented as a mux on the read side
(address == 0 forces the output to 0) plus a write-enable gate
(address == 0 drops the write). This avoids depending on the
initial contents of the underlying BRAM, which makes the design
simulation-friendly.

Reads are one cycle delayed (standard synchronous-read BRAM
behaviour on this part). The Core module accounts for that by
presenting the read address during the decode stage so the result
is ready in the execute stage.
-}
module Riski5.Regfile (
  regfile,
) where

import Clash.Prelude hiding (repeat)
import Clash.Prelude qualified as CP

{- | 32x32 register file with synchronous-read ports.

@regfile rs1 rs2 wr@ returns @(rs1Data, rs2Data)@: the values
observed at the register read ports @rs1@ and @rs2@, one clock
cycle after their addresses were presented. The write port @wr@
is @Just (rd, wdata)@ when a write is in flight, @Nothing@ when
idle; writes to @x0@ are silently dropped.
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
  -- | @(rs1Data, rs2Data)@
  (Signal dom (BitVector 32), Signal dom (BitVector 32))
regfile rs1 rs2 wr =
  let writeGated = gateX0 <$> wr
      rs1Raw = blockRam zeroInit (unpackAddr <$> rs1) writeGated
      rs2Raw = blockRam zeroInit (unpackAddr <$> rs2) writeGated
      -- x0 reads as zero regardless of what's in the BRAM; we check
      -- against the *address* that was presented one cycle ago, so
      -- delay the address by one cycle to align with the data.
      rs1Addr = register 0 rs1
      rs2Addr = register 0 rs2
      zeroIfX0 a d = mux (a .==. pure 0) (pure 0) d
   in ( zeroIfX0 rs1Addr rs1Raw
      , zeroIfX0 rs2Addr rs2Raw
      )
 where
  zeroInit :: Vec 32 (BitVector 32)
  zeroInit = CP.repeat 0

  unpackAddr :: BitVector 5 -> Unsigned 5
  unpackAddr = unpack

  -- A write to x0 is a no-op architecturally; swap it for 'Nothing'
  -- so 'blockRam' never perturbs address 0 either.
  gateX0 :: Maybe (BitVector 5, BitVector 32) -> Maybe (Unsigned 5, BitVector 32)
  gateX0 Nothing = Nothing
  gateX0 (Just (a, d))
    | a == 0 = Nothing
    | otherwise = Just (unpack a, d)
