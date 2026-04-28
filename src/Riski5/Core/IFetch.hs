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
Module      : Riski5.Core.IFetch
Description : RV32IMAC instruction-fetch unit — 2-deep fetch FIFO + half-word realigner.

The IF stage's job is to feed the decoder one 32-bit instruction
per cycle. Without the C extension that's straightforward — the
PC advances in 4-byte steps, every fetched 32-bit word holds
exactly one instruction, and a single sync-read BRAM port covers
the bandwidth. With the C extension PC can sit at any 2-byte
boundary and a 32-bit word can hold up to two compressed
instructions, so the unit has to:

  * decouple the imem-fetch rate from the retire rate (compressed
    code retires twice per word; uncompressed code retires once
    per word);
  * tolerate the 1-cycle sync-read latency between @pcFetch@
    update and @imemData@ arrival without losing any words;
  * stitch a 32-bit uncompressed instruction together when its
    first half lands at @[31:16]@ of one word and its second
    half at @[15:0]@ of the next.

== Architecture

A 2-deep fetch FIFO sits between the imem read port and the
realigner state machine.

@
  pcFetch ──► imem ──► imemData ──► (push?)──► [FIFO[0], FIFO[1]] ──► realigner ──► IF\/ID
                                                            ▲
                                                            └─ pop on word-completion
@

  * __FIFO push__: when @inFlight@ — the registered \"a fetch I
    issued last cycle is returning data this cycle\" bit — is
    @True@ and there's room in the FIFO. With sync-read BRAM
    there's exactly one outstanding fetch in flight at a time
    after a successful issue; the credit-based @pcFetchAdvance@
    gating below guarantees the FIFO always has room when an
    in-flight fetch returns.
  * __FIFO pop__: when the realigner finishes a 32-bit word.
    For uncompressed retires, that's every emit (the word is one
    instruction). For compressed-at-offset-0 retires, no pop
    yet — the upper half is still in the same word. For
    compressed-at-offset-2 retires, pop. For uncompressed-at-
    offset-2 stitches, pop on the latch cycle (the only piece
    we still need from this word is the latched high half — the
    word itself is dead).
  * __pcFetch advance__ (= issue a new fetch this cycle) is
    gated by a credit-based check:

@
  advance = inFlight + (fifoCount - pop) <= 1
@

    The invariant @inFlight + fifoCount <= 2@ ensures the FIFO
    can always accept the imemData arriving from any in-flight
    fetch — no word is ever lost.

== Realigner state machine

Two registers track the cross-word state:

  * @wordOffset :: Bool@ — within the FIFO head's 32-bit word,
    is the next instruction at offset 0 (low half) or offset 2
    (high half)?
  * @holdHi :: Maybe (BitVector 16, BitVector 32)@ — when an
    uncompressed (32-bit) instruction starts at offset 2 of one
    word, its low half lives in the next word. We latch the
    high half + that instruction's start PC and complete the
    stitch when the next FIFO entry becomes head.

Both clear on flush (branch redirect / trap target). On flush
the realigner state is rebuilt from @wordOffset := target[1]@
(low bit of target's halfword index) and @holdHi := Nothing@.

== Why this is robust

Sustained all-compressed retire rate matches sustained
all-uncompressed retire rate: 1 instruction per cycle. The FIFO
absorbs the half-rate fetch traffic that compressed code
generates (one new word per two retires) without wasting cycles.
Mixed code self-balances: the FIFO fills when the realigner
slows down, drains when it speeds up.

The 1-cycle sync-read latency that doomed the earlier
combinational realigner attempt is hidden behind the FIFO —
@pcFetch@ can advance speculatively because the credit logic
guarantees there's always a slot for the result.
-}
module Riski5.Core.IFetch (
  -- * Public types
  IFetchOut (..),

  -- * Step functions (pure, easily testable)
  realignerStep,
) where

import Clash.Prelude hiding (not, (!!), (&&), (||))
import Riski5.Compressed (expandCompressed, isCompressedHalf)

-- | One realigner-step output.
data IFetchOut = IFetchOut
  { ifoInstr :: !(BitVector 32)
  -- ^ Expanded 32-bit instruction word presented to the decoder.
  , ifoPc :: !(BitVector 32)
  -- ^ Start PC of the emitted instruction (2-byte aligned).
  , ifoPcNext :: !(BitVector 32)
  -- ^ Post-instruction PC = ifoPc + 2 for compressed, + 4 for
  -- uncompressed (or stitched). Drives the IF\/ID @ifPcNext@
  -- field that the X stage's @pcN@ argument follows.
  , ifoValid :: !Bool
  -- ^ True if this is a real retire; False on bubble cycles
  -- (FIFO empty, post-flush gap, uncompressed-at-offset-2
  -- latch cycle).
  , ifoPop :: !Bool
  -- ^ Pop the FIFO head at edge.
  , ifoWordOffsetNext :: !Bool
  -- ^ Next-cycle 'wordOffset' the realigner state should hold.
  , ifoHoldHiNext :: !(Maybe (BitVector 16, BitVector 32))
  -- ^ Next-cycle 'holdHi' the realigner state should hold.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- |
Pure realigner step. Given current state and the FIFO head plus
its PC, produce the emit + state-transition bundle. Doesn't deal
with FIFO empty / fetch-in-flight; the caller wraps this step
with bubble emits when the FIFO has nothing for the realigner to
consume.

Sub-cases:

  * @holdHi = Just (h, hPc)@ — previous cycle latched the high
    half of an uncompressed instruction starting at offset 2 of
    the previous word. This cycle's FIFO head holds the next
    word; its low half completes the 32-bit instruction. Emit
    @lo ++# h@ at PC @hPc@. Pop the previous word? — no, by the
    time we get here the previous word has already been popped
    (during the latch cycle); the head is the new word, and we
    don't pop it because we're now consuming offset 2 of it.
  * @hold = Nothing@, @offset = 0@: take @lo = head[15:0]@. If
    compressed, expand and emit, transition to @offset = 1@,
    don't pop. If uncompressed, emit @head@ as the full
    instruction, transition to @offset = 0@, pop.
  * @hold = Nothing@, @offset = 2@: take @hi = head[31:16]@. If
    compressed, expand and emit, transition to @offset = 0@,
    pop. If uncompressed, latch @hi@ + (PC + 2), emit a bubble,
    transition to @offset = 0@ with @hold@ set, pop (we're done
    with this word's contents).
-}
realignerStep ::
  -- | wordOffset (False = offset 0, True = offset 2)
  Bool ->
  -- | holdHi
  Maybe (BitVector 16, BitVector 32) ->
  -- | FIFO head: 32-bit fetched word
  BitVector 32 ->
  -- | FIFO head's 4-aligned PC
  BitVector 32 ->
  IFetchOut
realignerStep wordOffset hold word pc = case hold of
  Just (h, hPc) ->
    -- Stitch resolution: previous cycle latched the high half;
    -- this cycle's word's low half completes the 32-bit
    -- instruction. We're now at offset 2 of the new word for
    -- the next retire.
    let lo16 = slice d15 d0 word :: BitVector 16
        stitched = lo16 ++# h
     in IFetchOut
          { ifoInstr = stitched
          , ifoPc = hPc
          , ifoPcNext = hPc + 4
          , ifoValid = True
          , ifoPop = False
          , ifoWordOffsetNext = True
          , ifoHoldHiNext = Nothing
          }
  Nothing -> case wordOffset of
    False ->
      let lo16 = slice d15 d0 word :: BitVector 16
       in if isCompressedHalf lo16
            then
              let inst = case expandCompressed lo16 of
                    Just w -> w
                    Nothing -> 0 -- decode = Nothing → trap
               in IFetchOut
                    { ifoInstr = inst
                    , ifoPc = pc
                    , ifoPcNext = pc + 2
                    , ifoValid = True
                    , ifoPop = False
                    , ifoWordOffsetNext = True
                    , ifoHoldHiNext = Nothing
                    }
            else
              IFetchOut
                { ifoInstr = word
                , ifoPc = pc
                , ifoPcNext = pc + 4
                , ifoValid = True
                , ifoPop = True
                , ifoWordOffsetNext = False
                , ifoHoldHiNext = Nothing
                }
    True ->
      let hi16 = slice d31 d16 word :: BitVector 16
          hiPc = pc + 2
       in if isCompressedHalf hi16
            then
              let inst = case expandCompressed hi16 of
                    Just w -> w
                    Nothing -> 0
               in IFetchOut
                    { ifoInstr = inst
                    , ifoPc = hiPc
                    , ifoPcNext = hiPc + 2
                    , ifoValid = True
                    , ifoPop = True
                    , ifoWordOffsetNext = False
                    , ifoHoldHiNext = Nothing
                    }
            else
              -- Uncompressed at offset 2: latch hi half, bubble
              -- emit, pop this word (done with it). Stitch
              -- completes next cycle when the new head's lo half
              -- arrives.
              IFetchOut
                { ifoInstr = 0
                , ifoPc = hiPc
                , ifoPcNext = hiPc + 4
                , ifoValid = False
                , ifoPop = True
                , ifoWordOffsetNext = False
                , ifoHoldHiNext = Just (hi16, hiPc)
                }

