-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : CoreMark
Description : CoreMark firmware wrapper — baked-in image for riski5-core.

Exposes 'coreMarkFirmwareWords' — the list of 32-bit RV32IM machine-
code words that the CoreMark bitstream variant bakes into imem.
'app/Top.hs' (or a future CoreMark-specific top) picks this list up
via 'Clash.Prelude.listToVecTH' and hands it to @soc@ as 'progInit',
which flows into both the fetch-port blockRam and the bus-read-port
blockRam added in CM-3.

The actual CoreMark machine code lives outside Haskell — it's the
ELF produced by the C cross-compile at
'pkgs/coremark/package.nix' (CM-1) running against the platform
port at 'firmware/phase2/coremark-port/' (CM-2). Baking those bytes
into this module is CM-4's scope; until then, this file returns a
stub (4096 NOPs) so:

  * @cabal build@ + @cabal test@ keep working without a Nix build
    (the stub compiles, the existing test suite doesn't reference
    CoreMark).
  * The module surface is fixed — CM-4 just swaps the body, nothing
    downstream re-plumbs.
  * The stub is exactly @ProgSize@ words (4096), so when CM-4 does
    land the real image, 'listToVecTH' still produces a Vec of the
    right size without separate padding logic.

CM-4 will replace 'coreMarkFirmwareWords' with a Template-Haskell
splice that reads the coremark.bin artefact (via a Nix-overlaid
source path) and unpacks it into @[BitVector 32]@.
-}
module CoreMark (
  coreMarkFirmwareWords,
) where

import Clash.Prelude (BitVector)
import Prelude qualified as P

-- | Stub image: 4096 NOPs. CM-4 replaces this definition with the
-- real cross-compiled CoreMark bytes.
coreMarkFirmwareWords :: [BitVector 32]
coreMarkFirmwareWords = P.replicate 4096 nop
 where
  -- RISC-V canonical NOP = @addi x0, x0, 0@ = 0x0000_0013.
  nop :: BitVector 32
  nop = 0x0000_0013
