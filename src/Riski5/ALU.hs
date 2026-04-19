-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause

{- |
Module      : Riski5.ALU
Description : Combinational RV32I arithmetic-logic unit.

Pure combinational — no clock, no reset, no state. The core's
execute stage feeds two 32-bit operands and an 'AluOp' code, gets
a 32-bit result back. The same 'alu' function is differentially
tested against the Haskell-side reference executor in
@test/AluSpec.hs@, which makes the whole operation spectrum a
property test rather than a hand-authored golden table.

Operations are written in an order that encourages Quartus to
infer Cyclone II's dedicated carry chains (for @+@ / @-@), and
the barrel shifter is a 5-stage log shift (1/2/4/8/16) that
composes cleanly out of 4-input LUTs. Writing these as plain
Haskell + Clash arithmetic is enough — the synthesizer does the
rest.
-}
module Riski5.ALU (
  AluOp (..),
  alu,
  BranchOp (..),
  branchTaken,
) where

import Clash.Prelude

{- |
Operations the ALU can perform in a single cycle. Covers every
RV32I arithmetic, logical, shift, and comparison operation; the
branch comparisons live separately in 'BranchOp' because the
branch unit produces a single-bit \"taken\" signal rather than a
full 32-bit result.
-}
data AluOp
  = AluAdd
  | AluSub
  | -- | shift left logical
    AluSll
  | -- | set less than (signed)
    AluSlt
  | -- | set less than (unsigned)
    AluSltu
  | AluXor
  | -- | shift right logical
    AluSrl
  | -- | shift right arithmetic
    AluSra
  | AluOr
  | AluAnd
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- |
One-cycle combinational ALU. Inputs are two 32-bit operands (treated
as signed, unsigned, or bit patterns depending on the op). The low
five bits of @b@ are taken as the shift amount for shift operations,
matching the RV32I encoding of SLL / SRL / SRA (both register-
register and the shift-immediate variant, since the latter already
has a 5-bit shamt field).
-}
alu :: AluOp -> BitVector 32 -> BitVector 32 -> BitVector 32
alu op a b = case op of
  AluAdd -> pack (signed a + signed b)
  AluSub -> pack (signed a - signed b)
  AluSll -> pack (unsigned a `shiftL` shamtInt b)
  AluSlt -> if signed a < signed b then 1 else 0
  AluSltu -> if unsigned a < unsigned b then 1 else 0
  AluXor -> a `xor` b
  AluSrl -> pack (unsigned a `shiftR` shamtInt b)
  AluSra -> pack (signed a `shiftR` shamtInt b)
  AluOr -> a .|. b
  AluAnd -> a .&. b
 where
  signed :: BitVector 32 -> Signed 32
  signed = unpack

  unsigned :: BitVector 32 -> Unsigned 32
  unsigned = unpack

  -- Extract the low 5 bits of @b@ as an Int suitable for the Clash
  -- Bits instance's 'shiftL' / 'shiftR'.
  shamtInt :: BitVector 32 -> Int
  shamtInt v =
    let low5 :: BitVector 5
        low5 = resize v
     in fromIntegral (unpack low5 :: Unsigned 5)

-- * Branch comparator ------------------------------------------------

-- | Six branch comparisons RV32I's B-type instructions request.
data BranchOp
  = BrEq
  | BrNe
  | -- | signed less-than
    BrLt
  | -- | signed greater-or-equal
    BrGe
  | -- | unsigned less-than
    BrLtu
  | -- | unsigned greater-or-equal
    BrGeu
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

-- | True iff the branch with the given comparison op and operands is taken.
branchTaken :: BranchOp -> BitVector 32 -> BitVector 32 -> Bool
branchTaken op a b = case op of
  BrEq -> a == b
  BrNe -> a /= b
  BrLt -> (unpack a :: Signed 32) < unpack b
  BrGe -> (unpack a :: Signed 32) >= unpack b
  BrLtu -> (unpack a :: Unsigned 32) < unpack b
  BrGeu -> (unpack a :: Unsigned 32) >= unpack b
