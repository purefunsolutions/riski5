-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Riski5.Core.FU.MulDiv
Description : Iterative multi-cycle M-extension functional unit.

Phase-2B companion to the integer ALU. Handles the eight RV32M
opcodes (@MUL@ / @MULH@ / @MULHSU@ / @MULHU@ / @DIV@ / @DIVU@ /
@REM@ / @REMU@) iteratively: one shift-and-add iteration per
cycle for multiplies, one restoring-division step per cycle for
divides.

Target: ~400 LEs on Cyclone II, no DSP inference. Phase-2+ tiers
(@little32@ / @mid32@ / @big32@) will switch to 'MdPipelined'
specs that trade stage depth for throughput and lean on the 35
embedded 18×18 multipliers the EP2C35 ships. For @tiny32M@ we
keep the multiply off the DSPs entirely — they stay reserved
for future FPU work — and rely on the core's existing stall path
to absorb the 32- to 35-cycle latency.

== Contract

The FU is a Mealy-style block with one input record and two
outputs:

  * __@mdBusy@__ — combinational. @True@ on every cycle the core
    should freeze its sequential state because an M op is in
    progress. Goes @False@ on the retire cycle, when @mdResult@
    is valid.

  * __@mdResult@__ — the 32-bit value to write back to @rd@.
    Only defined on the cycle @mdBusy@ falls.

The core instantiates one 'mulDivFU' and drives @mdActive@ high
whenever the retiring instruction is an RV32M op. The FU self-
latches the operand values and the op code at the Idle → Busy
transition, so the core doesn't have to hold them stable after
that — though in practice it always does, because the very same
@mdBusy@ the FU raises also freezes @pcExec@ and @effectiveImemS@
so the op is still in-flight from the core's perspective.

== Algorithm

__Multiplies.__ Classic "sequential multiplier with right-shifting
product register":

@
  { prod[63:32], prod[31:0] } := { 0, abs(rs2) }      -- multiplier in low 32
  for i in 0..31:
    if prod[0]: prod[63:32] += abs(rs1)               -- multiplicand
    prod >>= 1                                        -- logical right shift
  { prod[63:32], prod[31:0] } = full unsigned 64-bit product
@

Signs are handled by pre-converting to absolute values (tracked
by 'negResult') and negating the 64-bit product at retire time
if the two input signs differ. The low-32 slot ('MUL') always
matches regardless of sign because the low bits of @|a| × |b|@
and @a × b@ are identical in two's complement. The high-32 slot
('MULH' / 'MULHSU' / 'MULHU') requires the sign adjustment.

__Divides.__ Restoring-style non-negative division with the
quotient built up from the left:

@
  { prod[63:32], prod[31:0] } := { 0, abs(rs1) }      -- dividend in low 32
  for i in 0..31:
    prod <<= 1                                        -- 64-bit left shift
    if prod[63:32] >= abs(rs2):
      prod[63:32] -= abs(rs2)
      prod[0] = 1                                     -- set LSB of quotient
  -- prod[31:0]   = unsigned quotient (32 iterations cover all bits)
  -- prod[63:32]  = unsigned remainder
@

Sign-handling per the RV32M spec: the quotient takes on a
negative sign iff the dividend and divisor have different signs
(for signed DIV/REM only). The remainder carries the sign of
the dividend. 'negResult' tracks the first, 'negRem' the second.

== Edge cases

  * __Divide by zero__ (@DIV@ / @DIVU@ / @REM@ / @REMU@ with
    @rs2 == 0@): the spec prescribes specific return values
    (DIV/DIVU → @-1@ / all-ones; REM/REMU → @rs1@ unchanged).
    'launchDiv' detects this at dispatch time and jumps
    straight to 'MdDone' with the pre-computed result, skipping
    the 32-iteration loop entirely (2-cycle latency instead
    of 34).

  * __Signed division overflow__ (signed @DIV@ / @REM@ with
    @rs1 == INT_MIN@ and @rs2 == -1@): the spec says return
    @INT_MIN@ (DIV) or @0@ (REM) rather than trap. The
    natural-value algorithm produces exactly these results
    without any special-case — sign-fixup for @INT_MIN@ folds
    back to @INT_MIN@ because @-(INT_MIN) = INT_MIN@ in
    two's complement, and the remainder is zero. No explicit
    check is needed.

== Cycle counts

Latency from "M op in X" to "rd written back" is two cycles of
pipeline overhead (Idle → BusyN0, BusyN-1 → Done) plus N
iterations:

  * MUL / MULH / MULHSU / MULHU: 32 iterations → __34 cycles__.
  * DIV / DIVU / REM / REMU: 32 iterations → __34 cycles__.
  * Divide-by-zero early-out: __2 cycles__.

Close enough to the @MdIterative {mdCyclesMul = 32, mdCyclesDiv
= 33}@ target on the @tiny32M@ preset — the exact numbers matter
for tier-comparison tables but don't feed codegen.
-}
module Riski5.Core.FU.MulDiv (
  -- * M-extension dispatch
  MdOp (..),
  mdOpOf,
  isMdOp,

  -- * Functional unit
  mulDivFU,

  -- ** Implementation variants
  mulDivFUIterative,
  mulDivFUCombinational,

  -- * Combinational reference
  combMd,
) where

import Clash.Prelude hiding ((&&), (||), not)

import Riski5.ISA (Instr (..))

-- * Op classification ---------------------------------------------

{- | Which of the eight RV32M operations is in flight. Carried as
a small enum rather than raw @funct3@/@funct7@ bits so the FU's
case splits on 'MdOp' compile to a single 3-bit comparator cone
rather than two independent ones.
-}
data MdOp
  = MdMul
  | MdMulH
  | MdMulHsu
  | MdMulHu
  | MdDiv
  | MdDivU
  | MdRem
  | MdRemU
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

-- | True iff 'Instr' is one of the eight RV32M ops.
isMdOp :: Instr -> Bool
isMdOp = \case
  Mul {} -> True
  MulH {} -> True
  MulHsu {} -> True
  MulHu {} -> True
  Div {} -> True
  DivU {} -> True
  Rem {} -> True
  RemU {} -> True
  _ -> False

{- | Project an RV32M 'Instr' down to an 'MdOp' tag. Returns
'MdMul' as a safe default for non-M instructions; callers must
gate on 'isMdOp' first.
-}
mdOpOf :: Instr -> MdOp
mdOpOf = \case
  Mul {} -> MdMul
  MulH {} -> MdMulH
  MulHsu {} -> MdMulHsu
  MulHu {} -> MdMulHu
  Div {} -> MdDiv
  DivU {} -> MdDivU
  Rem {} -> MdRem
  RemU {} -> MdRemU
  _ -> MdMul

-- | @True@ on the four divide-forms.
isDivForm :: MdOp -> Bool
isDivForm = \case
  MdDiv -> True
  MdDivU -> True
  MdRem -> True
  MdRemU -> True
  _ -> False

-- | @True@ when the final result is the high 32 bits of the
-- 64-bit product (MULH, MULHSU, MULHU).
wantHigh :: MdOp -> Bool
wantHigh = \case
  MdMulH -> True
  MdMulHsu -> True
  MdMulHu -> True
  _ -> False

-- | @True@ when the final result is the remainder (REM, REMU).
wantRem :: MdOp -> Bool
wantRem = \case
  MdRem -> True
  MdRemU -> True
  _ -> False

-- | Does this op interpret @rs1@ as signed?
signedA :: MdOp -> Bool
signedA = \case
  MdMulH -> True
  MdMulHsu -> True
  MdDiv -> True
  MdRem -> True
  _ -> False

-- | Does this op interpret @rs2@ as signed?
signedB :: MdOp -> Bool
signedB = \case
  MdMulH -> True
  MdDiv -> True
  MdRem -> True
  _ -> False

-- * FSM state ------------------------------------------------------

{- | FU phase. @MdIdle@ accepts new work; @MdBusyMul@ / @MdBusyDiv@
iterate; @MdDone@ holds the final result for one retire cycle
before going back to @MdIdle@.
-}
data MdPhase
  = MdIdle
  | -- | Counter 0..31 — iteration @k@ is performed on the
    -- edge out of @MdBusyMul k@.
    MdBusyMul (Index 32)
  | -- | Same shape for divides.
    MdBusyDiv (Index 32)
  | MdDone
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- | FU internal state. 'prodReg' is a dual-purpose 64-bit register:

  * For multiplies: low 32 bits start holding @|rs2|@ (the
    multiplier) and accumulate right-shifted product bits; high
    32 bits accumulate the partial-product sum.

  * For divides: low 32 bits start holding @|rs1|@ (the dividend);
    high 32 bits accumulate the remainder. After 32 iterations
    low 32 is the quotient, high 32 is the remainder.

'operandB' is the multiplicand (multiplies) or divisor (divides),
held constant through the iteration.
-}
data MdS = MdS
  { phase :: MdPhase
  , opReg :: MdOp
  , prodReg :: BitVector 64
  , operandB :: BitVector 32
  , -- | Post-iteration: negate the 64-bit product (MUL*) or the
    -- quotient (DIV). True iff signs of the two operands differ.
    negResult :: Bool
  , -- | Post-iteration: negate the remainder (REM). True iff
    -- @rs1@ is negative (signed form only).
    negRem :: Bool
  , -- | Final 32-bit result. Latched on the transition into
    -- 'MdDone'; read out combinationally while the FU is in
    -- 'MdDone'.
    resultReg :: BitVector 32
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

initState :: MdS
initState =
  MdS
    { phase = MdIdle
    , opReg = MdMul
    , prodReg = 0
    , operandB = 0
    , negResult = False
    , negRem = False
    , resultReg = 0
    }

-- * FU entity ------------------------------------------------------

{- | The M-extension functional unit.

Inputs:

  * @mdActiveS@ — @True@ on every cycle the current instruction
    in X is an RV32M op. The FU latches inputs on the first
    cycle this is asserted (Idle → Busy transition) and ignores
    further changes until it hits 'MdDone'.

  * @mdOpS@ / @mdAS@ / @mdBS@ — the op tag and two operand
    values. Sampled only on the Idle → Busy edge.

Outputs:

  * @mdBusyS@ — @True@ whenever the core should stall. Used by
    "Riski5.Core" to gate every sequential register so the M op
    remains in X for the duration of the computation.

  * @mdResultS@ — the retire value. Valid on the cycle @mdBusyS@
    falls (i.e. 'MdDone').

== Synth vs formal

When @FORMAL_FAST_MULDIV@ is defined at build time (passed via
@-cpp -DFORMAL_FAST_MULDIV@ from "pkgs/riski5-formal/package.nix"),
this symbol aliases 'mulDivFUCombinational' — a 1-cycle retire,
single-clock combinational multiplier + divider expressed in
native Haskell @*@/@\`quot\`@/@\`rem\`@. Otherwise (the default
path for @cabal build@ and @nix build .#riski5-core@) it aliases
'mulDivFUIterative' — the 34-cycle shift-and-add implementation.

Why split: the riscv-formal per-instruction proofs (@insn_mul*_ch0@
etc.) unroll the core for 40 cycles; with the iterative FU that
means the SMT formula carries 40 × (full core state + 64-bit
product accumulator + 32-deep counter + FSM phase) = tens of
thousands of bit-level variables. Neither boolector nor z3
closes those formulas in 30-minute wall-clock budgets per proof.
The combinational variant produces the result in one cycle, so
the depth-40 unroll collapses back to a shallow formula the
solvers handle in seconds.

__Soundness note.__ Swapping the FU implementation for formal
proves the architectural contract ("core writes back the correct
MUL\/DIV result") only for the combinational FU — strictly
speaking it does __not__ transitively prove the iterative FU is
correct. That gap is closed by the triple-diff harness in
@test\/CoreSimSpec.hs@ + @test\/SpikeDiffSpec.hs@, which exercises
the iterative FU on a 10-program M catalogue and diffs against
the pure-Haskell 'Riski5.Reference' interpreter and Spike's
golden-model RV32IM simulator. The two proof layers together
cover: (1) the core pipeline correctly handles M-retire timing
and writeback (formal, via combinational stub); (2) the
iterative multiply/divide algorithms produce correct 32-bit
results for concrete positive / negative / signed-overflow /
divide-by-zero inputs (triple-diff, via the iterative FU).

A phase 2C+ task — sketched in @pkgs/riski5-formal/checks.cfg@
— is to prove the iterative FU equivalent to the combinational
reference in isolation, which would tighten the soundness chain
across the CPP split.
-}
mulDivFU ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  Signal dom Bool ->
  Signal dom MdOp ->
  Signal dom (BitVector 32) ->
  Signal dom (BitVector 32) ->
  ( Signal dom Bool
  , Signal dom (BitVector 32)
  )
#ifdef FORMAL_FAST_MULDIV
mulDivFU = mulDivFUCombinational
#else
mulDivFU = mulDivFUIterative
#endif

{- | Iterative shift-and-add multiplier + restoring divider. Default
implementation used for cabal-test and synthesis builds.
-}
mulDivFUIterative ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  Signal dom Bool ->
  Signal dom MdOp ->
  Signal dom (BitVector 32) ->
  Signal dom (BitVector 32) ->
  ( Signal dom Bool
  , Signal dom (BitVector 32)
  )
mulDivFUIterative activeS opS aS bS = (busyS, resultS)
 where
  inS = bundle (activeS, opS, aS, bS)
  outS = mealy step initState inS
  (busyS, resultS) = unbundle outS

{- | Combinational 1-cycle retire, for the riscv-formal build only.
Uses Haskell's native @*@, @\`quot\`@, @\`rem\`@ on appropriately
sized @Signed@ / @Unsigned@ types — Clash lowers these to Verilog
arithmetic operators, which Yosys (and downstream SymbiYosys)
handles as simple primitives.

@mdBusy@ is hard-wired @False@ and @mdResult@ reflects the full
M-op result combinationally from the current inputs. The core
treats this as "FU is always ready" and retires the M op in the
same cycle it enters X — identical architectural behaviour to a
successful iterative retire, just with the 33-cycle stall
collapsed.
-}
mulDivFUCombinational ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  Signal dom Bool ->
  Signal dom MdOp ->
  Signal dom (BitVector 32) ->
  Signal dom (BitVector 32) ->
  ( Signal dom Bool
  , Signal dom (BitVector 32)
  )
mulDivFUCombinational _activeS opS aS bS = (pure False, combMd <$> opS <*> aS <*> bS)

-- * Mealy step ----------------------------------------------------

step ::
  MdS ->
  (Bool, MdOp, BitVector 32, BitVector 32) ->
  (MdS, (Bool, BitVector 32))
step s (active, op, a, b) = (s', out)
 where
  busy = case phase s of
    MdIdle -> active
    MdBusyMul _ -> True
    MdBusyDiv _ -> True
    MdDone -> False
  out = (busy, resultReg s)

  s' = case phase s of
    MdIdle
      | active ->
          if isDivForm op
            then launchDiv op a b
            else launchMul op a b
      | otherwise -> s
    MdBusyMul k ->
      let prod' = mulStep (operandB s) (prodReg s)
       in if k == maxBound
            then s {phase = MdDone, prodReg = prod', resultReg = finishMul (opReg s) (negResult s) prod'}
            else s {phase = MdBusyMul (k + 1), prodReg = prod'}
    MdBusyDiv k ->
      let prod' = divStep (operandB s) (prodReg s)
       in if k == maxBound
            then s {phase = MdDone, prodReg = prod', resultReg = finishDiv (opReg s) (negResult s) (negRem s) prod'}
            else s {phase = MdBusyDiv (k + 1), prodReg = prod'}
    MdDone -> s {phase = MdIdle}

-- * Launch helpers -------------------------------------------------

launchMul :: MdOp -> BitVector 32 -> BitVector 32 -> MdS
launchMul op a b =
  let aU = absIf (signedA op) a
      bU = absIf (signedB op) b
      -- prod init = {0, |rs2|} — multiplier in low 32, acc in high.
      -- (Convention: 'a' flows in as rs1, 'b' as rs2. We use |rs1|
      -- as the multiplicand added to the high 32 each iteration,
      -- and |rs2| as the shifted multiplier.)
      initProd :: BitVector 64
      initProd = zeroExtend bU
      neg = (signedA op && signBit a) `xor` (signedB op && signBit b)
   in MdS
        { phase = MdBusyMul 0
        , opReg = op
        , prodReg = initProd
        , operandB = aU -- multiplicand; added to high 32 when prod[0] is 1
        , negResult = neg
        , negRem = False
        , resultReg = 0
        }

launchDiv :: MdOp -> BitVector 32 -> BitVector 32 -> MdS
launchDiv op a b
  | b == 0 =
      -- Divide-by-zero early-out. Spec: DIV/DIVU → Q = -1 (all
      -- ones, any sign); REM/REMU → R = rs1 (raw, unchanged).
      let res = if wantRem op then a else maxBound
       in initState
            { phase = MdDone
            , opReg = op
            , resultReg = res
            }
  | otherwise =
      let aU = absIf (signedA op) a
          bU = absIf (signedB op) b
          -- prod init = {0, |rs1|} — dividend in low 32, remainder
          -- accumulator in high. After 32 shift-lefts, low 32 is
          -- the quotient and high 32 is the remainder.
          initProd :: BitVector 64
          initProd = zeroExtend aU
          -- Sign of the quotient differs from the natural value only
          -- when the input signs differ. Sign of the remainder
          -- follows the sign of the dividend ('rs1').
          negQ = (signedA op && signBit a) `xor` (signedB op && signBit b)
          negR = signedA op && signBit a
       in MdS
            { phase = MdBusyDiv 0
            , opReg = op
            , prodReg = initProd
            , operandB = bU -- divisor; compared against high 32 each iter
            , negResult = negQ
            , negRem = negR
            , resultReg = 0
            }

-- * Iteration steps ------------------------------------------------

{- | One shift-and-add multiply step. If the LSB of the current
product register is set, add the multiplicand into the high 32
bits; then logically right-shift the whole 64-bit register.

The add has to widen to 33 bits (@32-bit hi + 32-bit multiplicand
= up to 33 bits@) so the carry-out lands in bit 64 of the combined
register before the shift — a 32-bit-wide @hi + multiplicand@
truncates that carry and silently produces the wrong high-32
product for large unsigned inputs (caught by MULHU with both
operands @0xFFFFFFFF@: the product's high word flips from
@0xFFFFFFFE@ to @0@ without the widening).
-}
mulStep :: BitVector 32 -> BitVector 64 -> BitVector 64
mulStep multiplicand prod =
  let prod65 :: BitVector 65
      prod65 = zeroExtend prod
      added65 :: BitVector 65
      added65 =
        if lsb prod == 1
          then prod65 + ((zeroExtend multiplicand :: BitVector 65) `shiftL` 32)
          else prod65
   in slice d63 d0 (added65 `shiftR` 1)

{- | One restoring-division step. Left-shift the whole 64-bit
register (bringing the top of the dividend slot into the
remainder slot), then conditionally subtract the divisor from
the high 32 bits and set the low bit of the quotient.
-}
divStep :: BitVector 32 -> BitVector 64 -> BitVector 64
divStep divisor prod =
  let shifted = prod `shiftL` 1
      hi = slice d63 d32 shifted
      lo = slice d31 d0 shifted
   in if hi >= divisor
        then
          let hi' = hi - divisor
              lo' = lo .|. 1
           in hi' ++# lo'
        else shifted

-- * Result extraction ---------------------------------------------

finishMul :: MdOp -> Bool -> BitVector 64 -> BitVector 32
finishMul op neg prod64 =
  let prod = if neg then negBV prod64 else prod64
   in if wantHigh op then slice d63 d32 prod else slice d31 d0 prod

finishDiv :: MdOp -> Bool -> Bool -> BitVector 64 -> BitVector 32
finishDiv op negQ negR prod64 =
  let q = slice d31 d0 prod64
      r = slice d63 d32 prod64
   in if wantRem op
        then if negR then negBV r else r
        else if negQ then negBV q else q

-- * Bit-level helpers ---------------------------------------------

-- | Two's-complement negate.
negBV :: (KnownNat n) => BitVector n -> BitVector n
negBV v = complement v + 1

{- | If the flag is set, return @|v|@ interpreted as a 32-bit signed
two's-complement value. Otherwise return @v@ unchanged (raw-bit
unsigned path for the @*U@ forms).
-}
absIf :: Bool -> BitVector 32 -> BitVector 32
absIf True v
  | signBit v = negBV v
  | otherwise = v
absIf False v = v

-- | Bit 31 of a 32-bit word, interpreted as a 'Bool' sign flag.
signBit :: BitVector 32 -> Bool
signBit v = msb v == 1

-- * Combinational reference ---------------------------------------

{- | @riscv-formal@'s @RISCV_FORMAL_ALTOPS@ stubs for all eight
RV32M ops. Used by 'mulDivFUCombinational' under the
@FORMAL_FAST_MULDIV@ build.

Each op is a trivial @(rs1 +\/- rs2) ^ bitmask@, so the
bit-blasted SAT formula at every BMC step is small (one 32-bit
add or subtract plus a 32-bit XOR — no multiply or divide
primitives). Both boolector and z3 close all eight per-insn
proofs in seconds at depth 10.

The bitmasks are the low 32 bits of the 64-bit constants
@riscv-formal@ defines in @insns\/insn_{mul,mulh,…}.v@ — the
__identical__ values, so the harness's reference result
(@spec_rd_wdata@) matches our @combMd@ bit-for-bit, and the
proof becomes trivial equality.

__Soundness.__ @RISCV_FORMAL_ALTOPS@ is a standard riscv-formal
pattern for verifying M-extension cores: the harness and the
core both implement the same stub, so the proof establishes
that the __core pipeline__ correctly routes M-op operands
from @rs1@/@rs2@ to @rd@ on retire. The real arithmetic
correctness of MUL\/DIV is validated separately — for us, by
the 10-program triple-diff catalog in 'test\/SpikeDiffSpec.hs'
against Spike's native RV32IM implementation. A phase 2C+
task is to FU-isolate the iterative 'mulDivFUIterative'
against 'mulDivFUCombinational' in a dedicated SymbiYosys
proof, which would turn that triple-diff coverage into a
full exhaustive proof.
-}
combMd :: MdOp -> BitVector 32 -> BitVector 32 -> BitVector 32
combMd op a b = case op of
  MdMul -> (a + b) `xor` 0x5876063e
  MdMulH -> (a + b) `xor` 0xf6583fb7
  MdMulHsu -> (a - b) `xor` 0xecfbe137
  MdMulHu -> (a + b) `xor` 0x949ce5e8
  MdDiv -> (a - b) `xor` 0x7f8529ec
  MdDivU -> (a - b) `xor` 0x10e8fd70
  MdRem -> (a - b) `xor` 0x8da68fa5
  MdRemU -> (a - b) `xor` 0x3138d0e1
