-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
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
import Hello (helloFirmwareWords)
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

{- | 256-word (1 KB) instruction memory — enough for the Hello
firmware plus headroom. Unused words are NOPs.
-}
type ProgSize = 256

-- | 64-word data memory. Phase-1B Hello firmware doesn't touch it.
type DataSize = 64

firmwareImage :: Vec ProgSize (BitVector 32)
firmwareImage =
  $(listToVecTH (P.take 256 (helloFirmwareWords P.++ P.repeat (0x0000_0013 :: BitVector 32))))

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
