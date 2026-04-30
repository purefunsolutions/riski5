-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
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
Module      : Riski5.Core.FU.Amo
Description : Multi-cycle A-extension functional unit (LR/SC + AMOs).

Phase-2 companion to 'Riski5.Core.FU.MulDiv'. Handles the eleven RV32A
instructions @LR.W@ / @SC.W@ + the nine @AMO*.W@ atomics. The FU sits
inside the X stage of the core and stalls the pipeline for a few
cycles per A-ext op while it sequences the necessary memory
transactions on the data bus:

  * __@LR.W@__ — 1 read cycle. Latches the original word, registers
    a reservation on the aligned address, returns the word to @rd@.
  * __@SC.W@__ — 0 or 1 write cycle. Compares the address to a live
    reservation; on match writes @rs2@ and returns @0@; on miss
    skips the write and returns @1@. Either way clears the
    reservation.
  * __@AMO*.W@__ — 1 read cycle + 1 write cycle. Reads the original
    word, computes @new = applyAmo op original rs2@, writes back,
    returns the original to @rd@. Clears any live reservation per
    the spec.

== State machine

@
                        amoActive=True                 ┌──── done? ────┐
              ┌─────────────────────────┐              │               │
              │                         ▼              ▼               │
            Idle ──────────► Read ────────► Write ────────► Done ──────┘
              ▲                                                │
              │                                                │
              └────────────────── retire cycle ────────────────┘
@

LR.W skips Write (Read → Done). SC.W-fail skips both Read and Write
(Idle → Done). AMOs use the full Read → Write → Done path.

== Bus drives

The FU drives a separate set of @amoDmemAddr@ / @amoDmemWdata@ /
@amoDmemBe@ / @amoDmemRen@ outputs. "Riski5.Core" muxes these onto
the actual dmem signals whenever 'amoBusyS' is asserted, taking
priority over 'handleInstr's defaults (which return zero for any
A-ext instruction).

== Reservation tracking

The @amoReservation@ field of the internal state is the canonical
LR/SC reservation register. It is __not__ a CSR — RV32A doesn't
expose it architecturally. Single-hart in-order means a successful
LR followed immediately by a matching SC always succeeds; an
intervening AMO clears it; a trap doesn't have to clear it for
correctness on this hart but the spec says "implementations may
clear reservations on a context switch", and we choose to leave it
alone since traps don't introduce intervening writes from other
agents.

== Cycle counts

  * LR.W — Idle (busy=True) → Read (busy=True) → Done (busy=False,
    retire). 2 busy cycles, 1 retire cycle.
  * SC.W success — Idle → Write → Done. 2 busy cycles.
  * SC.W failure — Idle → Done. 1 busy cycle.
  * AMO*.W — Idle → Read → Write → Done. 3 busy cycles.

A cache-coupled D-cache phase will eventually replace the bare
2-phase bus access with a tag-locked atomic transaction; at that
point the FU shrinks to a single "issue + wait for done" handshake.
For phase 2 the per-op latency is small enough that the simple
multi-cycle path is the right tradeoff.
-}
module Riski5.Core.FU.Amo (
  -- * A-extension dispatch
  AmoOp (..),
  amoOpOf,
  isAmoOp,
  applyAmo,

  -- * Functional unit
  amoFU,

  -- * Bundled bus drives
  AmoBus (..),
) where

import Clash.Prelude hiding (And, Xor, not, (!!), (&&), (||))

import Riski5.ISA (Instr (..))

-- * Op classification ---------------------------------------------

{- | Which of the eleven RV32A operations is in flight. Carried as a
small enum so case splits compile to a 4-bit comparator cone rather
than two independent funct5/funct3 cones.
-}
data AmoOp
  = AmoLrW
  | AmoScW
  | AmoSwap
  | AmoAdd
  | AmoXor
  | AmoAnd
  | AmoOr
  | AmoMin
  | AmoMax
  | AmoMinu
  | AmoMaxu
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

-- | True iff 'Instr' is one of the eleven RV32A ops.
isAmoOp :: Instr -> Bool
isAmoOp = \case
  LrW {} -> True
  ScW {} -> True
  AmoSwapW {} -> True
  AmoAddW {} -> True
  AmoXorW {} -> True
  AmoAndW {} -> True
  AmoOrW {} -> True
  AmoMinW {} -> True
  AmoMaxW {} -> True
  AmoMinuW {} -> True
  AmoMaxuW {} -> True
  _ -> False

{- | Project an RV32A 'Instr' down to an 'AmoOp' tag. Returns 'AmoLrW'
as a safe default for non-A instructions; callers must gate on
'isAmoOp' first.
-}
amoOpOf :: Instr -> AmoOp
amoOpOf = \case
  LrW {} -> AmoLrW
  ScW {} -> AmoScW
  AmoSwapW {} -> AmoSwap
  AmoAddW {} -> AmoAdd
  AmoXorW {} -> AmoXor
  AmoAndW {} -> AmoAnd
  AmoOrW {} -> AmoOr
  AmoMinW {} -> AmoMin
  AmoMaxW {} -> AmoMax
  AmoMinuW {} -> AmoMinu
  AmoMaxuW {} -> AmoMaxu
  _ -> AmoLrW

{- | The pure binary-op contribution of an AMO. For @AMO*.W@ the
returned value is what gets written back to memory; @AmoLrW@ /
@AmoScW@ don't go through this path.
-}
applyAmo :: AmoOp -> BitVector 32 -> BitVector 32 -> BitVector 32
applyAmo op a b = case op of
  AmoSwap -> b
  AmoAdd -> pack ((unpack a :: Signed 32) + unpack b)
  AmoXor -> a `xor` b
  AmoAnd -> a .&. b
  AmoOr -> a .|. b
  AmoMin -> if (unpack a :: Signed 32) < unpack b then a else b
  AmoMax -> if (unpack a :: Signed 32) > unpack b then a else b
  AmoMinu -> if (unpack a :: Unsigned 32) < unpack b then a else b
  AmoMaxu -> if (unpack a :: Unsigned 32) > unpack b then a else b
  -- LR / SC don't reach this helper. Return @b@ as a defined default
  -- so the case match is total without a partial @error@.
  _ -> b

-- * Bus drive bundle ----------------------------------------------

{- | The four dmem signals the FU drives. "Riski5.Core" muxes these
onto the SoC bus when the FU's @busy@ output is asserted (taking
priority over 'handleInstr's zero defaults).
-}
data AmoBus = AmoBus
  { amoDmemAddr :: BitVector 32
  , amoDmemWdata :: BitVector 32
  , amoDmemBe :: BitVector 4
  , amoDmemRen :: Bool
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (NFDataX)

-- | Bus drives during a phase that doesn't touch memory.
quietBus :: AmoBus
quietBus = AmoBus 0 0 0 False

-- * FSM state ------------------------------------------------------

-- | FU phase. See module-header diagram.
data AmoPhase
  = AmoIdle
  | AmoRead
  | AmoWrite
  | AmoDone
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- | FU internal state. Holds enough to drive the bus correctly through
the read / write / done sequence and present the architectural
result on the retire cycle.
-}
data AmoS = AmoS
  { phase :: AmoPhase
  , opReg :: AmoOp
  , addrReg :: BitVector 32
  -- ^ Word-aligned address for the current op (rs1 sampled at
  -- Idle → Busy edge).
  , rs2Reg :: BitVector 32
  , originalReg :: BitVector 32
  -- ^ Memory value captured at the end of the Read phase.
  , resultReg :: BitVector 32
  -- ^ Final value to write back to @rd@ on the retire cycle. Set
  -- on the transition into 'AmoDone'.
  , reservation :: Maybe (BitVector 32)
  -- ^ LR/SC reservation. @Nothing@ when no reservation is live.
  -- @Just addr@ records the word-aligned address an earlier @LR.W@
  -- registered. @SC.W@ checks this; AMOs and a fresh @LR.W@ both
  -- replace it.
  }
  deriving stock (Generic)
  deriving anyclass (NFDataX)

initState :: AmoS
initState =
  AmoS
    { phase = AmoIdle
    , opReg = AmoLrW
    , addrReg = 0
    , rs2Reg = 0
    , originalReg = 0
    , resultReg = 0
    , reservation = Nothing
    }

-- * FU entity ------------------------------------------------------

{- |
The A-extension functional unit. Inputs:

  * @activeS@ — @True@ on every cycle the X-stage instruction is an
    RV32A op. The FU latches inputs on the Idle → Busy transition.
  * @opS@ — the op tag (sampled only on the launch edge).
  * @addrS@ — rs1 value (the memory address).
  * @rs2S@ — rs2 value (write data for SC.W; second operand for
    AMOs; ignored for LR.W).
  * @dmemRdataS@ — combinational read response from the dmem bus.
    Captured at the end of the Read phase.

Outputs:

  * @busyS@ — @True@ for the Idle, Read, Write phases; @False@ in
    Done. The core uses this to gate the pipeline.
  * @resultS@ — the writeback value for @rd@. Valid on the cycle
    @busyS@ falls.
  * @busS@ — the dmem signals to mux onto the bus while busy.
-}
amoFU ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  Signal dom Bool ->
  Signal dom AmoOp ->
  Signal dom (BitVector 32) ->
  Signal dom (BitVector 32) ->
  Signal dom (BitVector 32) ->
  -- | slave ready: 'True' on cycles the dmem bus has settled the
  -- current transaction (read data valid, or write accepted). The
  -- AmoFU holds in 'AmoRead' / 'AmoWrite' phases while this is
  -- 'False', advancing only on a 'True' cycle. For BRAM / sim
  -- harnesses with async-read dmem, the caller passes constant
  -- 'True'. For multi-cycle slaves (SRAM, SDRAM), the caller
  -- passes the SoC's slave-ready signal so the FSM matches the
  -- access latency.
  Signal dom Bool ->
  ( Signal dom Bool
  , Signal dom (BitVector 32)
  , Signal dom AmoBus
  )
amoFU activeS opS addrS rs2S dmemRdataS slaveReadyS = (busyS, resultS, busS)
 where
  inS = bundle (activeS, opS, addrS, rs2S, dmemRdataS, slaveReadyS)
  outS = mealy step initState inS
  (busyS, resultS, busS) = unbundle outS

-- * Mealy step -----------------------------------------------------

step ::
  AmoS ->
  (Bool, AmoOp, BitVector 32, BitVector 32, BitVector 32, Bool) ->
  (AmoS, (Bool, BitVector 32, AmoBus))
step s (active, op, addr, rs2, dmemRdata, slaveReady) = (s', (busy, resultReg s, bus))
 where
  -- Output combinational signals depend on the *current* phase. The
  -- transition happens on the next clock edge.
  busy = case phase s of
    AmoIdle -> active
    AmoRead -> True
    AmoWrite -> True
    AmoDone -> False

  bus = case phase s of
    AmoIdle -> quietBus
    AmoRead ->
      AmoBus
        { amoDmemAddr = addrReg s
        , amoDmemWdata = 0
        , amoDmemBe = 0
        , amoDmemRen = True
        }
    AmoWrite ->
      let newVal = case opReg s of
            AmoScW -> rs2Reg s
            _ -> applyAmo (opReg s) (originalReg s) (rs2Reg s)
       in AmoBus
            { amoDmemAddr = addrReg s
            , amoDmemWdata = newVal
            , amoDmemBe = 0xF
            , amoDmemRen = False
            }
    AmoDone -> quietBus

  -- Transition logic. 'launchAt addr op' captures the operands on the
  -- Idle → Busy edge.
  s' = case phase s of
    AmoIdle
      | active -> launchAt op addr rs2 s
      | otherwise -> s
    AmoRead
      | not slaveReady -> s -- hold until slave settles the read
      | otherwise ->
          -- Capture the original word; for LR.W also register the
          -- reservation. AMOs go on to AmoWrite; LR.W skips to Done.
          let captured = dmemRdata
           in case opReg s of
                AmoLrW ->
                  s
                    { phase = AmoDone
                    , originalReg = captured
                    , resultReg = captured
                    , reservation = Just (addrReg s)
                    }
                _ ->
                  s
                    { phase = AmoWrite
                    , originalReg = captured
                    }
    AmoWrite
      | not slaveReady -> s -- hold until slave accepts the write
      | otherwise ->
          -- Write phase done. AMOs return the original; SC.W returns 0
          -- (always reached only on success — failure goes Idle → Done).
          let res = case opReg s of
                AmoScW -> 0
                _ -> originalReg s
           in s
                { phase = AmoDone
                , resultReg = res
                -- AMOs and successful SC.W both clear the reservation.
                , reservation = Nothing
                }
    AmoDone
      | active -> s
      -- ^ Hold AmoDone while the X-stage still has the AMO
      -- instruction (idValid && isAmoOp). Without this guard, the
      -- FSM transitions Done → Idle on the very next clock; if the
      -- pipeline can't retire the AMO in that one cycle (because
      -- e.g. the external @stallS@ is briefly high from the AMO's
      -- own write echoing back through a multi-cycle bus / CDC
      -- bridge), the next-cycle AmoIdle sees @active@ still True
      -- and re-launches via launchAt — generating a self-feeding
      -- loop where the AMO write is re-issued indefinitely. Task
      -- #143 / silicon Linux hang at PC=0x80000108 was exactly this.
      -- While in AmoDone the FU's @busy@ output is False, so the
      -- pipeline-advance logic is free to retire the AMO; once
      -- @active@ drops we enter AmoIdle cleanly.
      | otherwise -> s {phase = AmoIdle}

-- | State at the Idle → Busy transition: capture operands; for SC.W
-- additionally check the reservation and either head straight into
-- Write (success) or jump directly to Done with @rd = 1@ (failure).
launchAt :: AmoOp -> BitVector 32 -> BitVector 32 -> AmoS -> AmoS
launchAt op addr rs2 s = case op of
  AmoScW -> case reservation s of
    Just resAddr | resAddr == addr ->
      s
        { phase = AmoWrite
        , opReg = op
        , addrReg = addr
        , rs2Reg = rs2
        }
    _ ->
      s
        { phase = AmoDone
        , opReg = op
        , addrReg = addr
        , rs2Reg = rs2
        , resultReg = 1
        , reservation = Nothing
        }
  AmoLrW ->
    s
      { phase = AmoRead
      , opReg = op
      , addrReg = addr
      , rs2Reg = rs2
      }
  _ ->
    -- AMO*.W
    s
      { phase = AmoRead
      , opReg = op
      , addrReg = addr
      , rs2Reg = rs2
      }
