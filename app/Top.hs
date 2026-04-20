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
import Clash.Intel.ClockGen (altpllSync)
import Clash.Prelude
import Clash.Explicit.Signal (unsafeSynchronizer)
import Hello (helloFirmwareWords)
import Riski5.Lcd (LcdPins (..))
import Riski5.Soc (SocIn (..), SocOut (..), soc)
import Prelude qualified as P

-- * Clock domain --------------------------------------------------

{- | 50 MHz clock domain matching DE2's @CLOCK_50@ oscillator; async
active-LOW reset matching @KEY0@'s electrical convention. Used only
to drive the PLL — no logic runs on this domain.
-}
createDomain
  vSystem
    { vName = "Dom50"
    , vPeriod = 20000
    , vResetKind = Asynchronous
    , vResetPolarity = ActiveLow
    }

{- | 40 MHz core domain — derived from @CLOCK_50@ via an Altera
ALTPLL (50 × 4 / 5 = 40 MHz). 40 MHz sits comfortably under the
fit-report Fmax of 41.53 MHz, so the design closes timing with
margin instead of running 20 % over the slow corner.
-}
createDomain
  vSystem
    { vName = "Dom40"
    , vPeriod = 25000
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
    ::: ( "LEDR" ::: Signal Dom40 (BitVector 18)
        , "LEDG" ::: Signal Dom40 (BitVector 9)
        , "LCD_DATA" ::: Signal Dom40 (BitVector 8)
        , "LCD_RS" ::: Signal Dom40 Bit
        , "LCD_RW" ::: Signal Dom40 Bit
        , "LCD_EN" ::: Signal Dom40 Bit
        , "LCD_ON" ::: Signal Dom40 Bit
        , "LCD_BLON" ::: Signal Dom40 Bit
        )
topEntity clk50 rst50 keyS50 swS50 =
  let -- Derive the 40 MHz core clock + reset from the 50 MHz input
      -- via Altera ALTPLL. The reset is held until the PLL locks.
      (clk40, rst40) :: (Clock Dom40, Reset Dom40) =
        altpllSync clk50 rst50
      -- Cross switches and keys from Dom50 → Dom40. They're sampled
      -- from physical inputs that change at human speeds, so a
      -- bare 'unsafeSynchronizer' is fine — the metastability risk
      -- on a single mechanical-switch read is negligible. Promote
      -- to a proper double-FF synchronizer if we ever sample these
      -- at full clock rate for time-sensitive logic.
      keyS = unsafeSynchronizer clk50 clk40 keyS50
      swS = unsafeSynchronizer clk50 clk40 swS50
   in withClockResetEnable clk40 rst40 enableGen
        $ let inS = SocIn <$> swS <*> keyS
              outS = soc firmwareImage dataImage inS
              ledrS = soLedR <$> outS
              ledgS = soLedG <$> outS
              lcdDataS = lcdData . soLcdPins <$> outS
              lcdRsS = lcdRs . soLcdPins <$> outS
              lcdRwS = lcdRw . soLcdPins <$> outS
              lcdEnS = lcdE . soLcdPins <$> outS
              lcdOnS = pure high
              -- LCD_BLON polarity on DE2 rev unclear from the user
              -- manual; first hardware run with HIGH gave a backlit-
              -- off LCD, so we drive LOW here. If that's wrong the
              -- backlight just stays off — LCD power (LCD_ON) is
              -- independent.
              lcdBlonS = pure low
           in (ledrS, ledgS, lcdDataS, lcdRsS, lcdRwS, lcdEnS, lcdOnS, lcdBlonS)

{- | Exported Clash-usable top-entity annotation so
@clash --verilog Top.hs@ emits a module named @riski5@ with the
port names declared above.
-}
makeTopEntityWithName 'topEntity "riski5"
