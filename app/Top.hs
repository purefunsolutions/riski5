-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Top
Description : DE2 top entity — Clash → Verilog → Quartus → .sof.

Synthesises into a Verilog module named @riski5@ that matches the
port names in @pkgs/riski5-core/Riski5.qsf@. JTAG UART output is
intentionally dropped at this boundary — real hardware needs the
Altera JTAG UART IP instead of our Clash-side 'jtagUartSim', and
that integration lands with the Quartus flow (T17). Until then
the first hardware run is \"core is alive\" via LEDR blinking.

Baked-in firmware: a six-instruction counter that increments x2
every cycle, right-shifts by 20 for human-visible speed, and
writes the upper bits to the LEDR MMIO register. At 50 MHz the
low LED toggles roughly 12 times per second — clean visual
confirmation that fetch, decode, execute, and GPIO MMIO access
all work end-to-end.
-}
module Top (
  topEntity,
) where

import Clash.Annotations.TH (makeTopEntityWithName)
import Clash.Prelude
import Clash.Sized.Vector qualified as V
import Data.Either qualified as DE
import Riski5.Asm (
  Asm,
  addi,
  assemble,
  j,
  label,
  lui,
 )
import Riski5.Asm qualified as Asm
import Riski5.ISA (Instr (..), x0, x1, x2, x3)
import Riski5.Lcd (LcdPins (..))
import Riski5.Soc (SocIn (..), SocOut (..), soc)
import Prelude qualified as P

-- * Clock domain --------------------------------------------------

{- | 50 MHz clock domain matching DE2's @CLOCK_50@; async active-LOW
reset matching @KEY0@'s electrical convention.
-}
createDomain
  vSystem
    { vName = "Dom50"
    , vPeriod = 20000
    , vResetKind = Asynchronous
    , vResetPolarity = ActiveLow
    }

-- * Firmware --------------------------------------------------------

{- |
Tight six-instruction counter that drives LEDR from an upper slice
of a counter register. Starts by building the LEDR MMIO address in
@x1@ (the GPIO base is 0x1000_0020), then loops: increment @x2@,
shift right by 20 bits, store to LEDR.
-}
counterFirmware :: Asm ()
counterFirmware = do
  lui x1 0x10000
  addi x1 x1 0x20
  loopL <- label
  addi x2 x2 1
  Asm.srli x3 x2 20
  Asm.emit (Sw x1 x3 0)
  j loopL

firmwareWords :: [BitVector 32]
firmwareWords =
  DE.fromRight
    (P.error "counterFirmware failed to assemble")
    (assemble counterFirmware)

-- | 64-word (256-byte) instruction memory; remainder is NOP padding.
type ProgSize = 64

-- | 64-word data memory. Phase-1B first bring-up doesn't touch it.
type DataSize = 64

firmwareImage :: Vec ProgSize (BitVector 32)
firmwareImage =
  V.unsafeFromList
    (P.take 64 (firmwareWords P.++ P.repeat 0x0000_0013))

dataImage :: Vec DataSize (BitVector 32)
dataImage = repeat 0

-- * Top entity -----------------------------------------------------

{- |
DE2 top-level entity.
-}
topEntity ::
  "CLOCK_50" ::: Clock Dom50 ->
  "KEY0" ::: Reset Dom50 ->
  "KEY" ::: Signal Dom50 (BitVector 4) ->
  "SW" ::: Signal Dom50 (BitVector 18) ->
  ""
    ::: ( "LEDR" ::: Signal Dom50 (BitVector 18)
        , "LEDG" ::: Signal Dom50 (BitVector 9)
        , "LCD_DATA" ::: Signal Dom50 (BitVector 8)
        , "LCD_RS" ::: Signal Dom50 Bit
        , "LCD_RW" ::: Signal Dom50 Bit
        , "LCD_EN" ::: Signal Dom50 Bit
        , "LCD_ON" ::: Signal Dom50 Bit
        , "LCD_BLON" ::: Signal Dom50 Bit
        )
topEntity clk rst keyS swS =
  withClockResetEnable clk rst enableGen
    $ let inS = SocIn <$> swS <*> keyS
          outS = soc firmwareImage dataImage inS
          ledrS = soLedR <$> outS
          ledgS = soLedG <$> outS
          lcdDataS = lcdData . soLcdPins <$> outS
          lcdRsS = lcdRs . soLcdPins <$> outS
          lcdRwS = lcdRw . soLcdPins <$> outS
          lcdEnS = lcdE . soLcdPins <$> outS
          lcdOnS = pure high
          lcdBlonS = pure high
       in (ledrS, ledgS, lcdDataS, lcdRsS, lcdRwS, lcdEnS, lcdOnS, lcdBlonS)

{- | Exported Clash-usable top-entity annotation so
@clash --verilog Top.hs@ emits a module named @riski5@ with the
port names declared above.
-}
makeTopEntityWithName 'topEntity "riski5"
