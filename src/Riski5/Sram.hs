-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Riski5.Sram
Description : Async-SRAM controller for the DE2's 512 KB IS61LV25616-class chip.

The DE2 carries an 18-address-line × 16-bit asynchronous SRAM
(256 K × 16 = 512 KB total). Per the DE2 User Manual table 4.17
the FPGA pins are:

@
  SRAM_ADDR[17:0]   address
  SRAM_DQ  [15:0]   bidirectional data bus
  SRAM_CE_N         chip enable (active LOW)
  SRAM_OE_N         output enable (active LOW, drives DQ on read)
  SRAM_WE_N         write enable (active LOW, latches DQ on rising edge)
  SRAM_UB_N         high-byte mask  (active LOW = byte enabled)
  SRAM_LB_N         low-byte mask   (active LOW = byte enabled)
@

== Single-cycle constraint

Riski5's pipelineless core has no stall mechanism: every memory
access must complete in one core cycle. The IS61LV25616 has
≈ 10 ns access time; at our 40 MHz core clock (25 ns period) one
half-word read/write completes well inside one cycle.

A 32-bit access to a 16-bit chip would normally cost two cycles —
which we can't afford without core surgery. Phase 1C therefore
exposes the SRAM as a **16-bit half-word memory only**: byte and
half-word loads/stores work in one cycle; word accesses
(@be == 0xF@) take this controller's combinational read path
(only the low half is meaningful) and any firmware that wants to
move 32-bit data must do it as two half-word transfers. The
firmware demo uses @lh@ / @lhu@ / @sh@ from @Riski5.Asm@.

Note: full 32-bit access to SRAM is deliberately deferred to
**phase 2**, when the core gains pipeline stages (an EX/MEM
boundary that can introduce a stall slot for the second SRAM
half-word). At that point this controller's interface stays the
same; the bus / core just gain a back-pressure signal to gate
the second cycle.

The CPU address inside the SRAM region is byte-addressed; the
controller drops bit 0 to form the SRAM half-word index, and uses
@be@ to derive @UB_N@ / @LB_N@ for byte selectivity.

== Simulation

The board's pins are 'BiSignalIn' / 'BiSignalOut'-shaped from the
core's perspective. For the Clash testbench we provide a
behavioural model 'sramSim' that wraps the controller with an
in-memory store, so 'test/SramSpec.hs' can run the full controller
without any HDL black-box.
-}
module Riski5.Sram (
  -- * Pin bundles
  SramPins (..),

  -- * Controller
  sram,

  -- * Behavioural model (simulation only)
  sramSim,
) where

import Clash.Prelude hiding (not, (&&), (||))
import Clash.Sized.Vector qualified as V
import Riski5.MemMap (sramBase)

{- |
External pin bundle the controller drives. Names match the DE2
User Manual table 4.17 verbatim.
-}
data SramPins = SramPins
  { sramAddr :: BitVector 18
  , sramDqOut :: BitVector 16
  , sramDqOe :: Bool
  -- ^ When 'True' the FPGA drives 'sramDqOut'; otherwise 'sramDqOut'
  -- is ignored and the SRAM owns the bus.
  , sramCeN :: Bit
  , sramOeN :: Bit
  , sramWeN :: Bit
  , sramUbN :: Bit
  , sramLbN :: Bit
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- |
SRAM controller.

Combinational read/write directly into the SRAM — at 40 MHz the
chip's 10 ns access time fits comfortably inside one core cycle.
Returns @(rdata, pins)@.

* @selS@ — slave-select from the bus decoder ('SlaveSram').
* @addrS@ — byte-addressed CPU address inside the SRAM region;
  the lower 19 bits index the 512 KB chip, with bit 0 picking
  the byte lane within a half-word.
* @wdataS@ — 32-bit write data; the byte lanes selected by @beS@
  are routed to the SRAM through @SRAM_UB_N@ / @SRAM_LB_N@.
* @beS@ — per-byte write-enable; nonzero on the lanes touching
  this half-word triggers a SRAM write.
* @sramDqIn@ — what the SRAM is currently driving on @SRAM_DQ@
  (sampled when @SRAM_OE_N == 0@ and the controller is reading).
-}
sram ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  -- | slave-select
  Signal dom Bool ->
  -- | CPU byte address
  Signal dom (BitVector 32) ->
  -- | 32-bit write data
  Signal dom (BitVector 32) ->
  -- | byte-enable
  Signal dom (BitVector 4) ->
  -- | read-enable (unused — read path is always live when selected)
  Signal dom Bool ->
  -- | data driven by the SRAM on the previous half-cycle
  Signal dom (BitVector 16) ->
  -- | @(rdata, pins)@
  ( Signal dom (BitVector 32)
  , Signal dom SramPins
  )
sram selS addrS wdataS beS _renS sramDqInS =
  (rdataS, pinsS)
 where
  -- The CPU address is byte-addressed, but the SRAM is half-word
  -- organised. Drop bit 0 to form the chip address.
  sramAddrS = (\a -> slice d18 d1 (a - sramBase)) <$> addrS

  -- Byte lane within the addressed half-word — picks which byte of
  -- a halfword gets routed into the upper / lower SRAM lanes.
  byteSelS = (\a -> testBit a 1) <$> addrS

  -- Decode beS / addr bit 1 into 'a write of any byte to either
  -- SRAM lane'. With phase-1C's half-word-only contract we treat
  -- the four CPU byte lanes as two SRAM halves: lanes 0/1 → low
  -- half (addr bit 1 == 0), lanes 2/3 → high half (addr bit 1 == 1).
  -- Within the chosen half, individual byte enables drive UB / LB.
  sramOpS =
    ( \sel be hi ->
        if not sel
          then SramOpIdle
          else
            let lowByte = if hi then testBit be 2 else testBit be 0
                hiByte = if hi then testBit be 3 else testBit be 1
             in case (lowByte, hiByte) of
                  (False, False) -> SramOpRead
                  _ -> SramOpWrite lowByte hiByte
    )
      <$> selS
      <*> beS
      <*> byteSelS

  -- The half-word the CPU wrote, projected from the requested CPU
  -- byte lane onto the SRAM data lines.
  sramWdataS =
    ( \w hi ->
        if hi
          then slice d31 d16 w
          else slice d15 d0 w
    )
      <$> wdataS
      <*> byteSelS

  -- Drive the pin bundle.
  pinsS =
    ( \op a d ->
        case op of
          SramOpIdle ->
            SramPins
              { sramAddr = a
              , sramDqOut = 0
              , sramDqOe = False
              , sramCeN = high -- chip disabled
              , sramOeN = high
              , sramWeN = high
              , sramUbN = high
              , sramLbN = high
              }
          SramOpRead ->
            SramPins
              { sramAddr = a
              , sramDqOut = 0
              , sramDqOe = False
              , sramCeN = low
              , sramOeN = low
              , sramWeN = high
              , sramUbN = low
              , sramLbN = low
              }
          SramOpWrite lo hi ->
            SramPins
              { sramAddr = a
              , sramDqOut = d
              , sramDqOe = True
              , sramCeN = low
              , sramOeN = high
              , sramWeN = low
              , sramUbN = if hi then low else high
              , sramLbN = if lo then low else high
              }
    )
      <$> sramOpS
      <*> sramAddrS
      <*> sramWdataS

  -- Read data: zero-extend the SRAM half-word into the CPU's 32-bit
  -- read-data bus, replicating onto the lane the CPU expects so a
  -- byte read out of the high lane lands in the right shifter slot.
  rdataS =
    ( \dqIn hi ->
        if hi
          then (zeroExtend dqIn :: BitVector 32) `shiftL` 16
          else zeroExtend dqIn
    )
      <$> sramDqInS
      <*> byteSelS

-- * Internal -------------------------------------------------------

{- | Decoded bus operation. Internal, not exported. The two booleans
on @SramOpWrite@ are the per-byte enables for low and high SRAM
lanes respectively.
-}
data SramOp
  = SramOpIdle
  | SramOpRead
  | SramOpWrite !Bool !Bool
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

-- * Behavioural simulation model -----------------------------------

{- |
Simulation wrapper: run 'sram' against an in-memory half-word store
of size @n@. Returns the same @(rdata, pins)@ pair, along with the
internal storage signal so tests can sample what's been written.

The store updates one cycle after a write request (modelling the
SRAM's WE-rising-edge latch), and reads are combinational — exactly
what the real chip does at the timescales we care about (10 ns
access ≪ 25 ns clock period).
-}
sramSim ::
  forall dom n.
  ( HiddenClockResetEnable dom
  , KnownNat n
  , 1 <= n
  ) =>
  -- | initial half-word contents
  Vec n (BitVector 16) ->
  Signal dom Bool ->
  Signal dom (BitVector 32) ->
  Signal dom (BitVector 32) ->
  Signal dom (BitVector 4) ->
  Signal dom Bool ->
  ( Signal dom (BitVector 32)
  , Signal dom SramPins
  , Signal dom (Vec n (BitVector 16))
  )
sramSim initial selS addrS wdataS beS renS = (rdataS, pinsS, storeS)
 where
  -- Storage: register over Vec n (BitVector 16). Updates on the
  -- next clock edge after a write request lands.
  storeS = register initial nextStoreS

  -- Project an 18-bit chip address into the model's @Index n@ for
  -- whatever @n@ the test happens to choose. Tests size the model
  -- a lot smaller than the real 256K half-words.
  toIndex :: BitVector 18 -> Index n
  toIndex bv = fromInteger (toInteger bv `mod` toInteger (maxBound :: Index n) + 1)

  -- Combinational read of the addressed half-word from the store.
  dqInS =
    (\store a -> store V.!! toIndex (slice d18 d1 (a - sramBase)))
      <$> storeS
      <*> addrS

  (rdataS, pinsS) = sram selS addrS wdataS beS renS dqInS

  -- Apply the controller's pin output to the model on each cycle.
  nextStoreS =
    ( \store p ->
        if sramWeN p == low && sramCeN p == low
          then
            let ix :: Index n
                ix = toIndex (sramAddr p)
                old = store V.!! ix
                lowMask, hiMask :: BitVector 16
                lowMask = if sramLbN p == low then 0x00FF else 0
                hiMask = if sramUbN p == low then 0xFF00 else 0
                mask = lowMask .|. hiMask
                new = (old .&. complement mask) .|. (sramDqOut p .&. mask)
             in V.replace ix new store
          else store
    )
      <$> storeS
      <*> pinsS
