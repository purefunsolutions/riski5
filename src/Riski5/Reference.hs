-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Riski5.Reference
Description : Pure-Haskell RV32I + Zicsr + M-mode reference executor.

A minimal interpreter that takes an 'Instr' and a 'MachineState' and
returns the state after executing the instruction. Used as the
Haskell-side golden oracle for differential testing against the
Clash-in-Verilator simulation of the real core (see
@docs/verification.md@, Layer 1).

This module is deliberately simple and readable — no Clash, no
performance tricks, no clever monad stacks. The whole thing is a
pattern match on 'Instr'. Errors (illegal operations, alignment
faults) surface as 'TrapCause' values threaded through the normal
machine-state transitions, mirroring the hardware's trap path.
-}
module Riski5.Reference (
  -- * Machine state
  MachineState (..),
  initial,

  -- * Traps
  TrapCause (..),

  -- * Stepping
  step,
  run,

  -- * Register helpers
  readReg,
  writeReg,

  -- * Memory helpers (exposed for SoC sim)
  Addr,
  readByte,
  readWord,
  writeByte,
  writeHalf,
  writeWord,
) where

import Clash.Prelude (BitVector, Signed, Unsigned, pack, unpack)
import Data.Bits (
  complement,
  shiftL,
  shiftR,
  xor,
  (.&.),
  (.|.),
 )
import Data.Int (Int32, Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Word (Word32, Word64, Word8)
import Riski5.Decode (decode)
import Riski5.ISA

-- * Machine state ----------------------------------------------------

-- | 32-bit physical address.
type Addr = Word32

{- | Snapshot of the architectural state needed to execute an
RV32I + Zicsr + M-mode instruction. Kept deliberately simple:
byte-addressable memory via a Map (mostly-empty regions are sparse;
tests initialise only what they touch).

@regs@ is indexed by the raw 5-bit register number. @x0@ reads zero
and writes are ignored, enforced inside 'writeReg'.

Only machine-mode CSRs riski5 actually implements are modelled;
reads from unmodelled CSRs return zero, writes are accepted silently
(the hardware core will trap instead; we match that more strictly
once the core exists).
-}
data MachineState = MachineState
  { regs :: Map (BitVector 5) Word32
  , pc :: Word32
  , memory :: Map Addr Word8
  , csrs :: Map (BitVector 12) Word32
  , reservation :: Maybe Addr
  -- ^ A-extension LR/SC reservation. @Nothing@ when no reservation is
  -- live. @Just addr@ records the word-aligned address an earlier
  -- @LR.W@ registered. The matching @SC.W@ checks this; any other
  -- write to the same address (including AMOs and traps) clears it.
  }
  deriving stock (Eq, Show)

-- | Fresh zero-initialised machine state with PC at @0x00000000@.
initial :: MachineState
initial =
  MachineState
    { regs = Map.empty
    , pc = 0
    , memory = Map.empty
    , csrs = Map.empty
    , reservation = Nothing
    }

-- * Traps ------------------------------------------------------------

-- | Exception cause values as defined by the RISC-V privileged spec.
data TrapCause
  = InstrAddrMisaligned
  | IllegalInstr
  | BreakpointExc
  | LoadAddrMisaligned
  | StoreAddrMisaligned
  | EcallFromM
  deriving stock (Eq, Show)

-- * Register helpers -------------------------------------------------

-- | Read a register. @x0@ always reads zero.
readReg :: Reg -> MachineState -> Word32
readReg (Reg 0) _ = 0
readReg (Reg n) s = Map.findWithDefault 0 n (regs s)

-- | Write a register. Writes to @x0@ are ignored per the ISA.
writeReg :: Reg -> Word32 -> MachineState -> MachineState
writeReg (Reg 0) _ s = s
writeReg (Reg n) v s = s {regs = Map.insert n v (regs s)}

-- * Memory -----------------------------------------------------------

readByte :: Addr -> MachineState -> Word8
readByte a s = Map.findWithDefault 0 a (memory s)

writeByte :: Addr -> Word8 -> MachineState -> MachineState
writeByte a b s = s {memory = Map.insert a b (memory s)}

readHalf :: Addr -> MachineState -> Word32
readHalf a s =
  fromIntegral (readByte a s)
    .|. (fromIntegral (readByte (a + 1) s) `shiftL` 8)

readWord :: Addr -> MachineState -> Word32
readWord a s =
  fromIntegral (readByte a s)
    .|. (fromIntegral (readByte (a + 1) s) `shiftL` 8)
    .|. (fromIntegral (readByte (a + 2) s) `shiftL` 16)
    .|. (fromIntegral (readByte (a + 3) s) `shiftL` 24)

writeHalf :: Addr -> Word32 -> MachineState -> MachineState
writeHalf a v =
  writeByte a (fromIntegral v)
    . writeByte (a + 1) (fromIntegral (v `shiftR` 8))

writeWord :: Addr -> Word32 -> MachineState -> MachineState
writeWord a v =
  writeByte a (fromIntegral v)
    . writeByte (a + 1) (fromIntegral (v `shiftR` 8))
    . writeByte (a + 2) (fromIntegral (v `shiftR` 16))
    . writeByte (a + 3) (fromIntegral (v `shiftR` 24))

-- | Sign-extend an 8-bit byte into a 32-bit word.
signExtendByte :: Word8 -> Word32
signExtendByte b
  | b .&. 0x80 /= 0 = fromIntegral b .|. 0xFFFFFF00
  | otherwise = fromIntegral b

-- | Sign-extend a 16-bit half into a 32-bit word.
signExtendHalf :: Word32 -> Word32
signExtendHalf h
  | h .&. 0x8000 /= 0 = h .|. 0xFFFF0000
  | otherwise = h

-- * Immediate helpers -----------------------------------------------

-- | Widen a signed N-bit immediate to a 32-bit word (sign-extended).
sxImm12 :: Signed 12 -> Word32
sxImm12 = fromIntegral @Int32 . fromIntegral

sxImm13 :: Signed 13 -> Word32
sxImm13 = fromIntegral @Int32 . fromIntegral

sxImm21 :: Signed 21 -> Word32
sxImm21 = fromIntegral @Int32 . fromIntegral

-- | Place an unsigned 20-bit U-type immediate in bits [31:12].
u20 :: BitVector 20 -> Word32
u20 b = fromIntegral (pack (unpack b :: Unsigned 20)) `shiftL` 12

-- | Widen a 5-bit shift amount to an Int usable by Data.Bits.
shamtInt :: BitVector 5 -> Int
shamtInt b = fromIntegral (pack (unpack b :: Unsigned 5) :: BitVector 5)

-- * Stepping --------------------------------------------------------

{- | Fetch-decode-execute one instruction. Returns 'Left' with a
'TrapCause' on illegal patterns, alignment faults, or environment
calls / breakpoints. Returns 'Right' with the new state on normal
completion; PC advancement is baked into the result.

The trap path mirrors the hardware: @mepc@ ← pc, @mcause@ ← cause
(numeric value per the priv spec), pc ← @mtvec.base@. No delegation,
no privilege switch — we only have M-mode.
-}
step :: MachineState -> Either TrapCause MachineState
step s =
  let bits = readWord (pc s) s
      bv :: BitVector 32
      bv = fromIntegral bits
   in case decode bv of
        Nothing -> trap IllegalInstr s
        Just i -> execute i s

execute :: Instr -> MachineState -> Either TrapCause MachineState
execute i s = case i of
  -- U-type
  Lui rd imm -> next (writeReg rd (u20 imm) s)
  Auipc rd imm -> next (writeReg rd (pc s + u20 imm) s)
  -- J-type
  Jal rd off ->
    let target = pc s + sxImm21 off
     in if target .&. 3 /= 0
          then trap InstrAddrMisaligned s
          else Right ((writeReg rd (pc s + 4) s) {pc = target})
  -- I-type jumps
  Jalr rd rs1 off ->
    let target = (readReg rs1 s + sxImm12 off) .&. complement 1
     in if target .&. 3 /= 0
          then trap InstrAddrMisaligned s
          else Right ((writeReg rd (pc s + 4) s) {pc = target})
  -- Loads
  Lb rd rs1 off -> nextLoad rd rs1 off 1 True s
  Lh rd rs1 off -> nextLoad rd rs1 off 2 True s
  Lw rd rs1 off -> nextLoad rd rs1 off 4 False s
  Lbu rd rs1 off -> nextLoad rd rs1 off 1 False s
  Lhu rd rs1 off -> nextLoad rd rs1 off 2 False s
  -- Arithmetic-immediate
  Addi rd rs1 imm -> next (writeReg rd (readReg rs1 s + sxImm12 imm) s)
  Slti rd rs1 imm ->
    next
      ( writeReg
          rd
          ( if toSigned (readReg rs1 s) < toSigned (sxImm12 imm)
              then 1
              else 0
          )
          s
      )
  Sltiu rd rs1 imm ->
    next
      ( writeReg
          rd
          (if readReg rs1 s < sxImm12 imm then 1 else 0)
          s
      )
  Xori rd rs1 imm -> next (writeReg rd (readReg rs1 s `xor` sxImm12 imm) s)
  Ori rd rs1 imm -> next (writeReg rd (readReg rs1 s .|. sxImm12 imm) s)
  Andi rd rs1 imm -> next (writeReg rd (readReg rs1 s .&. sxImm12 imm) s)
  Slli rd rs1 shamt -> next (writeReg rd (readReg rs1 s `shiftL` shamtInt shamt) s)
  Srli rd rs1 shamt -> next (writeReg rd (readReg rs1 s `shiftR` shamtInt shamt) s)
  Srai rd rs1 shamt ->
    next (writeReg rd (fromIntegral (toSigned (readReg rs1 s) `shiftR` shamtInt shamt)) s)
  -- Stores
  Sb rs1 rs2 off ->
    let addr = readReg rs1 s + sxImm12 off
     in next (writeByte addr (fromIntegral (readReg rs2 s)) s)
  Sh rs1 rs2 off ->
    let addr = readReg rs1 s + sxImm12 off
     in if addr .&. 1 /= 0
          then trap StoreAddrMisaligned s
          else next (writeHalf addr (readReg rs2 s) s)
  Sw rs1 rs2 off ->
    let addr = readReg rs1 s + sxImm12 off
     in if addr .&. 3 /= 0
          then trap StoreAddrMisaligned s
          else next (writeWord addr (readReg rs2 s) s)
  -- Branches
  Beq rs1 rs2 off -> branch (readReg rs1 s == readReg rs2 s) off s
  Bne rs1 rs2 off -> branch (readReg rs1 s /= readReg rs2 s) off s
  Blt rs1 rs2 off -> branch (toSigned (readReg rs1 s) < toSigned (readReg rs2 s)) off s
  Bge rs1 rs2 off -> branch (toSigned (readReg rs1 s) >= toSigned (readReg rs2 s)) off s
  Bltu rs1 rs2 off -> branch (readReg rs1 s < readReg rs2 s) off s
  Bgeu rs1 rs2 off -> branch (readReg rs1 s >= readReg rs2 s) off s
  -- R-type register-register arithmetic
  Add rd rs1 rs2 -> next (writeReg rd (readReg rs1 s + readReg rs2 s) s)
  Sub rd rs1 rs2 -> next (writeReg rd (readReg rs1 s - readReg rs2 s) s)
  Sll rd rs1 rs2 ->
    next (writeReg rd (readReg rs1 s `shiftL` fromIntegral (readReg rs2 s .&. 0x1F)) s)
  Slt rd rs1 rs2 ->
    next
      ( writeReg
          rd
          (if toSigned (readReg rs1 s) < toSigned (readReg rs2 s) then 1 else 0)
          s
      )
  Sltu rd rs1 rs2 ->
    next (writeReg rd (if readReg rs1 s < readReg rs2 s then 1 else 0) s)
  Xor rd rs1 rs2 -> next (writeReg rd (readReg rs1 s `xor` readReg rs2 s) s)
  Srl rd rs1 rs2 ->
    next (writeReg rd (readReg rs1 s `shiftR` fromIntegral (readReg rs2 s .&. 0x1F)) s)
  Sra rd rs1 rs2 ->
    next
      ( writeReg
          rd
          ( fromIntegral
              ( toSigned (readReg rs1 s)
                  `shiftR` fromIntegral (readReg rs2 s .&. 0x1F)
              )
          )
          s
      )
  Or rd rs1 rs2 -> next (writeReg rd (readReg rs1 s .|. readReg rs2 s) s)
  And rd rs1 rs2 -> next (writeReg rd (readReg rs1 s .&. readReg rs2 s) s)
  -- A-extension. Reservation is single-hart-only here. Address
  -- alignment is checked and AMO/SC misalignment traps as a store
  -- fault, mirroring the hardware path.
  LrW rd rs1 _aqrl ->
    let addr = readReg rs1 s
     in if addr .&. 3 /= 0
          then trap LoadAddrMisaligned s
          else
            let v = readWord addr s
             in next (writeReg rd v (s {reservation = Just addr}))
  ScW rd rs1 rs2 _aqrl ->
    let addr = readReg rs1 s
     in if addr .&. 3 /= 0
          then trap StoreAddrMisaligned s
          else case reservation s of
            Just resAddr | resAddr == addr ->
              -- Success: write rs2, return 0, clear reservation.
              let s' = writeWord addr (readReg rs2 s) s
               in next (writeReg rd 0 (s' {reservation = Nothing}))
            _ ->
              -- Fail: skip store, return non-zero, clear reservation.
              next (writeReg rd 1 (s {reservation = Nothing}))
  AmoSwapW rd rs1 rs2 aqrl -> doAmo rd rs1 rs2 aqrl AmoFnSwap s
  AmoAddW rd rs1 rs2 aqrl -> doAmo rd rs1 rs2 aqrl AmoFnAdd s
  AmoXorW rd rs1 rs2 aqrl -> doAmo rd rs1 rs2 aqrl AmoFnXor s
  AmoAndW rd rs1 rs2 aqrl -> doAmo rd rs1 rs2 aqrl AmoFnAnd s
  AmoOrW rd rs1 rs2 aqrl -> doAmo rd rs1 rs2 aqrl AmoFnOr s
  AmoMinW rd rs1 rs2 aqrl -> doAmo rd rs1 rs2 aqrl AmoFnMin s
  AmoMaxW rd rs1 rs2 aqrl -> doAmo rd rs1 rs2 aqrl AmoFnMax s
  AmoMinuW rd rs1 rs2 aqrl -> doAmo rd rs1 rs2 aqrl AmoFnMinu s
  AmoMaxuW rd rs1 rs2 aqrl -> doAmo rd rs1 rs2 aqrl AmoFnMaxu s
  -- RV32M — integer multiply / divide.
  Mul rd rs1 rs2 ->
    -- Low 32 bits of the 64-bit product; sign-agnostic.
    next (writeReg rd (readReg rs1 s * readReg rs2 s) s)
  MulH rd rs1 rs2 ->
    let a :: Int64
        a = fromIntegral (toSigned (readReg rs1 s))
        b :: Int64
        b = fromIntegral (toSigned (readReg rs2 s))
        hi = fromIntegral ((a * b) `shiftR` 32) :: Word32
     in next (writeReg rd hi s)
  MulHsu rd rs1 rs2 ->
    let a :: Int64
        a = fromIntegral (toSigned (readReg rs1 s))
        b :: Int64
        b = fromIntegral (readReg rs2 s) -- zero-extend unsigned → Int64 is still positive
        hi = fromIntegral ((a * b) `shiftR` 32) :: Word32
     in next (writeReg rd hi s)
  MulHu rd rs1 rs2 ->
    let a :: Word64
        a = fromIntegral (readReg rs1 s)
        b :: Word64
        b = fromIntegral (readReg rs2 s)
        hi = fromIntegral ((a * b) `shiftR` 32) :: Word32
     in next (writeReg rd hi s)
  Div rd rs1 rs2 ->
    -- Signed division, truncated toward zero. Special cases per the
    -- RV32M spec §7.2 "Semantics for Divide by Zero and Division
    -- Overflow": dividing by zero yields -1 (all 1s), and signed
    -- INT_MIN / -1 yields INT_MIN (quotient overflow, no trap).
    let a = toSigned (readReg rs1 s)
        b = toSigned (readReg rs2 s)
        q
          | b == 0 = -1
          | a == minBound && b == -1 = a
          | otherwise = a `quot` b
     in next (writeReg rd (fromIntegral q) s)
  DivU rd rs1 rs2 ->
    let a = readReg rs1 s
        b = readReg rs2 s
        q
          | b == 0 = maxBound -- 2^32 - 1
          | otherwise = a `quot` b
     in next (writeReg rd q s)
  Rem rd rs1 rs2 ->
    -- Remainder has the sign of the dividend. Special cases:
    -- b == 0 → r = rs1; INT_MIN `rem` -1 → 0.
    let a = toSigned (readReg rs1 s)
        b = toSigned (readReg rs2 s)
        r
          | b == 0 = a
          | a == minBound && b == -1 = 0
          | otherwise = a `rem` b
     in next (writeReg rd (fromIntegral r) s)
  RemU rd rs1 rs2 ->
    let a = readReg rs1 s
        b = readReg rs2 s
        r
          | b == 0 = a
          | otherwise = a `rem` b
     in next (writeReg rd r s)
  -- MISC-MEM
  Fence {} -> next s -- no caches, nothing to synchronise
  FenceI -> next s -- ditto for instruction fetch
  -- SYSTEM — environment
  Ecall -> trap EcallFromM s
  Ebreak -> trap BreakpointExc s
  Mret ->
    -- Jump to mepc; simplified (no xIE/xPIE dance).
    Right (s {pc = Map.findWithDefault 0 (unCsr csrMepc) (csrs s)})
  -- SYSTEM — Zicsr
  Csrrw rd rs1 csr ->
    let old = Map.findWithDefault 0 (unCsr csr) (csrs s)
        new = readReg rs1 s
        s' = writeReg rd old s
     in next (s' {csrs = Map.insert (unCsr csr) new (csrs s')})
  Csrrs rd rs1 csr ->
    let old = Map.findWithDefault 0 (unCsr csr) (csrs s)
        new = old .|. readReg rs1 s
        s' = writeReg rd old s
     in next (s' {csrs = Map.insert (unCsr csr) new (csrs s')})
  Csrrc rd rs1 csr ->
    let old = Map.findWithDefault 0 (unCsr csr) (csrs s)
        new = old .&. complement (readReg rs1 s)
        s' = writeReg rd old s
     in next (s' {csrs = Map.insert (unCsr csr) new (csrs s')})
  Csrrwi rd zimm csr ->
    let old = Map.findWithDefault 0 (unCsr csr) (csrs s)
        new = fromIntegral (pack (unpack zimm :: Unsigned 5) :: BitVector 5)
        s' = writeReg rd old s
     in next (s' {csrs = Map.insert (unCsr csr) new (csrs s')})
  Csrrsi rd zimm csr ->
    let old = Map.findWithDefault 0 (unCsr csr) (csrs s)
        new = old .|. fromIntegral (pack (unpack zimm :: Unsigned 5) :: BitVector 5)
        s' = writeReg rd old s
     in next (s' {csrs = Map.insert (unCsr csr) new (csrs s')})
  Csrrci rd zimm csr ->
    let old = Map.findWithDefault 0 (unCsr csr) (csrs s)
        new =
          old
            .&. complement
              (fromIntegral (pack (unpack zimm :: Unsigned 5) :: BitVector 5))
        s' = writeReg rd old s
     in next (s' {csrs = Map.insert (unCsr csr) new (csrs s')})

-- * Execution primitives --------------------------------------------

-- | Advance PC by 4; no writes beyond what the caller has already done.
next :: MachineState -> Either TrapCause MachineState
next s = Right (s {pc = pc s + 4})

-- | The nine RV32A read-modify-write atomics share a single helper.
data AmoFn
  = AmoFnSwap
  | AmoFnAdd
  | AmoFnXor
  | AmoFnAnd
  | AmoFnOr
  | AmoFnMin
  | AmoFnMax
  | AmoFnMinu
  | AmoFnMaxu

-- | Apply an AMO read-modify-write at @[rs1]@: read original, compute
-- the new value, write it back, deliver the original to @rd@. Always
-- clears any live reservation per the spec. Misaligned addresses
-- trap as store faults — RISC-V groups AMO misalignment under the
-- store class.
doAmo ::
  Reg ->
  Reg ->
  Reg ->
  BitVector 2 ->
  AmoFn ->
  MachineState ->
  Either TrapCause MachineState
doAmo rd rs1 rs2 _aqrl op s =
  let addr = readReg rs1 s
   in if addr .&. 3 /= 0
        then trap StoreAddrMisaligned s
        else
          let original = readWord addr s
              operand = readReg rs2 s
              newVal = applyAmo op original operand
              s' = writeWord addr newVal s
           in next (writeReg rd original (s' {reservation = Nothing}))

-- | Pure-function definitions of the nine RV32A binary operations.
applyAmo :: AmoFn -> Word32 -> Word32 -> Word32
applyAmo op a b = case op of
  AmoFnSwap -> b
  AmoFnAdd -> a + b
  AmoFnXor -> a `xor` b
  AmoFnAnd -> a .&. b
  AmoFnOr -> a .|. b
  AmoFnMin -> if toSigned a < toSigned b then a else b
  AmoFnMax -> if toSigned a > toSigned b then a else b
  AmoFnMinu -> if a < b then a else b
  AmoFnMaxu -> if a > b then a else b

{- |
Compute a load and write it to @rd@; traps on misalignment. Accepts
the access width (1/2/4 bytes) and whether the result should be
sign-extended.
-}
nextLoad ::
  Reg ->
  Reg ->
  Signed 12 ->
  Word32 ->
  Bool ->
  MachineState ->
  Either TrapCause MachineState
nextLoad rd rs1 off width signed s =
  let addr = readReg rs1 s + sxImm12 off
      aligned = case width of
        1 -> True
        2 -> addr .&. 1 == 0
        4 -> addr .&. 3 == 0
        _ -> True
   in if not aligned
        then trap LoadAddrMisaligned s
        else
          let v = case (width, signed) of
                (1, True) -> signExtendByte (readByte addr s)
                (1, False) -> fromIntegral (readByte addr s)
                (2, True) -> signExtendHalf (readHalf addr s)
                (2, False) -> readHalf addr s
                (4, _) -> readWord addr s
                _ -> 0 -- unreachable
           in next (writeReg rd v s)

{- | Conditional branch helper: taken branches set pc ← pc+off,
untaken advance by 4.
-}
branch :: Bool -> Signed 13 -> MachineState -> Either TrapCause MachineState
branch taken off s
  | not taken = next s
  | otherwise =
      let target = pc s + sxImm13 off
       in if target .&. 3 /= 0
            then trap InstrAddrMisaligned s
            else Right (s {pc = target})

{- |
Raise a trap: record the cause, save pc to @mepc@, jump to
@mtvec.base@. Mirrors the hardware trap path without the
privilege/delegation dance.
-}
trap :: TrapCause -> MachineState -> Either TrapCause MachineState
trap cause s =
  let mepc' = pc s
      mcauseVal = causeNumber cause
      mtvec = Map.findWithDefault 0 (unCsr csrMtvec) (csrs s)
      base = mtvec .&. complement 3
      csrs' =
        Map.insert (unCsr csrMepc) mepc' $
          Map.insert (unCsr csrMcause) mcauseVal (csrs s)
   in Right (s {csrs = csrs', pc = base}) `seq`
        Left cause
 where
  -- We both record the cause numerically (so callers that *don't*
  -- stop on trap can keep stepping) and surface it via Left so the
  -- typical test runner halts immediately on the first exception.
  causeNumber = \case
    InstrAddrMisaligned -> 0
    IllegalInstr -> 2
    BreakpointExc -> 3
    LoadAddrMisaligned -> 4
    StoreAddrMisaligned -> 6
    EcallFromM -> 11

{- | Run for at most @n@ steps or until a trap is raised; return the
final state (or the state at the trap point) and the cause if any.
-}
run :: Int -> MachineState -> (MachineState, Maybe TrapCause)
run = go
 where
  go 0 s = (s, Nothing)
  go k s = case step s of
    Left cause -> (s, Just cause)
    Right s' -> go (k - 1) s'

-- * Signed interpretation -------------------------------------------

-- | Reinterpret a 32-bit word as signed.
toSigned :: Word32 -> Int32
toSigned = fromIntegral
