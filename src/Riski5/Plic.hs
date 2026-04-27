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
Module      : Riski5.Plic
Description : SiFive-PLIC-1.0.0-compatible interrupt controller — single hart, 8 sources.

A minimal Platform-Level Interrupt Controller laid out so the
upstream Linux @drivers/irqchip/irq-sifive-plic.c@ driver works
against riski5 with only a device-tree entry — no driver edits.

== Address layout (offsets from 'Riski5.MemMap.plicBase')

@
  0x0000_0004 .. 0x0000_001C   priority[1..7]   (4 bytes each)
  0x0000_1000                  pending[31:0]    (read-only, 1 register)
  0x0000_2000                  enable[31:0]     (hart 0 context 0)
  0x0020_0000                  threshold (hart 0)
  0x0020_0004                  claim / complete (hart 0)
@

Per the SiFive PLIC spec:

  * @priority[i]@ — 4-bit priority for source i (1..7). 0 disables;
    higher numbers preempt lower. Source 0 is reserved (read-only 0).
  * @pending[i]@ — set by hardware when an external IRQ source fires;
    cleared by writing the source ID to @complete@.
  * @enable[i]@ — masks @pending[i]@ for hart 0 context 0.
  * @threshold@ — interrupts fire at hart 0 only when their priority
    strictly exceeds this value.
  * @claim@ — read returns the highest-priority pending-and-enabled
    source ID (0 if none); reading also clears that source's
    @pending@ bit.
  * @complete@ — write the source ID to signal handler completion;
    also clears the bit on the in-flight pending if the same source
    is re-asserted, matching SiFive semantics.

== Source numbering

8 sources fit in a single 32-bit pending / enable word: bits 0..7.
Source 0 is reserved (Linux convention: "no source"). Sources 1..7
are wirable to peripherals via the 'plicExtIrqsS' input; the
order maps directly to PLIC source-ID, so DT @interrupts = <N>@
selects the bit at position @N@ in the input vector.

When more sources are needed (DM9000 + UART + GPIO + …), we widen
the input vector and the @pending@ / @enable@ words to 16, 32, …
sources. The register layout absorbs that natively because it
reserves a full 32-bit word for each.

== meipS output

Combinational: @meipS = any (pending bit & enable bit) whose
priority > threshold@. The CSR file's @mip.MEIP@ bit follows this
each cycle (mirrors the existing @mtipS@ → @mip.MTIP@ wiring from
the CLINT). @cMie.MEIE && cMstatus.MIE@ is the gate inside the
core's 'Riski5.CSR.interruptPending' predicate.
-}
module Riski5.Plic (
  PlicSources,
  plic,
) where

import Clash.Prelude hiding (foldl, not, (!!), (&&))
import Clash.Prelude qualified as CP
import Riski5.MemMap (plicBase)

-- | Width of the external IRQ input vector. 8 sources, indexed 0..7,
-- with index 0 reserved (per SiFive convention; firmware should
-- never enable source 0). Wired to peripherals in the SoC.
type PlicSources = 8

{- |
The PLIC block.

  * @selS@ — slave-select asserted by the bus decoder for the PLIC
    address window (true on cycles when @addr@ falls in the
    'plicBase'..'plicBase' + 0x0020_0008 range).
  * @addrS@ — byte-granular address (we sub-decode internally).
  * @wdataS@ / @beS@ / @readEnS@ — standard memory-bus fields.
  * @extIrqsS@ — per-source level-sensitive IRQ input. Bit @i@
    high means source @i@ is asserting; the PLIC samples on the
    clock edge to set @pending[i]@.
  * @rdataS@ — read data; reads of unmapped offsets return zero.
  * @meipS@ — combinational machine-external-interrupt-pending
    signal for hart 0 context 0. Wired into the core's CSR
    @mip.MEIP@ bit by 'Riski5.Soc'.

The 1-cycle round-trip is: extIrqsS sample at edge N sets
@pending[i]@ at cycle N+1; @pending[i] & enable[i]@ at priority >
threshold lights @meipS@ at cycle N+1; the core captures
@mip.MEIP@ at edge N+1→N+2; @interruptPending@ in 'handleInstr'
at cycle N+2 takes the trap.
-}
plic ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  -- | slave-select
  Signal dom Bool ->
  -- | address (byte-granular)
  Signal dom (BitVector 32) ->
  -- | write data
  Signal dom (BitVector 32) ->
  -- | byte-enable (any non-zero treated as a full-word write)
  Signal dom (BitVector 4) ->
  -- | read enable (currently unused; reads are always combinational)
  Signal dom Bool ->
  -- | external IRQ sources, one bit per source. Bit 0 reserved.
  Signal dom (BitVector PlicSources) ->
  -- | @(rdata, meip)@
  ( Signal dom (BitVector 32)
  , Signal dom Bool
  )
plic selS addrS wdataS beS _readEnS extIrqsS = (rdataS, meipS)
 where
  -- ---------------------------------------------------------------
  -- State
  -- ---------------------------------------------------------------

  -- 8 priority registers (index 0 reserved → forced to 0). Each is
  -- 4 bits, packed into 'BitVector 32' for the bus side.
  priorityS :: Vec PlicSources (Signal dom (BitVector 32))
  priorityS = CP.map mkPrio CP.indicesI
   where
    mkPrio :: Index PlicSources -> Signal dom (BitVector 32)
    mkPrio 0 = pure 0
    mkPrio i = register 0 (priorityNext i)

  priorityNext :: Index PlicSources -> Signal dom (BitVector 32)
  priorityNext i =
    ( \cur wr w ->
        if wr then w .&. 0xF else cur
    )
      <$> (priorityS CP.!! i)
      <*> writePriorityS i
      <*> wdataS

  -- pending bits — set when an extIrqs bit rises (level-sensitive
  -- with edge-detect-ish semantics: pending stays set until cleared
  -- by a claim or complete, even if the source de-asserts). Source
  -- 0 always reads 0.
  pendingS :: Signal dom (BitVector 32)
  pendingS = register 0 pendingNextS

  pendingNextS :: Signal dom (BitVector 32)
  pendingNextS =
    ( \cur ext clr ->
        let ext32 = zeroExtend ext :: BitVector 32
            -- A source's pending bit latches True on any cycle its
            -- input is high and the bit isn't currently being cleared.
            -- Source 0 is reserved; mask it out.
            src0Mask = complement 1 :: BitVector 32
            set = ext32 .&. src0Mask
            -- Cleared bits: claim or complete this cycle.
            cleared = cur .&. complement clr
         in cleared .|. (set .&. complement clr)
    )
      <$> pendingS
      <*> extIrqsS
      <*> pendingClrS

  -- enable bits for hart 0 context 0. Bit 0 always reads 0.
  enableS :: Signal dom (BitVector 32)
  enableS = register 0 enableNextS

  enableNextS :: Signal dom (BitVector 32)
  enableNextS =
    ( \cur wr w ->
        if wr then w .&. complement 1 else cur
    )
      <$> enableS
      <*> writeEnableS
      <*> wdataS

  -- threshold — only 4 bits matter (matches priority width).
  thresholdS :: Signal dom (BitVector 32)
  thresholdS = register 0 thresholdNextS

  thresholdNextS :: Signal dom (BitVector 32)
  thresholdNextS =
    (\cur wr w -> if wr then w .&. 0xF else cur)
      <$> thresholdS
      <*> writeThresholdS
      <*> wdataS

  -- ---------------------------------------------------------------
  -- Address decoding
  -- ---------------------------------------------------------------

  -- True iff the bus is presenting a write to the named offset.
  writeAt :: BitVector 32 -> Signal dom Bool
  writeAt off =
    (\s a be -> s && a == plicBase + off && be /= 0)
      <$> selS
      <*> addrS
      <*> beS

  writePriorityS :: Index PlicSources -> Signal dom Bool
  writePriorityS i =
    writeAt (4 * fromIntegral (toInteger i))

  writePendingS :: Signal dom Bool
  writePendingS = writeAt 0x1000

  writeEnableS :: Signal dom Bool
  writeEnableS = writeAt 0x2000

  writeThresholdS :: Signal dom Bool
  writeThresholdS = writeAt 0x20_0000

  writeClaimCompleteS :: Signal dom Bool
  writeClaimCompleteS = writeAt 0x20_0004

  -- True iff the bus is reading the claim/complete register this
  -- cycle. A read of claim has a side-effect: it clears the
  -- pending bit of the returned source.
  readClaimS :: Signal dom Bool
  readClaimS =
    (\s a -> s && a == plicBase + 0x20_0004)
      <$> selS
      <*> addrS

  -- ---------------------------------------------------------------
  -- Pending-bit clear logic
  -- ---------------------------------------------------------------
  --
  -- Three clear sources:
  --   * Software writes to the @pending@ register (rare; mostly
  --     used for testing — Linux drivers don't write pending).
  --   * A claim read returns the lowest-numbered enabled-and-pending
  --     source; the act of reading clears that source's bit.
  --   * A complete write clears the source ID written.
  --
  -- All three OR into a single 32-bit clear mask consumed by
  -- 'pendingNextS'.

  pendingClrS :: Signal dom (BitVector 32)
  pendingClrS =
    ( \claim claimEn complete completeEn pendingWr pendingW ->
        let claimMask = if claimEn then bit (fromIntegral claim) else 0
            completeMask =
              if completeEn
                then bit (fromIntegral (slice d4 d0 complete))
                else 0
            -- A write to pending clears bits set in wdata (1-to-clear
            -- semantics — quirky but matches what most SiFive PLIC
            -- testbenches expect).
            pendingMask =
              if pendingWr
                then pendingW
                else 0
         in claimMask .|. completeMask .|. pendingMask
    )
      <$> claimedSourceS
      <*> readClaimS
      <*> wdataS
      <*> writeClaimCompleteS
      <*> writePendingS
      <*> wdataS

  -- ---------------------------------------------------------------
  -- Claim arbitration
  -- ---------------------------------------------------------------
  --
  -- Returns the lowest-numbered source that is both pending and
  -- enabled, with priority > threshold. Returns 0 ("no source") if
  -- none qualify. Lowest-numbered tie-break matches the SiFive
  -- spec's "select the source with the highest priority; ties go to
  -- lowest source ID."

  -- For our 8-source setup, an O(N) scan over priorityS suffices.
  -- Each step compares the candidate's priority against the running
  -- best and picks the winner. Linear logic depth in N — fine on
  -- Cyclone II for N=8; if we grow N past ~16 we'd switch to a
  -- tree-reduction.
  claimedSourceS :: Signal dom (BitVector 5)
  claimedSourceS =
    arbitrate
      <$> bundle priorityVecS
      <*> pendingS
      <*> enableS
      <*> thresholdS

  -- 'priorityS' is 'Vec PlicSources (Signal dom (BitVector 32))';
  -- bundle each entry into a single Signal of a Vec for the
  -- arbiter.
  priorityVecS :: Vec PlicSources (Signal dom (BitVector 32))
  priorityVecS = priorityS

  -- ---------------------------------------------------------------
  -- meipS — combinational pending-and-eligible
  -- ---------------------------------------------------------------

  meipS :: Signal dom Bool
  meipS = (/= 0) <$> claimedSourceS

  -- ---------------------------------------------------------------
  -- Read mux
  -- ---------------------------------------------------------------

  rdataS :: Signal dom (BitVector 32)
  rdataS =
    ( \sel addr prios pend en thr claim claimEn ->
        if not sel
          then 0
          else case addr - plicBase of
            -- priority[1..7]
            off
              | off < 0x20 -> prios CP.!! (slice d4 d2 off :: BitVector 3)
              | off == 0x1000 -> pend
              | off == 0x2000 -> en
              | off == 0x20_0000 -> thr
              | off == 0x20_0004 ->
                  -- Reading claim: returns the source ID and clears
                  -- the bit (clear is handled in pendingClrS).
                  if claimEn
                    then zeroExtend claim
                    else zeroExtend claim
              | otherwise -> 0
    )
      <$> selS
      <*> addrS
      <*> bundle priorityVecS
      <*> pendingS
      <*> enableS
      <*> thresholdS
      <*> claimedSourceS
      <*> readClaimS

-- | One-pass linear arbiter: walk the source vector low-to-high,
-- keep the highest-priority candidate that is pending && enabled
-- && priority > threshold; ties go to the lowest source index.
-- Returns the winning source ID (0 if no source qualifies).
arbitrate ::
  Vec PlicSources (BitVector 32) ->
  BitVector 32 ->
  BitVector 32 ->
  BitVector 32 ->
  BitVector 5
arbitrate prios pending enable threshold =
  let candidates = imap candidate prios
   in CP.foldl pickHigher (0, 0) candidates
        & snd
 where
  candidate ::
    Index PlicSources ->
    BitVector 32 ->
    (BitVector 4, BitVector 5)
  candidate i prio =
    let bitOk =
          (slice d0 d0 (pending `shiftR` fromIntegral i) == (1 :: BitVector 1))
            && (slice d0 d0 (enable `shiftR` fromIntegral i) == (1 :: BitVector 1))
        prio4 :: BitVector 4
        prio4 = slice d3 d0 prio
        thr4 :: BitVector 4
        thr4 = slice d3 d0 threshold
        eligible = bitOk && prio4 > thr4 && i /= 0
        prioOut = if eligible then prio4 else 0
        idxOut :: BitVector 5
        idxOut = if eligible then fromIntegral (toInteger i) else 0
     in (prioOut, idxOut)

  pickHigher ::
    (BitVector 4, BitVector 5) ->
    (BitVector 4, BitVector 5) ->
    (BitVector 4, BitVector 5)
  pickHigher (bestP, bestId) (curP, curId) =
    if curP > bestP
      then (curP, curId)
      else (bestP, bestId)

  (&) :: a -> (a -> b) -> b
  x & f = f x
  infixl 1 &
