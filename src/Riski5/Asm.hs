-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Riski5.Asm
Description : Haskell-embedded RV32I assembler.

A small monad layered over 'Riski5.Encode' that lets us write
firmware directly in Haskell. No external assembler involved:
labels, forward references, and the usual pseudo-instructions
(@li@, @mv@, @nop@, @ret@, @j@, @beqz@, …) are resolved by a
two-pass scan and the result is a @['BitVector' 32]@ suitable for
Quartus @.mif@ initialisation or direct Clash @Vec@ embedding.

This module, 'Riski5.Encode', and 'Riski5.Decode' are driven by the
single source of truth in 'Riski5.ISA'; there is no separate
\"assembler\" copy of the instruction set.
-}
module Riski5.Asm (
  -- * Assembler monad
  Asm,
  assemble,
  assembleAt,
  Label,
  AsmError (..),

  -- * Placing instructions
  emit,
  label,
  labelUnplaced,
  placeAt,

  -- * Real instruction wrappers — full RV32I + Zifencei + Zicsr +

  -- M-mode coverage (every constructor in 'Riski5.ISA.Instr').

  -- ** Upper-immediate / jumps
  lui,
  auipc,
  jal,
  jalr,

  -- ** Conditional branches
  beq,
  bne,
  blt,
  bge,
  bltu,
  bgeu,

  -- ** Loads
  lb,
  lh,
  lw,
  lbu,
  lhu,

  -- ** Stores
  sb,
  sh,
  sw,

  -- ** Integer register-immediate
  addi,
  slti,
  sltiu,
  xori,
  ori,
  andi,
  slli,
  srli,
  srai,

  -- ** Integer register-register
  add,
  sub,
  sll,
  slt,
  sltu,
  xor_,
  srl,
  sra,
  or_,
  and_,

  -- ** Memory-ordering (Zifencei)
  fence,
  fenceI,

  -- ** Environment + privileged (M-mode)
  ecall,
  ebreak,
  mret,

  -- ** Zicsr
  csrrw,
  csrrs,
  csrrc,
  csrrwi,
  csrrsi,
  csrrci,

  -- * Pseudo-instructions
  nop,
  mv,
  li,
  ret,
  j,
  jr,
  beqz,
  bnez,
  beq,
  bne,
  blt,
  bge,
  bltu,
  bgeu,
) where

import Clash.Prelude (BitVector, Signed)
import Control.Monad.State.Strict (
  State,
  execState,
  gets,
  modify',
 )
import Data.Bits (shiftR, (.&.))
import Data.Int (Int32)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Riski5.Encode (encode)
import Riski5.ISA

-- * Internals ---------------------------------------------------------

-- | A symbolic label; opaque, only created via 'label'.
newtype Label = Label Int
  deriving stock (Eq, Ord, Show)

-- | Things that can go wrong at assembly time.
data AsmError
  = UndefinedLabel Label
  | -- | Branch / jump offset out of range for its format.
    OffsetOutOfRange Label Int
  deriving stock (Eq, Show)

-- | Internal assembler state.
data AsmState = AsmState
  { stPos :: !Int
  -- ^ Current word offset in instruction slots.
  , stNextLabelId :: !Int
  -- ^ Monotonic counter for allocating 'Label's.
  , stItems :: ![Item]
  -- ^ Built in reverse; flushed + resolved by 'finish'.
  , stLabels :: !(Map Label Int)
  -- ^ Label → word offset.
  }

{- |
An un-resolved instruction placeholder. Concrete instructions are
wrapped with 'Concrete'; branch/jump / label-dependent items come
through 'LabelRel' carrying a resolver that accepts the label's
resolved position and the item's own position and produces an
'Instr' (or an 'AsmError' if the offset doesn't fit the field).
-}
data Item
  = Concrete !Int !Instr
  | LabelRel !Int !Label !(Int -> Int -> Either AsmError Instr)

-- | Assembler monad: a plain 'State' over 'AsmState'.
newtype Asm a = Asm (State AsmState a)
  deriving newtype (Functor, Applicative, Monad)

{- | Run an assembler program, producing a list of 32-bit machine words
starting at word offset zero.
-}
assemble :: Asm () -> Either AsmError [BitVector 32]
assemble = assembleAt 0

{- | Like 'assemble' but place the first instruction at the given byte
offset (e.g. a non-zero reset vector). The offset must be word-aligned.
-}
assembleAt :: Int -> Asm () -> Either AsmError [BitVector 32]
assembleAt baseByte (Asm m) =
  let st0 =
        AsmState
          { stPos = baseByte `div` 4
          , stNextLabelId = 0
          , stItems = []
          , stLabels = Map.empty
          }
      st = execState m st0
   in fmap (map encode) (resolve (reverse (stItems st)) (stLabels st))

{- | Second pass: walk the placeholder list in emission order and
resolve each 'LabelRel' using the collected label map.
-}
resolve :: [Item] -> Map Label Int -> Either AsmError [Instr]
resolve items labels = traverse one items
 where
  one (Concrete _ i) = Right i
  one (LabelRel pos lbl f) = case Map.lookup lbl labels of
    Nothing -> Left (UndefinedLabel lbl)
    Just tgt -> f pos tgt

-- * Primitive placement -----------------------------------------------

-- | Append an already-materialised instruction.
emit :: Instr -> Asm ()
emit i = Asm $ do
  pos <- gets stPos
  modify' $ \s ->
    s
      { stPos = pos + 1
      , stItems = Concrete pos i : stItems s
      }

{- | Create a fresh label placed at the current position. Use the
returned handle with branch / jump combinators below.
-}
label :: Asm Label
label = do
  lbl <- labelUnplaced
  placeAt lbl
  pure lbl

{- | Allocate a label without binding it to any position yet. Place it
later with 'placeAt'. Use this for forward references:

@
  end <- labelUnplaced
  beqz x5 end
  addi x6 x0 1
  placeAt end
@
-}
labelUnplaced :: Asm Label
labelUnplaced = Asm $ do
  n <- gets stNextLabelId
  modify' $ \s -> s {stNextLabelId = n + 1}
  pure (Label n)

{- | Bind a previously-allocated label to the current position. Calling
'placeAt' twice on the same label overwrites the first binding, so
don't.
-}
placeAt :: Label -> Asm ()
placeAt lbl = Asm $ do
  pos <- gets stPos
  modify' $ \s -> s {stLabels = Map.insert lbl pos (stLabels s)}

-- Append a label-dependent item. The resolver sees `(ownPos, targetPos)`
-- measured in word slots (i.e. pc / 4) and produces the concrete Instr
-- or an out-of-range error.
emitLabelRel :: Label -> (Int -> Int -> Either AsmError Instr) -> Asm ()
emitLabelRel lbl f = Asm $ do
  pos <- gets stPos
  modify' $ \s ->
    s
      { stPos = pos + 1
      , stItems = LabelRel pos lbl f : stItems s
      }

-- * Real-instruction wrappers ----------------------------------------

addi :: Reg -> Reg -> Signed 12 -> Asm ()
addi rd rs1 imm = emit (Addi rd rs1 imm)

add :: Reg -> Reg -> Reg -> Asm ()
add rd rs1 rs2 = emit (Add rd rs1 rs2)

sub :: Reg -> Reg -> Reg -> Asm ()
sub rd rs1 rs2 = emit (Sub rd rs1 rs2)

slti :: Reg -> Reg -> Signed 12 -> Asm ()
slti rd rs1 imm = emit (Slti rd rs1 imm)

sltiu :: Reg -> Reg -> Signed 12 -> Asm ()
sltiu rd rs1 imm = emit (Sltiu rd rs1 imm)

xori :: Reg -> Reg -> Signed 12 -> Asm ()
xori rd rs1 imm = emit (Xori rd rs1 imm)

ori :: Reg -> Reg -> Signed 12 -> Asm ()
ori rd rs1 imm = emit (Ori rd rs1 imm)

andi :: Reg -> Reg -> Signed 12 -> Asm ()
andi rd rs1 imm = emit (Andi rd rs1 imm)

slli :: Reg -> Reg -> BitVector 5 -> Asm ()
slli rd rs1 shamt = emit (Slli rd rs1 shamt)

srli :: Reg -> Reg -> BitVector 5 -> Asm ()
srli rd rs1 shamt = emit (Srli rd rs1 shamt)

srai :: Reg -> Reg -> BitVector 5 -> Asm ()
srai rd rs1 shamt = emit (Srai rd rs1 shamt)

-- | @LB rd, imm(rs1)@ — load a sign-extended byte.
lb :: Reg -> Reg -> Signed 12 -> Asm ()
lb rd rs1 imm = emit (Lb rd rs1 imm)

-- | @LH rd, imm(rs1)@ — load a sign-extended halfword.
lh :: Reg -> Reg -> Signed 12 -> Asm ()
lh rd rs1 imm = emit (Lh rd rs1 imm)

-- | @LW rd, imm(rs1)@ — load a 32-bit word.
lw :: Reg -> Reg -> Signed 12 -> Asm ()
lw rd rs1 imm = emit (Lw rd rs1 imm)

-- | @LBU rd, imm(rs1)@ — load a zero-extended byte.
lbu :: Reg -> Reg -> Signed 12 -> Asm ()
lbu rd rs1 imm = emit (Lbu rd rs1 imm)

-- | @LHU rd, imm(rs1)@ — load a zero-extended halfword.
lhu :: Reg -> Reg -> Signed 12 -> Asm ()
lhu rd rs1 imm = emit (Lhu rd rs1 imm)

-- | @SB rs2, imm(rs1)@ — store the low byte of @rs2@.
sb :: Reg -> Reg -> Signed 12 -> Asm ()
sb rs1 rs2 imm = emit (Sb rs1 rs2 imm)

-- | @SH rs2, imm(rs1)@ — store the low halfword of @rs2@.
sh :: Reg -> Reg -> Signed 12 -> Asm ()
sh rs1 rs2 imm = emit (Sh rs1 rs2 imm)

-- | @SW rs2, imm(rs1)@ — store all 32 bits of @rs2@.
sw :: Reg -> Reg -> Signed 12 -> Asm ()
sw rs1 rs2 imm = emit (Sw rs1 rs2 imm)

-- | @SLL rd, rs1, rs2@ — shift left logical (low 5 bits of @rs2@).
sll :: Reg -> Reg -> Reg -> Asm ()
sll rd rs1 rs2 = emit (Sll rd rs1 rs2)

-- | @SLT rd, rs1, rs2@ — set if @rs1@ < @rs2@ (signed).
slt :: Reg -> Reg -> Reg -> Asm ()
slt rd rs1 rs2 = emit (Slt rd rs1 rs2)

-- | @SLTU rd, rs1, rs2@ — set if @rs1@ < @rs2@ (unsigned).
sltu :: Reg -> Reg -> Reg -> Asm ()
sltu rd rs1 rs2 = emit (Sltu rd rs1 rs2)

{- | @XOR rd, rs1, rs2@ — bitwise exclusive-or. Named with a trailing
underscore to avoid clashing with @Data.Bits.xor@ in user code.
-}
xor_ :: Reg -> Reg -> Reg -> Asm ()
xor_ rd rs1 rs2 = emit (Xor rd rs1 rs2)

-- | @SRL rd, rs1, rs2@ — shift right logical.
srl :: Reg -> Reg -> Reg -> Asm ()
srl rd rs1 rs2 = emit (Srl rd rs1 rs2)

-- | @SRA rd, rs1, rs2@ — shift right arithmetic.
sra :: Reg -> Reg -> Reg -> Asm ()
sra rd rs1 rs2 = emit (Sra rd rs1 rs2)

{- | @OR rd, rs1, rs2@ — bitwise or. Trailing underscore avoids
clashing with @Prelude.or@ on @[Bool]@.
-}
or_ :: Reg -> Reg -> Reg -> Asm ()
or_ rd rs1 rs2 = emit (Or rd rs1 rs2)

{- | @AND rd, rs1, rs2@ — bitwise and. Trailing underscore avoids
clashing with @Prelude.and@ on @[Bool]@.
-}
and_ :: Reg -> Reg -> Reg -> Asm ()
and_ rd rs1 rs2 = emit (And rd rs1 rs2)

-- | @FENCE pred, succ@ — memory ordering fence (Zifencei).
fence :: BitVector 4 -> BitVector 4 -> Asm ()
fence pred_ succ_ = emit (Fence pred_ succ_)

-- | @FENCE.I@ — instruction-fetch fence.
fenceI :: Asm ()
fenceI = emit FenceI

lui :: Reg -> BitVector 20 -> Asm ()
lui rd imm = emit (Lui rd imm)

auipc :: Reg -> BitVector 20 -> Asm ()
auipc rd imm = emit (Auipc rd imm)

-- | @JAL rd, label@ — 21-bit PC-relative jump.
jal :: Reg -> Label -> Asm ()
jal rd lbl = emitLabelRel lbl $ \pos tgt ->
  jOffset pos tgt >>= \off -> Right (Jal rd off)

-- | @JALR rd, rs1, imm@ — absolute register-relative jump.
jalr :: Reg -> Reg -> Signed 12 -> Asm ()
jalr rd rs1 imm = emit (Jalr rd rs1 imm)

ecall :: Asm ()
ecall = emit Ecall

ebreak :: Asm ()
ebreak = emit Ebreak

mret :: Asm ()
mret = emit Mret

-- | @CSRRW rd, csr, rs1@ — atomic read-write of a CSR.
csrrw :: Reg -> Reg -> Csr -> Asm ()
csrrw rd rs1 csr = emit (Csrrw rd rs1 csr)

-- | @CSRRS rd, csr, rs1@ — atomic read-and-set CSR bits.
csrrs :: Reg -> Reg -> Csr -> Asm ()
csrrs rd rs1 csr = emit (Csrrs rd rs1 csr)

-- | @CSRRC rd, csr, rs1@ — atomic read-and-clear CSR bits.
csrrc :: Reg -> Reg -> Csr -> Asm ()
csrrc rd rs1 csr = emit (Csrrc rd rs1 csr)

{- | @CSRRWI rd, csr, uimm5@ — atomic read-write with a 5-bit
zero-extended immediate.
-}
csrrwi :: Reg -> BitVector 5 -> Csr -> Asm ()
csrrwi rd uimm csr = emit (Csrrwi rd uimm csr)

-- | @CSRRSI rd, csr, uimm5@ — atomic read-and-set with immediate.
csrrsi :: Reg -> BitVector 5 -> Csr -> Asm ()
csrrsi rd uimm csr = emit (Csrrsi rd uimm csr)

-- | @CSRRCI rd, csr, uimm5@ — atomic read-and-clear with immediate.
csrrci :: Reg -> BitVector 5 -> Csr -> Asm ()
csrrci rd uimm csr = emit (Csrrci rd uimm csr)

-- * Pseudo-instructions ----------------------------------------------

-- | Canonical RISC-V NOP: @ADDI x0, x0, 0@.
nop :: Asm ()
nop = addi x0 x0 0

-- | @mv rd, rs@ — encoded as @ADDI rd, rs, 0@.
mv :: Reg -> Reg -> Asm ()
mv rd rs = addi rd rs 0

{- |
@li rd, imm@ — load 32-bit immediate. Expands to:

  * @ADDI rd, x0, imm@ if @imm@ fits in 12-bit signed range; else
  * @LUI rd, upper20@ followed by @ADDI rd, rd, lower12@ where
    @upper20@ is chosen so the final 32-bit value equals @imm@ after
    the ADDI's sign extension.
-}
li :: Reg -> Int32 -> Asm ()
li rd imm
  | fitsSigned12 imm = addi rd x0 (fromIntegral imm)
  | otherwise = do
      let lower :: Int32
          lower = signExtend12 imm
          upper :: Int32
          upper = (imm - lower) `shiftR` 12 -- arithmetic shift, matches spec
      lui rd (fromIntegral (upper .&. 0xFFFFF))
      addi rd rd (fromIntegral lower)

-- | @ret@ — encoded as @JALR x0, ra, 0@.
ret :: Asm ()
ret = jalr x0 ra 0

{- | @j label@ — unconditional forward/backward jump; does not write
a return address. Encoded as @JAL x0, label@.
-}
j :: Label -> Asm ()
j = jal x0

-- | @jr rs@ — indirect jump. Encoded as @JALR x0, rs, 0@.
jr :: Reg -> Asm ()
jr rs = jalr x0 rs 0

-- | @beqz rs, label@ — @BEQ rs, x0, label@.
beqz :: Reg -> Label -> Asm ()
beqz rs = branchTo rs x0 Beq

-- | @bnez rs, label@ — @BNE rs, x0, label@.
bnez :: Reg -> Label -> Asm ()
bnez rs = branchTo rs x0 Bne

{- | Typed forward/backward branch combinators. Each takes the two
register operands plus a 'Label' and resolves the PC-relative
offset at assembly time.
-}
beq, bne, blt, bge, bltu, bgeu :: Reg -> Reg -> Label -> Asm ()
beq rs1 rs2 = branchTo rs1 rs2 Beq
bne rs1 rs2 = branchTo rs1 rs2 Bne
blt rs1 rs2 = branchTo rs1 rs2 Blt
bge rs1 rs2 = branchTo rs1 rs2 Bge
bltu rs1 rs2 = branchTo rs1 rs2 Bltu
bgeu rs1 rs2 = branchTo rs1 rs2 Bgeu

branchTo ::
  Reg ->
  Reg ->
  (Reg -> Reg -> Signed 13 -> Instr) ->
  Label ->
  Asm ()
branchTo rs1 rs2 ctor lbl = emitLabelRel lbl $ \pos tgt ->
  bOffset pos tgt >>= \off -> Right (ctor rs1 rs2 off)

-- * Offset fitting ---------------------------------------------------

-- | Fold a word-offset branch target into a 13-bit signed byte offset.
bOffset :: Int -> Int -> Either AsmError (Signed 13)
bOffset pos tgt =
  let byteDelta = (tgt - pos) * 4
   in if byteDelta < -4096 || byteDelta > 4094 || odd byteDelta
        then Left (OffsetOutOfRange (Label 0) byteDelta)
        else Right (fromIntegral byteDelta)

-- | Fold a word-offset jump target into a 21-bit signed byte offset.
jOffset :: Int -> Int -> Either AsmError (Signed 21)
jOffset pos tgt =
  let byteDelta = (tgt - pos) * 4
   in if byteDelta < -1048576 || byteDelta > 1048574 || odd byteDelta
        then Left (OffsetOutOfRange (Label 0) byteDelta)
        else Right (fromIntegral byteDelta)

fitsSigned12 :: Int32 -> Bool
fitsSigned12 x = x >= -2048 && x <= 2047

-- | Sign-extend the low 12 bits of an Int32 back to a full Int32.
signExtend12 :: Int32 -> Int32
signExtend12 x =
  let low = x .&. 0xFFF
      ext = if low .&. 0x800 /= 0 then low - 0x1000 else low
   in ext
