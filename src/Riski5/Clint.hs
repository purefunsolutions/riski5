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
Module      : Riski5.Clint
Description : Core-Local Interrupt Controller — mtime + mtimecmp + mtip.

The riski5 CLINT, simplified for a single hart. Provides the minimum
needed for an OS-grade timer-interrupt source:

  * @mtime@ — a 64-bit free-running counter at the core clock.
    Wraps at @2 ^ 64@. Memory-mapped read / write (writes set
    a new value, useful for seeding from a wall-clock at boot).

  * @mtimecmp@ — a 64-bit compare register. When @mtime >=
    mtimecmp@, the CLINT raises its 'mtipS' output strobe. The
    hart's CSR file ('Riski5.CSR') latches that into @mip.MTIP@,
    which (when @mstatus.MIE && mie.MTIE@) fires a machine-timer
    interrupt the core's existing trap path consumes.

== Register layout — SiFive CLINT v0 (1-hart subset)

Memory-mapped at 'Riski5.MemMap.clintBase' = @0x0200_0000@. Layout
matches the SiFive CLINT exactly, so upstream Linux's
@drivers/clocksource/timer-riscv.c@ + @timer-clint.c@ recognise the
block via DT @compatible = "sifive,clint0"@:

@
  offset 0x0000 — msip[0]            (RW, low bit only)
  offset 0x4000 — mtimecmp[0][31:0]  (RW)
  offset 0x4004 — mtimecmp[0][63:32] (RW)
  offset 0xBFF8 — mtime[31:0]        (RW)
  offset 0xBFFC — mtime[63:32]       (RW)
@

The 64 KB CLINT window is sparse — only five 32-bit registers
are live; reads of unmapped offsets return 0 and writes are
ignored.

Writes commit on the next clock edge; the increment of @mtime@ also
happens on the clock edge, so a write that races a tick gets the
write's value rather than the incremented one (priority: write
wins).
-}
module Riski5.Clint (
  clint,
) where

import Clash.Prelude hiding ((&&))
import Riski5.MemMap (clintBase)

{- |
The CLINT block. @clint sel addr wdata be readEn@ returns
@(rdataS, mtipS)@.

  * @sel@ — slave-select asserted by the bus decoder for the CLINT
    address window (true on cycles when @addr@ is inside
    @clintBase..clintBase+0xFFFF@).
  * @addr@ / @wdata@ / @be@ / @readEn@ — the standard memory-bus
    fields the rest of the SoC slaves accept.
  * @rdataS@ — read data; word-aligned 32-bit slices of the CLINT
    registers (msip, mtimecmp low, mtimecmp high, mtime low, mtime
    high). Reads of unmapped offsets return zero.
  * @mtipS@ — combinational @mtime >= mtimecmp@. Wired into the
    core's CSR @mip.MTIP@ bit by 'Riski5.Soc'.

The @mtime@ counter increments every clock cycle unconditionally —
not gated on stalls or pipeline bubbles, matching the spec ("a
real-time counter that runs at a constant frequency"). For the
phase-2 single-clock-domain core this is just the core clock; once
phase 2D PLLs land, the counter can be re-clocked off a slower
bus-clock domain by switching the @register@ to a CDC FIFO at the
boundary.
-}
clint ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  -- | slave-select
  Signal dom Bool ->
  -- | address (byte-granular)
  Signal dom (BitVector 32) ->
  -- | write data
  Signal dom (BitVector 32) ->
  -- | byte-enable (any non-zero treated as a full-word write — the
  -- registers don't support sub-word granularity)
  Signal dom (BitVector 4) ->
  -- | read enable (currently unused; reads are always combinational)
  Signal dom Bool ->
  -- | @(rdata, mtip)@
  ( Signal dom (BitVector 32)
  , Signal dom Bool
  )
clint selS addrS wdataS beS _readEnS = (rdataS, mtipS)
 where
  -- 64-bit mtime — increments every clock cycle, with bus writes
  -- taking priority (low or high half independently).
  mtimeS :: Signal dom (BitVector 64)
  mtimeS = register 0 mtimeNextS

  mtimeNextS :: Signal dom (BitVector 64)
  mtimeNextS =
    ( \cur wrLo wrHi w ->
        let stepped = cur + 1
            -- Bus writes win over the natural increment.
            withLo = if wrLo then (slice d63 d32 stepped ++# w) else stepped
            withHi = if wrHi then (w ++# slice d31 d0 withLo) else withLo
         in withHi
    )
      <$> mtimeS
      <*> writeMtimeLoS
      <*> writeMtimeHiS
      <*> wdataS

  -- 64-bit mtimecmp — only changes via bus writes.
  mtimecmpS :: Signal dom (BitVector 64)
  mtimecmpS = register maxBound mtimecmpNextS

  mtimecmpNextS :: Signal dom (BitVector 64)
  mtimecmpNextS =
    ( \cur wrLo wrHi w ->
        let withLo = if wrLo then (slice d63 d32 cur ++# w) else cur
            withHi = if wrHi then (w ++# slice d31 d0 withLo) else withLo
         in withHi
    )
      <$> mtimecmpS
      <*> writeMtimecmpLoS
      <*> writeMtimecmpHiS
      <*> wdataS

  -- Software-interrupt-pending bit (msip[0] @ 0x0000). Reserved for
  -- phase 2C+ IPI work; reads / writes the low bit of the word at
  -- offset 0x0000.
  msipS :: Signal dom (BitVector 32)
  msipS = register 0 msipNextS
  msipNextS =
    ( \cur wr w -> if wr then 0 .|. (w .&. 1) else cur
    )
      <$> msipS
      <*> writeMsipS
      <*> wdataS

  -- Address-decoded write enables. Any non-zero be is treated as a
  -- write — the registers don't support partial-word updates.
  isWriteTo :: BitVector 32 -> Signal dom Bool
  isWriteTo off =
    (\s a be -> s && a == clintBase + off && be /= 0)
      <$> selS
      <*> addrS
      <*> beS

  -- SiFive CLINT layout (single-hart subset).
  writeMsipS = isWriteTo 0x0000
  writeMtimecmpLoS = isWriteTo 0x4000
  writeMtimecmpHiS = isWriteTo 0x4004
  writeMtimeLoS = isWriteTo 0xBFF8
  writeMtimeHiS = isWriteTo 0xBFFC

  -- Combinational reads. Reads of unmapped offsets return zero.
  rdataS :: Signal dom (BitVector 32)
  rdataS =
    ( \sel addr mt mtc msip ->
        if sel
          then case addr - clintBase of
            0x0000 -> msip
            0x4000 -> slice d31 d0 mtc
            0x4004 -> slice d63 d32 mtc
            0xBFF8 -> slice d31 d0 mt
            0xBFFC -> slice d63 d32 mt
            _ -> 0
          else 0
    )
      <$> selS
      <*> addrS
      <*> mtimeS
      <*> mtimecmpS
      <*> msipS

  -- Pending-interrupt strobe: combinational @mtime >= mtimecmp@.
  -- The CSR file's @mip.MTIP@ bit follows this signal.
  mtipS :: Signal dom Bool
  mtipS = (\mt mtc -> mt >= mtc) <$> mtimeS <*> mtimecmpS
