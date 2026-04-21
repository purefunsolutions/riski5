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
Description : FSM-based async-SRAM controller for the DE2's 512 KB IS61LV25616-class chip.

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

== T31a: explicit FSM with write recovery + 32-bit access

Earlier phase-1C revisions exposed the chip as half-word-only with a
combinational pin path and a single-cycle write. That worked for
isolated accesses but two hazards were latent:

  1. __Back-to-back writes__ kept @WE_N@ low across cycles while
     @SRAM_ADDR@ and @SRAM_DQ_O@ changed mid-flight — undefined on
     a real chip (t_AW = 8 ns requires address stable before WE
     rising). Never tripped because no phase-1 firmware issues
     consecutive @SRAM@ writes, but a latent bug nonetheless.
  2. __Read-after-write on the same address__ relied on the
     simultaneous cycle-edge transitions @WE_N: low→high@ and
     @OE_N: high→low@ completing within one 33 ns cycle — legal on
     paper (t_WR = 0 ns) but no built-in margin.

T31a replaces the combinational pin drive with an explicit FSM that
gives every write a __pulse + recovery__ cycle pair, and promotes
every read to a full 32-bit __word-read__ (two back-to-back
half-word fetches) so @LW@ works and the controller doesn't need
to branch on access width.

Cycle layout (each row = one 30 MHz cycle, 33.33 ns):

@
    SB / SH:  pulse    (WE=low, addr+data driven, ready=False)
              recover  (WE=high, addr+data held → rising-edge latches,
                         ready=True)

    SW:       lo-pulse   (WE=low, addr=lo, data=lo-half, ready=False)
              lo-recover (WE=high, addr=lo held, ready=False)
              hi-pulse   (WE=low, addr=hi, data=hi-half, ready=False)
              hi-recover (WE=high, addr=hi held, ready=True)

    LB/LBU/LH/LHU/LW (uniform word read):
              lo-pulse   (OE=low, addr=lo, ready=False;
                           sramDqIn captures SRAM[lo] at cycle end)
              hi-pulse   (OE=low, addr=hi, ready=False;
                           sramDqIn captures SRAM[hi] at cycle end,
                           wordLoReg latches the lo half)
              commit     (ready=True, rdata = SRAM[hi]<<16 | SRAM[lo])
@

The core stalls through every non-terminal cycle via @readyS=False@.

Uniform word-read simplifies the FSM (7 states instead of 13) and
the 32-bit @rdata@ is a superset of what the core needs for LH/LB
— the core's own load-width masking (see @loadMask@ / @extendLoad@
in @Riski5.Core@) picks the right bits.

== Cycle counts at 30 MHz (33.33 ns / cycle)

@
  Op                   Cycles   Wall time
  LB / LBU / LH / LHU       3     100.00 ns
  LW                        3     100.00 ns
  SB / SH                   2      66.67 ns
  SW                        4     133.33 ns
@

== Why this should close timing better

Pre-T31a, @sramRdataS@ passed through a combinational chain:
@external SRAM_DQ pin → FPGA input → byte-select mux → 32-bit rdata
bus mux in Soc.hs → core writeback mux → rfile write port@. Each
cycle of that chain had to settle inside 33 ns minus PLL / clock-tree
skew. T31a breaks the chain at two points: @sramDqInS = register 0
sramDqInRawS@ registers the chip input pin, and @wordLoReg@ latches
the lo half one cycle before the hi half. The ALU / writeback cone
now sees a pre-settled rdata, so Quartus should report a higher
Fmax on the SRAM data path (the old design was already at 34 MHz;
T31a is expected to lift the ceiling).

== Simulation

The board's pins are 'BiSignalIn' / 'BiSignalOut'-shaped from the
core's perspective. For the Clash testbench we provide a
behavioural model 'sramSim' that wraps the controller with an
in-memory store. The model latches writes on the __rising edge__
of @WE_N@ (not on every @WE=low@ cycle) so a controller that skips
the recovery cycle or cuts hold time short will silently fail the
test instead of silently passing.
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
  {- ^ When 'True' the FPGA drives 'sramDqOut'; otherwise 'sramDqOut'
  is ignored and the SRAM owns the bus.
  -}
  , sramCeN :: Bit
  , sramOeN :: Bit
  , sramWeN :: Bit
  , sramUbN :: Bit
  , sramLbN :: Bit
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

-- * Controller FSM ------------------------------------------------

{- | Controller state.

'SIdle' doubles as both "no transaction" (when @selS@ is false) and
__first cycle of any op__ (when @selS@ is true). Pin logic for
'SIdle' branches on the bus signals to drive the first-cycle pins
directly, so a new op starts on the same cycle it's requested.

Terminal states ('SReadHiCommit', 'SHalfWriteRecover',
'SWordWriteHiRecover') raise @readyS=True@ and the core advances
at the edge into 'SIdle'.
-}
data SramState
  = -- | Either no transaction or the first cycle of a new op.
    SIdle
  | -- | 2nd cycle of any read: driving the hi-half chip address.
    SReadHiStall
  | -- | 3rd cycle of any read: @rdata@ presented, ready=True.
    SReadHiCommit
  | -- | 2nd cycle of SB/SH: WE rising-edge latches the write.
    SHalfWriteRecover
  | -- | 2nd cycle of SW: lo-half WE rising-edge latch; addr+data held.
    SWordWriteLoRecover
  | -- | 3rd cycle of SW: driving WE low on the hi half.
    SWordWriteHiPulse
  | -- | 4th cycle of SW: hi-half WE rising-edge latch; ready=True.
    SWordWriteHiRecover
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- |
SRAM controller. See module header for the FSM layout + timing
table.
-}
sram ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  -- | slave-select from the bus decoder
  Signal dom Bool ->
  -- | CPU byte address
  Signal dom (BitVector 32) ->
  -- | 32-bit write data
  Signal dom (BitVector 32) ->
  -- | byte-enable (nonzero on stores; zero on loads)
  Signal dom (BitVector 4) ->
  -- | read-enable (unused — "read" is inferred from @be == 0@)
  Signal dom Bool ->
  -- | data driven by the SRAM on @SRAM_DQ@ this cycle (external input)
  Signal dom (BitVector 16) ->
  -- | @(rdata, pins, ready)@
  ( Signal dom (BitVector 32)
  , Signal dom SramPins
  , Signal dom Bool
  )
sram selS addrS wdataS beS _renS sramDqInRawS =
  (rdataS, pinsS, readyS)
 where
  -- Register the off-chip SRAM DQ input once, inside the controller.
  -- One cycle of read latency in exchange for slack on the pin →
  -- input-flop path; see module header.
  sramDqInS = register 0 sramDqInRawS

  -- Half-word index of the CPU's addressed half-word. Bit 0 may be
  -- 0 or 1 depending on @addr[1]@ (hi-half within a word).
  halfIdxS = (\a -> slice d18 d1 (a - sramBase)) <$> addrS

  -- Word-aligned chip addresses. For reads (uniform word access),
  -- lo is the even index, hi is the odd index of the surrounding
  -- 32-bit word. Works correctly regardless of whether the CPU
  -- access is word-aligned (LW/SW), half-aligned (LH), or byte-aligned
  -- (LB) because we always read the entire word and let the core's
  -- load logic mask the right bits.
  wordLoAddrS = (\h -> h .&. complement 1) <$> halfIdxS
  wordHiAddrS = (\h -> h .|. 1) <$> halfIdxS

  -- Decoded op shape — combinational from bus signals.
  isWriteS = (\be -> be /= 0) <$> beS
  isWordS = (\be -> be == 0b1111) <$> beS

  -- FSM state register.
  stateS = register SIdle nextStateS
  nextStateS = nextState <$> stateS <*> selS <*> isWriteS <*> isWordS

  -- Low-half register for word reads. Latched at the end of
  -- 'SReadHiStall' when @sramDqInS@ holds the freshly-registered lo
  -- half. On the following cycle ('SReadHiCommit') the hi half
  -- appears on @sramDqInS@ and we combine them.
  wordLoReg = register 0 wordLoNextS
  wordLoNextS =
    ( \st dq old -> case st of
        SReadHiStall -> dq
        _ -> old
    )
      <$> stateS
      <*> sramDqInS
      <*> wordLoReg

  -- Ready. True on terminal cycles only; False during every other
  -- cycle (including 'SIdle' with @selS@ active, which is the first
  -- cycle of a new op).
  readyS = ready <$> stateS <*> selS

  -- Pin bundle.
  pinsS =
    pinsFor
      <$> stateS
      <*> selS
      <*> isWriteS
      <*> isWordS
      <*> halfIdxS
      <*> wordLoAddrS
      <*> wordHiAddrS
      <*> byteSelS
      <*> beS
      <*> wdataS

  -- Which half of the 32-bit CPU word the current half / byte access
  -- targets (hi if @addr[1] == 1@). Drives half-word write data
  -- routing and byte-enable selection for SB / SH.
  byteSelS = (\a -> testBit a 1) <$> addrS

  -- Read data presented to the core. Always a full 32-bit word from
  -- SRAM; the core's load logic masks to the requested width.
  rdataS = rdata <$> stateS <*> sramDqInS <*> wordLoReg

-- * FSM helpers ----------------------------------------------------

-- | Next-state transition function.
nextState :: SramState -> Bool -> Bool -> Bool -> SramState
nextState SIdle False _ _ = SIdle
nextState SIdle True isWrite isWord =
  case (isWrite, isWord) of
    (True, True) -> SWordWriteLoRecover -- cycle 0 of SW was the lo pulse
    (True, False) -> SHalfWriteRecover -- cycle 0 of SB/SH was the pulse
    (False, _) -> SReadHiStall -- cycle 0 of any read was the lo pulse
nextState SReadHiStall _ _ _ = SReadHiCommit
nextState SReadHiCommit _ _ _ = SIdle
nextState SHalfWriteRecover _ _ _ = SIdle
nextState SWordWriteLoRecover _ _ _ = SWordWriteHiPulse
nextState SWordWriteHiPulse _ _ _ = SWordWriteHiRecover
nextState SWordWriteHiRecover _ _ _ = SIdle

-- | @readyS@ value for a given state.
ready :: SramState -> Bool -> Bool
ready SIdle sel = not sel
ready SReadHiStall _ = False
ready SReadHiCommit _ = True
ready SHalfWriteRecover _ = True
ready SWordWriteLoRecover _ = False
ready SWordWriteHiPulse _ = False
ready SWordWriteHiRecover _ = True

{- | Pin bundle for the current cycle.

When in 'SIdle' with @selS@ active, drives the __first cycle of the
pending op__ (read lo-pulse, half-write pulse, or word-write lo-pulse)
so the stall slot is repurposed to drive the initial pulse. Saves
one cycle per access vs the "start in next cycle" layout.
-}
pinsFor ::
  SramState ->
  -- | selS
  Bool ->
  -- | isWriteS
  Bool ->
  -- | isWordS
  Bool ->
  -- | halfIdxS (half-word index from CPU addr)
  BitVector 18 ->
  -- | wordLoAddrS (word-aligned lo chip addr)
  BitVector 18 ->
  -- | wordHiAddrS (word-aligned hi chip addr)
  BitVector 18 ->
  -- | byteSelS (half is hi half of CPU word)
  Bool ->
  -- | beS
  BitVector 4 ->
  -- | wdataS
  BitVector 32 ->
  SramPins
pinsFor st sel isWrite isWord halfIdx wLo wHi byteHi be wdata = case st of
  SIdle
    | not sel -> idlePins
    | isWord && isWrite -> wordWritePulse wLo (slice d15 d0 wdata)
    | isWord && not isWrite -> wordReadPulse wLo
    | not isWord && isWrite ->
        halfWritePulse halfIdx (halfWdata wdata byteHi) (halfLoLane byteHi be) (halfHiLane byteHi be)
    | otherwise -> wordReadPulse wLo
  SReadHiStall -> wordReadPulse wHi
  SReadHiCommit -> wordReadPulse wHi
  SHalfWriteRecover ->
    halfWriteRecover halfIdx (halfWdata wdata byteHi) (halfLoLane byteHi be) (halfHiLane byteHi be)
  SWordWriteLoRecover -> wordWriteRecover wLo (slice d15 d0 wdata)
  SWordWriteHiPulse -> wordWritePulse wHi (slice d31 d16 wdata)
  SWordWriteHiRecover -> wordWriteRecover wHi (slice d31 d16 wdata)

-- | Half-word data to drive for a half / byte write — pick the lo
-- or hi half of the 32-bit CPU word based on @addr[1]@.
halfWdata :: BitVector 32 -> Bool -> BitVector 16
halfWdata w True = slice d31 d16 w
halfWdata w False = slice d15 d0 w

-- | Lo-byte-lane enable (maps to @LB_N@) for a half / byte write.
halfLoLane :: Bool -> BitVector 4 -> Bool
halfLoLane True be = testBit be 2
halfLoLane False be = testBit be 0

-- | Hi-byte-lane enable (maps to @UB_N@) for a half / byte write.
halfHiLane :: Bool -> BitVector 4 -> Bool
halfHiLane True be = testBit be 3
halfHiLane False be = testBit be 1

-- ** Individual per-op pin bundles --------------------------------

-- | No transaction: chip disabled.
idlePins :: SramPins
idlePins =
  SramPins
    { sramAddr = 0
    , sramDqOut = 0
    , sramDqOe = False
    , sramCeN = high
    , sramOeN = high
    , sramWeN = high
    , sramUbN = high
    , sramLbN = high
    }

-- | Read pulse / hold. Both byte lanes enabled; the core masks later.
wordReadPulse :: BitVector 18 -> SramPins
wordReadPulse a =
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

-- | Half-word write pulse — WE low, UB / LB per the per-byte enables
-- of the addressed half (byte 0 → LB, byte 1 → UB inside the
-- half-word's position in the 32-bit CPU word).
halfWritePulse :: BitVector 18 -> BitVector 16 -> Bool -> Bool -> SramPins
halfWritePulse a d loByte hiByte =
  SramPins
    { sramAddr = a
    , sramDqOut = d
    , sramDqOe = True
    , sramCeN = low
    , sramOeN = high
    , sramWeN = low
    , sramUbN = if hiByte then low else high
    , sramLbN = if loByte then low else high
    }

-- | Half-word write recovery — WE high (rising edge at entry latches
-- the write), addr + data held from the pulse cycle.
halfWriteRecover :: BitVector 18 -> BitVector 16 -> Bool -> Bool -> SramPins
halfWriteRecover a d loByte hiByte =
  (halfWritePulse a d loByte hiByte) {sramWeN = high}

-- | Word write pulse — both byte lanes enabled, WE low.
wordWritePulse :: BitVector 18 -> BitVector 16 -> SramPins
wordWritePulse a d =
  SramPins
    { sramAddr = a
    , sramDqOut = d
    , sramDqOe = True
    , sramCeN = low
    , sramOeN = high
    , sramWeN = low
    , sramUbN = low
    , sramLbN = low
    }

-- | Word write recovery — WE high, both byte lanes enabled.
wordWriteRecover :: BitVector 18 -> BitVector 16 -> SramPins
wordWriteRecover a d = (wordWritePulse a d) {sramWeN = high}

-- ** Read data mux ------------------------------------------------

-- | Read data presented to the core on the commit cycle. On every
-- other state the value is don't-care (the core doesn't capture it
-- unless @readyS@ is True, which only happens on 'SReadHiCommit' for
-- reads).
rdata :: SramState -> BitVector 16 -> BitVector 16 -> BitVector 32
rdata SReadHiCommit dqIn wordLo =
  ((zeroExtend dqIn :: BitVector 32) `shiftL` 16)
    .|. (zeroExtend wordLo :: BitVector 32)
rdata _ _ _ = 0

-- * Behavioural simulation model -----------------------------------

{- |
Simulation wrapper: run 'sram' against an in-memory half-word store
of size @n@. Returns the same @(rdata, pins, ready)@ tuple as the
real controller, along with the internal storage signal so tests
can sample what's been written.

Unlike earlier revisions, this model latches writes on the __rising
edge__ of @WE_N@ (not on every @WE=low@ cycle). That way a
controller that forgets the recovery cycle or runs address / data
through WE transitions will silently fail the test instead of
silently passing.
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
  -- | @(rdata, pins, store, ready)@
  ( Signal dom (BitVector 32)
  , Signal dom SramPins
  , Signal dom (Vec n (BitVector 16))
  , Signal dom Bool
  )
sramSim initial selS addrS wdataS beS renS = (rdataS, pinsS, storeS, readyS)
 where
  -- Storage: register over Vec n (BitVector 16). Updates at each
  -- WE_N rising edge when CE_N is asserted.
  storeS = register initial nextStoreS

  toIndex :: BitVector 18 -> Index n
  toIndex bv = fromInteger (toInteger bv `mod` toInteger (maxBound :: Index n) + 1)

  -- Combinational read of the addressed half-word from the store —
  -- using whatever chip address the controller is currently driving
  -- (not the CPU address directly), so word reads' second half
  -- returns the right value.
  dqInS =
    (\store p -> store V.!! toIndex (sramAddr p))
      <$> storeS
      <*> pinsS

  (rdataS, pinsS, readyS) = sram selS addrS wdataS beS renS dqInS

  -- Track WE_N across cycles so we can detect rising edges (which
  -- is when the real chip latches the write).
  prevWeNS = register high (sramWeN <$> pinsS)
  weRisingS =
    (\prev curr -> prev == low && curr == high)
      <$> prevWeNS
      <*> (sramWeN <$> pinsS)

  nextStoreS =
    ( \store p rising ->
        if rising && sramCeN p == low
          then
            let ix :: Index n
                ix = toIndex (sramAddr p)
                oldHalfWord = store V.!! ix
                lowMask, hiMask :: BitVector 16
                lowMask = if sramLbN p == low then 0x00FF else 0
                hiMask = if sramUbN p == low then 0xFF00 else 0
                mask = lowMask .|. hiMask
                newHalfWord = (oldHalfWord .&. complement mask) .|. (sramDqOut p .&. mask)
             in V.replace ix newHalfWord store
          else store
    )
      <$> storeS
      <*> pinsS
      <*> weRisingS
