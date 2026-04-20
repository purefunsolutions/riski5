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
Module      : Riski5.Soc
Description : Riski5 SoC top — core + memory + peripherals on a bus.

Wires 'Riski5.Core.core' up to its memory map: a pair of BRAM
instances (imem + dmem) plus the JTAG UART, LCD, and GPIO
peripherals, all selected by a trivial address decoder derived
from 'Riski5.MemMap.slaveOf'.

Phase-1 SoC layout:

@
  ┌───────────┐
  │   Core    │◀── imemData ── Bram (program)
  │           │◀── dmemRData ─┬─ Bram (data)
  │           │── pc ─────────┘
  │           │── dmemAddr ──────┬── bus decoder
  │           │── dmemWdata/be ──┤
  │           │── dmemRen ───────┘       │
  └───────────┘                          │
                 ┌───────────────────────┤
                 │          │            │
                 ▼          ▼            ▼
             JtagUart    Lcd          Gpio
                 │          │            │
                 ▼          ▼            ▼
              TX byte    LCD pins      LEDR / LEDG
@

The imem is a parameterised 'Vec' so tests can load different
programs; the data BRAM starts zero-initialised. On real hardware,
Quartus's @.mif@ loader populates the imem at power-on and the
core simply executes from address 0.
-}
module Riski5.Soc (
  soc,
  SocIn (..),
  SocOut (..),
) where

import Clash.Prelude hiding (And, Xor, not)
import Clash.Prelude qualified as CP
import Riski5.Bram (bram)
import Riski5.Core (core)
import Riski5.Gpio (GpioIn (..), GpioOut (..), gpio)
import Riski5.JtagUart (jtagUartSim)
import Riski5.Lcd (LcdPins (..), lcd)
import Riski5.MemMap (SlaveId (..), slaveOf)
import Riski5.Sram (SramPins (..), sram)

{- |
Inputs the SoC reads from the board.
-}
data SocIn = SocIn
  { siSwitches :: BitVector 18
  , siKeys :: BitVector 4
  , siSramDqIn :: BitVector 16
  -- ^ What the off-chip SRAM is currently driving on @SRAM_DQ@.
  -- Read combinationally on the cycle the controller is reading
  -- (i.e. @SRAM_OE_N == 0@); ignored otherwise. In simulation,
  -- the test harness wraps the SoC with 'Riski5.Sram.sramSim' to
  -- provide a model of the off-chip chip.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- |
Outputs the SoC drives to the board (and, for the UART, to the
simulation harness). In real hardware, @soUartTx@ is latched into
the Altera JTAG UART IP instead; the 'Maybe' surface here is just
an observability channel for Clash simulation.
-}
data SocOut = SocOut
  { soLedR :: BitVector 18
  , soLedG :: BitVector 9
  , soLcdPins :: LcdPins
  , soSramPins :: SramPins
  , soUartTx :: Maybe (BitVector 8)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- |
SoC top. Parameterised on the program vector (size @p@) and a
blank data RAM of size @d@. For phase-1 tests both default to 128
words (512 bytes); real hardware picks larger sizes in the SoC
instantiation inside @app\/Top.hs@.
-}
soc ::
  forall dom p d.
  ( HiddenClockResetEnable dom
  , KnownNat p
  , 1 <= p
  , KnownNat d
  , 1 <= d
  ) =>
  -- | initial imem contents (RV32I machine-code words)
  Vec p (BitVector 32) ->
  -- | initial dmem contents (typically all zero)
  Vec d (BitVector 32) ->
  -- | board-level inputs (switches, keys)
  Signal dom SocIn ->
  Signal dom SocOut
soc progInit dataInit inS = outS
 where
  -- ----- Core instance -----------------------------------------
  -- The stall signal comes from the bus mux: any slave that needs
  -- multi-cycle service can deassert ready and the core freezes
  -- until the data settles.
  (pcS, dAddrS, dWdataS, dBeS, dRenS, _wbS) =
    core imemDataS dmemRdataS stallS

  -- ----- Instruction memory ------------------------------------
  imemDataS :: Signal dom (BitVector 32)
  imemDataS =
    bram progInit pcS (CP.pure 0) (CP.pure 0)

  -- ----- Data memory (slave at 0x0000_0000 — shares addr space
  -- with imem for simplicity; programs pick a base above the code) --
  bramRdataS :: Signal dom (BitVector 32)
  bramRdataS = bram dataInit dAddrS dWdataSForBram dBeSForBram

  -- Gate the data-memory write signal so it only fires when the
  -- bus decoder has selected the BRAM slave. Same trick for the
  -- other slaves below.
  bramSelS = (\a -> slaveOf a == SlaveBram) <$> dAddrS
  dWdataSForBram = dWdataS
  dBeSForBram =
    (\sel be -> if sel then be else 0) <$> bramSelS <*> dBeS

  -- ----- JTAG UART ---------------------------------------------
  jtagSelS = (\a -> slaveOf a == SlaveJtagUart) <$> dAddrS
  (uartRdataS, uartTxS) =
    jtagUartSim jtagSelS dAddrS dWdataS dBeS dRenS

  -- ----- LCD ---------------------------------------------------
  lcdSelS = (\a -> slaveOf a == SlaveLcd) <$> dAddrS
  (lcdRdataS, lcdPinsS) =
    lcd lcdSelS dAddrS dWdataS dBeS dRenS

  -- ----- GPIO --------------------------------------------------
  gpioSelS = (\a -> slaveOf a == SlaveGpio) <$> dAddrS
  gpInS = (\SocIn {..} -> GpioIn {gpiSwitches = siSwitches, gpiKeys = siKeys}) <$> inS
  (gpioRdataS, gpOutS) =
    gpio gpioSelS dAddrS dWdataS dBeS dRenS gpInS

  -- ----- SRAM (off-chip 512 KB IS61LV25616-class) --------------
  -- Pure half-word controller — see 'Riski5.Sram' for the
  -- pipelineless 16-bit-only contract (T31a tracks 32-bit access).
  -- 'sramReadyS' is False on the first cycle of a freshly-issued
  -- read; the core stalls via 'stallS' until it goes True.
  sramSelS = (\a -> slaveOf a == SlaveSram) <$> dAddrS
  sramDqInS = siSramDqIn <$> inS
  (sramRdataS, sramPinsS, sramReadyS) =
    sram sramSelS dAddrS dWdataS dBeS dRenS sramDqInS

  -- Bus-level stall: any selected slave can deassert ready. Today
  -- only SRAM does so; BRAM / GPIO / LCD / UART are single-cycle.
  stallS =
    ( \s sramRdy ->
        case s of
          SlaveSram -> not sramRdy
          _ -> False
    )
      <$> (slaveOf <$> dAddrS)
      <*> sramReadyS

  -- ----- Bus read mux ------------------------------------------
  dmemRdataS :: Signal dom (BitVector 32)
  dmemRdataS =
    ( \s bR uR lR gR sR ->
        case s of
          SlaveBram -> bR
          SlaveJtagUart -> uR
          SlaveLcd -> lR
          SlaveGpio -> gR
          SlaveSram -> sR
          _ -> 0
    )
      <$> (slaveOf <$> dAddrS)
      <*> bramRdataS
      <*> uartRdataS
      <*> lcdRdataS
      <*> gpioRdataS
      <*> sramRdataS

  -- ----- Bundle outputs ----------------------------------------
  outS =
    ( \gpo lcdPins sramPins uartTx ->
        SocOut
          { soLedR = gpoLedR gpo
          , soLedG = gpoLedG gpo
          , soLcdPins = lcdPins
          , soSramPins = sramPins
          , soUartTx = uartTx
          }
    )
      <$> gpOutS
      <*> lcdPinsS
      <*> sramPinsS
      <*> uartTxS
