-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : HelloSdramDataStress
Description : SDRAM data-only stress (PC stays in BRAM).

Bisecting twin of 'HelloSdramStress'. Same workload — write a
per-iteration value to 4 SDRAM addresses across 4 banks, read
each back, print @.@ per clean iter / @F@ per failure — but the
loop runs entirely from BRAM, so the IF stage only ever fetches
from BRAM. Use to disambiguate "SDRAM data path is broken" from
"the SDRAM arbiter / fetch+data multiplex inside Riski5.Soc is
broken".

  * If __this__ passes 256 / 256 but 'HelloSdramStress' fails
    immediately (which is what we observe on commit 74d9662
    silicon), the SDRAM arbiter (`sdramOwnerS` /
    `sdramSelArbS` / `sdramAddrArbS` in @Riski5.Soc@) is the
    culprit — confirms task #17 hypothesis.
  * If __this__ also fails, the bug is in the SDRAM data path
    itself (the `Riski5.Sdram` adapter or the `SdrController`
    behaviour for core-issued writes), separate from any IF /
    data multiplexing.

The variant build sets @enableSdramFetch=False@ so the SoC
takes the cheaper BRAM-only fetch wiring (no SDRAM arbiter
instantiated for fetch traffic), making the test as clean a
data-path probe as possible.
-}
module HelloSdramDataStress (
  helloSdramDataStressFirmware,
  helloSdramDataStressFirmwareWords,
) where

import Clash.Prelude (BitVector)
import Data.Either qualified as DE
import Riski5.Asm
import Riski5.ISA
import Prelude qualified as P

helloSdramDataStressFirmware :: Asm ()
helloSdramDataStressFirmware = do
  -- UART
  li tUart 0x10000000
  -- 4 data bases — each in a different SDRAM bank (2 MB stride)
  li tA 0x80100000
  li tB 0x80300000
  li tC 0x80500000
  li tD 0x80700000
  -- Iteration max
  li tMax 256
  -- Iteration counter
  addi tIter x0 0
  -- Pattern base
  li tPat 0x12340000

  -- 'B' to confirm BRAM exec + UART are alive.
  addi tTmp x0 0x42
  sw tUart tTmp 0

  failL <- labelUnplaced
  failAL <- labelUnplaced
  failBL <- labelUnplaced
  failCL <- labelUnplaced
  failDL <- labelUnplaced

  loopL <- label

  xor_ tValue tPat tIter

  sw tA tValue 0
  sw tB tValue 0
  sw tC tValue 0
  sw tD tValue 0

  lw tRead tA 0
  bne tRead tValue failAL
  lw tRead tB 0
  bne tRead tValue failBL
  lw tRead tC 0
  bne tRead tValue failCL
  lw tRead tD 0
  bne tRead tValue failDL

  addi tTmp x0 0x2E -- '.'
  sw tUart tTmp 0

  addi tIter tIter 1
  blt tIter tMax loopL

  -- Done
  addi tTmp x0 0x44 -- 'D'
  sw tUart tTmp 0
  doneL <- label
  j doneL

  placeAt failAL
  addi tTmp x0 0x41 -- 'A'
  sw tUart tTmp 0
  j failL
  placeAt failBL
  addi tTmp x0 0x42 -- 'B'
  sw tUart tTmp 0
  j failL
  placeAt failCL
  addi tTmp x0 0x43 -- 'C'
  sw tUart tTmp 0
  j failL
  placeAt failDL
  addi tTmp x0 0x44 -- 'D'
  sw tUart tTmp 0
  j failL

  placeAt failL
  addi tTmp x0 0x46 -- 'F'
  sw tUart tTmp 0
  -- Dump expected then actual (LE bytes).
  sw tUart tValue 0
  srli tTmp tValue 8
  sw tUart tTmp 0
  srli tTmp tValue 16
  sw tUart tTmp 0
  srli tTmp tValue 24
  sw tUart tTmp 0
  sw tUart tRead 0
  srli tTmp tRead 8
  sw tUart tTmp 0
  srli tTmp tRead 16
  sw tUart tTmp 0
  srli tTmp tRead 24
  sw tUart tTmp 0
  failHaltL <- label
  j failHaltL
 where
  tUart = x10
  tA = x11
  tB = x12
  tC = x13
  tD = x14
  tMax = x15
  tIter = x16
  tPat = x17
  tValue = x18
  tRead = x19
  tTmp = x20

helloSdramDataStressFirmwareWords :: [BitVector 32]
helloSdramDataStressFirmwareWords =
  DE.fromRight
    (P.error "helloSdramDataStressFirmware failed to assemble")
    (assemble helloSdramDataStressFirmware)
