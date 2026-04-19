-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Riski5.Bram
Description : Word-addressable async-read BRAM with byte-enable writes.

For the pipelineless phase-1 core this wraps an **async-read**
register-array memory (see 'Riski5.Regfile' for the same rationale
— the core can only absorb one cycle of memory latency and that
slot goes to the imem fetch). Reads observe writes on the same
cycle; writes commit on the next clock edge via the normal
register-next function.

Byte-enable writes implement the store-data-shifting already done
by 'Riski5.Core' / 'Riski5.Core.shiftStoreData': the @wdata@ input
is 32 bits wide with data already in the correct byte lane, and
the four-bit @be@ selects which lanes actually get written.

On hardware, this costs @N@ × 32 flip-flops. Worth swapping for
`blockRam` once the core can tolerate a second cycle of latency
(pipeline phase). Noted alongside the regfile in CLAUDE.md's
hardware-targeting rules.
-}
module Riski5.Bram (
  bram,
) where

import Clash.Prelude
import Clash.Prelude qualified as CP

{- | Word-addressable async-read RAM with byte-enable writes.

@bram initContents addr wdata be@ returns the 32-bit word currently
at byte-address @addr@ (word-aligned — the low two bits of @addr@
are ignored for read selection). When any bit of @be@ is set, the
corresponding byte lanes of @wdata@ are latched into the memory on
the next clock edge.

@n@ is the number of 32-bit words. Use 'Clash.Sized.Vector.repeat'
or a constructed 'Vec' for @initContents@; firmware tools will emit
these in T17 (Nix derivation) and T18 (hello-world firmware).
-}
bram ::
  forall dom n.
  (HiddenClockResetEnable dom, KnownNat n, 1 <= n) =>
  -- | initial word contents, indexed by word offset
  Vec n (BitVector 32) ->
  -- | byte-granular address (low 2 bits ignored)
  Signal dom (BitVector 32) ->
  -- | write data (already shifted into the correct lane by core)
  Signal dom (BitVector 32) ->
  -- | per-byte write enable; 0 = no write this cycle
  Signal dom (BitVector 4) ->
  -- | read data (same-cycle as address)
  Signal dom (BitVector 32)
bram initContents addrS wdataS beS = rdata
 where
  mem :: Signal dom (Vec n (BitVector 32))
  mem = register initContents (applyWrite <$> mem <*> addrS <*> wdataS <*> beS)

  rdata :: Signal dom (BitVector 32)
  rdata = readMem <$> mem <*> addrS

  -- Combinational read of the current memory state at the given
  -- address. Low two bits of the address select a byte lane but
  -- the core already handled byte extraction — the BRAM itself
  -- only understands words.
  readMem :: Vec n (BitVector 32) -> BitVector 32 -> BitVector 32
  readMem m addr = m CP.!! wordIndex addr

  -- Apply a byte-enabled write to the current memory state.
  applyWrite ::
    Vec n (BitVector 32) ->
    BitVector 32 ->
    BitVector 32 ->
    BitVector 4 ->
    Vec n (BitVector 32)
  applyWrite m addr wdata be
    | be == 0 = m
    | otherwise =
        let idx = wordIndex addr
            old = m CP.!! idx
            new = mergeBytes old wdata be
         in replace idx new m

  -- \|
  -- Strip the low two bits of the byte-address and wrap modulo the
  -- memory size. Out-of-range addresses wrap rather than trap; the
  -- bus decoder in 'Riski5.MemMap' should prevent them from reaching
  -- us in practice.
  wordIndex :: BitVector 32 -> Index n
  wordIndex addr =
    let wordOff :: BitVector 32
        wordOff = addr `shiftR` 2
     in fromIntegral (unpack wordOff :: Unsigned 32)

-- | Merge @new@ into @old@ byte-by-byte based on the byte-enable mask.
mergeBytes :: BitVector 32 -> BitVector 32 -> BitVector 4 -> BitVector 32
mergeBytes old new be = b3 ++# b2 ++# b1 ++# b0
 where
  pickByte :: Bit -> BitVector 8 -> BitVector 8 -> BitVector 8
  pickByte b o n = if b == high then n else o

  b0 = pickByte (slice d0 d0 be ! (0 :: Int)) (slice d7 d0 old) (slice d7 d0 new)
  b1 = pickByte (slice d1 d1 be ! (0 :: Int)) (slice d15 d8 old) (slice d15 d8 new)
  b2 = pickByte (slice d2 d2 be ! (0 :: Int)) (slice d23 d16 old) (slice d23 d16 new)
  b3 = pickByte (slice d3 d3 be ! (0 :: Int)) (slice d31 d24 old) (slice d31 d24 new)
