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
Module      : Riski5.MemMap
Description : Single source of truth for riski5's physical address map.

Decoded on the upper 4 bits of the 32-bit address. Every address
constant anywhere else in the code (bus decoder, reset PC,
firmware MMIO accesses, tests) imports from here so changing the
map is a one-line edit.

See @CLAUDE.md@ for the human-readable table. Summary:

@
  0x0000_0000 – 0x0000_0FFF   BRAM       (4 KB)
  0x1000_0000 – 0x1000_000F   JTAG UART  (16 B)
  0x1000_0020 – 0x1000_003F   GPIO       (32 B)
  0x1000_0040 – 0x1000_005F   LCD        (32 B)
  0x1000_0060 – 0x1000_009F   CLINT      (64 B, phase 2+)
  0x2000_0000 – 0x2007_FFFF   SRAM       (512 KB, phase 1C)
  0x8000_0000 – 0x807F_FFFF   SDRAM      (8 MB, phase 1D)
@
-}
module Riski5.MemMap (
  SlaveId (..),
  slaveOf,

  -- * Region bases (for firmware + tests)
  bramBase,
  jtagUartBase,
  gpioBase,
  lcdBase,
  clintBase,
  sramBase,
  sdramBase,

  -- * Reset configuration
  resetPc,
  defaultMtvecBase,
) where

import Clash.Prelude

{- | Which slave owns a given physical address. The bus decoder muxes
read data and write-enable based on this classification.
-}
data SlaveId
  = SlaveBram
  | SlaveJtagUart
  | SlaveGpio
  | SlaveLcd
  | SlaveClint
  | SlaveSram
  | SlaveSdram
  | {- | Address falls outside any decoded region — the core raises an
    access fault once T12's trap path gains bus-error support
    (phase 1 treats unmapped addresses as a silent no-op).
    -}
    SlaveNone
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- | Classify a 32-bit physical address into its owning slave.

The decoder fans out on the top 4 bits and (for peripheral
addresses) the next 4 bits below. Intentionally combinational:
Quartus maps it to a tiny 4-input LUT cone.
-}
slaveOf :: BitVector 32 -> SlaveId
slaveOf addr = case top4 of
  0x0 -> SlaveBram
  0x1 -> classifyPeripheral addr
  0x2 -> SlaveSram
  0x8 -> SlaveSdram
  _ -> SlaveNone
 where
  top4 :: BitVector 4
  top4 = slice d31 d28 addr

-- | Sub-decode the @0x1000_00xx@ peripheral window.
classifyPeripheral :: BitVector 32 -> SlaveId
classifyPeripheral addr = case slice d7 d0 addr of
  lo
    | lo < 0x10 -> SlaveJtagUart
    | lo < 0x40 -> SlaveGpio
    | lo < 0x60 -> SlaveLcd
    | lo < 0xA0 -> SlaveClint
    | otherwise -> SlaveNone

-- * Region bases --------------------------------------------------

bramBase :: BitVector 32
bramBase = 0x0000_0000

jtagUartBase :: BitVector 32
jtagUartBase = 0x1000_0000

gpioBase :: BitVector 32
gpioBase = 0x1000_0020

lcdBase :: BitVector 32
lcdBase = 0x1000_0040

clintBase :: BitVector 32
clintBase = 0x1000_0060

sramBase :: BitVector 32
sramBase = 0x2000_0000

sdramBase :: BitVector 32
sdramBase = 0x8000_0000

-- * Reset defaults ------------------------------------------------

-- | Where the CPU starts executing on reset.
resetPc :: BitVector 32
resetPc = bramBase

{- | Default @mtvec.base@ that firmware installs before enabling traps.
The trap handler stub lives at this offset in BRAM.
-}
defaultMtvecBase :: BitVector 32
defaultMtvecBase = 0x0000_0100
