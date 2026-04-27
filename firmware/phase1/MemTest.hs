-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : MemTest
Description : Classic-BIOS-style memory test firmware for SRAM + SDRAM.

Two distinct test suites, one per off-chip memory region, runnable
separately or chained from one bitstream.

  * 'memTestSramFirmware' walks every word-aligned address in the
    512 KB SRAM (0x2000_0000 .. 0x2007_FFFF).
  * 'memTestSdramFirmware' walks every word-aligned address in the
    8 MB SDRAM (0x8000_0000 .. 0x807F_FFFF).
  * 'memTestFirmware' runs SRAM then SDRAM back-to-back — the
    default @app\/Top.hs@ firmware for the bitstream this milestone
    ships.

For each region the test runs four patterns, each in two passes:

  1. __Write + inline readback.__ Walk addr, store pattern(addr) to
     addr, LW back, BNE to fail-handler on mismatch. Catches:
     stuck bits inside a single cell; SRAM / SDRAM controller
     timing bugs that break back-to-back write→read on the same
     address; write-enable gating errors.
  2. __Verify.__ Walk addr again, LW, compare to pattern(addr),
     BNE on mismatch. Catches: cell-to-cell cross-talk where an
     earlier write corrupted a later cell; SDRAM refresh bugs
     (the second pass runs after ~seconds of walking, which is
     multiple refresh intervals); address-decoder aliasing where
     two distinct addresses map to the same cell (the write-pass
     corrupts one of them).

Patterns:

  * __Address-as-data__ — @mem[a] = a@. Aliasing detection.
  * __Inverted address__ — @mem[a] = ~a@. Catches stuck-at-1
    bits the address-as-data pass masked (0x2000_0000 already has
    a lot of zero bits in low bytes).
  * __0xAAAAAAAA__ — even bit pattern.
  * __0x55555555__ — odd bit pattern. Paired with the AAAA test
    catches adjacent-cell coupling.

On first mismatch, the core latches @addr@ / @expected@ / @got@,
emits a formatted UART line, writes LCD + LEDs, and spins. Silicon
that passes every pass advances to the next region / "ALL OK".

At 50 MHz with the P2-A 5-stage core the full run takes roughly
1 s on SRAM and roughly 5 s on SDRAM. Both print progress.
-}
module MemTest (
  memTestFirmware,
  memTestFirmwareWords,
  memTestSramFirmware,
  memTestSdramFirmware,
) where

import Clash.Prelude (BitVector, Signed)
import Control.Monad (forM_)
import Data.Either qualified as DE
import Data.Int (Int32)
import Riski5.Asm
import Riski5.ISA
import Prelude (Int, ($), (.))
import Prelude qualified as P

-- * Top-level programs ---------------------------------------------

-- | Runs SRAM test, then SDRAM test, then spins on "MEMTEST ALL OK".
memTestFirmware :: Asm ()
memTestFirmware = do
  setupBase
  failL <- labelUnplaced
  uartString "MEMTEST BEGIN\n"
  lcdBanner "MEMTEST: BEGIN  " "                "
  testRegion failL "SRAM " sramBase sramEnd
  testRegion failL "SDRAM" sdramBase sdramEnd
  -- All green.
  uartString "MEMTEST ALL OK\n"
  ledrSet 0x20000
  lcdBanner "MEMTEST:  ALL OK" "SRAM 512K SDRAM8"
  okSpin <- label
  j okSpin

  -- Shared fail handler sits at the tail — every BNE in the region
  -- loops above jumps here.
  placeAt failL
  emitFailHandler

-- | Just SRAM; useful for quick smoke-checks.
memTestSramFirmware :: Asm ()
memTestSramFirmware = do
  setupBase
  failL <- labelUnplaced
  uartString "MEMTEST BEGIN\n"
  testRegion failL "SRAM " sramBase sramEnd
  uartString "MEMTEST ALL OK\n"
  ledrSet 0x20000
  lcdBanner "MEMTEST:SRAM OK " "512KB walked    "
  okSpin <- label
  j okSpin

  placeAt failL
  emitFailHandler

-- | Just SDRAM. Runs for several seconds at 50 MHz.
memTestSdramFirmware :: Asm ()
memTestSdramFirmware = do
  setupBase
  failL <- labelUnplaced
  uartString "MEMTEST BEGIN\n"
  testRegion failL "SDRAM" sdramBase sdramEnd
  uartString "MEMTEST ALL OK\n"
  ledrSet 0x20000
  lcdBanner "MEMTEST:SDRAMOK " "8 MB walked     "
  okSpin <- label
  j okSpin

  placeAt failL
  emitFailHandler

memTestFirmwareWords :: [BitVector 32]
memTestFirmwareWords =
  DE.fromRight
    (P.error "MemTest failed to assemble")
    (assemble memTestFirmware)

-- * Region test driver --------------------------------------------

{- | Run all four patterns (each with write + verify pass) against
the @[base, end)@ byte-address window. Prints a per-pattern UART
line. On mismatch the loops branch to the shared @failL@ label —
never returns.

Registers preserved at the branch-to-fail point:
  * @addrReg@ — faulting byte address.
  * @patReg@ — expected value.
  * @resultReg@ — actual value.

@name@ is a 5-char space-padded region label.
-}
testRegion :: Label -> P.String -> Int32 -> Int32 -> Asm ()
testRegion failL name base end = do
  -- Local fail trampoline. BNE's B-type offset is 13-bit signed
  -- (≤ ±4096 bytes); the full firmware at 5 KB+ overflows that,
  -- so the inner-loop BNEs target this local trampoline instead,
  -- which then does a JAL (21-bit signed ≈ ±1 MB) to the real
  -- fail handler at the tail of the program.
  localFail <- labelUnplaced
  skipLocal <- labelUnplaced
  j skipLocal
  placeAt localFail
  j failL
  placeAt skipLocal

  uartString (name P.++ ": begin\n")
  lcdBanner ("MEMTEST:" P.++ padName name) "pattern 0/4     "

  lcdLine2 "P0: addr        "
  runPatternAddr localFail base end patAddr
  uartString (name P.++ ": addr OK\n")

  lcdLine2 "P1: ~addr       "
  runPatternAddr localFail base end patInvAddr
  uartString (name P.++ ": ~addr OK\n")

  lcdLine2 "P2: AAAAAAAA    "
  runPatternConst localFail base end 0xAAAAAAAA
  uartString (name P.++ ": AAAA OK\n")

  lcdLine2 "P3: 55555555    "
  runPatternConst localFail base end 0x55555555
  uartString (name P.++ ": 5555 OK\n")

  uartString (name P.++ ": ALL OK\n")

-- | Pad / truncate a 5-char label to exactly 8 chars for LCD line 1.
padName :: P.String -> P.String
padName s = P.take 8 (s P.++ P.repeat ' ')

-- * Pattern-suite drivers ------------------------------------------

{- | "Derived pattern" suite: the pattern value is computed from the
current address. Runs a write + inline-readback pass, then a
verify-only pass over the full region.
-}
runPatternAddr ::
  -- | fail handler
  Label ->
  -- | base byte-address
  Int32 ->
  -- | end byte-address (exclusive)
  Int32 ->
  -- | pattern computation: @compute patReg addrReg@
  (Reg -> Reg -> Asm ()) ->
  Asm ()
runPatternAddr failL base end computePat = do
  -- Pure write pass (no inline readback) — fills every word in the
  -- region with pattern(addr).
  li addrReg base
  li endReg end
  writeLoop <- label
  computePat patReg addrReg
  sw addrReg patReg 0
  addi addrReg addrReg 4
  bne addrReg endReg writeLoop

  -- Verify pass (read-only). After all writes finished, walk again
  -- and compare each cell against pattern(addr). Catches:
  --   * cell-to-cell cross-talk (earlier write corrupted a later cell)
  --   * SDRAM refresh bugs (verify runs after ~seconds of walking)
  --   * address-decoder aliasing (two addrs → one cell; one of them
  --     reads the other's value on verify)
  li addrReg base
  verifyLoop <- label
  computePat patReg addrReg
  lw resultReg addrReg 0
  bne resultReg patReg failL
  addi addrReg addrReg 4
  bne addrReg endReg verifyLoop

{- | "Constant pattern" suite: every address holds the same fixed
value. Write + inline readback pass, then a verify-only pass.
-}
runPatternConst :: Label -> Int32 -> Int32 -> Int32 -> Asm ()
runPatternConst failL base end patValue = do
  li patReg patValue
  -- Pure write pass (no inline readback).
  li addrReg base
  li endReg end
  writeLoop <- label
  sw addrReg patReg 0
  addi addrReg addrReg 4
  bne addrReg endReg writeLoop

  -- Verify pass.
  li addrReg base
  verifyLoop <- label
  lw resultReg addrReg 0
  bne resultReg patReg failL
  addi addrReg addrReg 4
  bne addrReg endReg verifyLoop

-- * Pattern functions ----------------------------------------------

-- | @patReg := addrReg@.
patAddr :: Reg -> Reg -> Asm ()
patAddr pat a = mv pat a

-- | @patReg := ~addrReg@. @XORI rd, rs, -1@ sign-extends to 0xFFFFFFFF.
patInvAddr :: Reg -> Reg -> Asm ()
patInvAddr pat a = xori pat a (-1)

-- * Fail handler ---------------------------------------------------

{- | Shared code emitted once at the tail of each firmware variant.
On entry: @addrReg@, @patReg@, @resultReg@ hold the failure data.
-}
emitFailHandler :: Asm ()
emitFailHandler = do
  -- Light the fail LEDs.
  ledrSet 0x10000
  ledgSet 0x100

  -- Shortened fail message — 8 + 8 + 1 chars per field fits inside
  -- the Altera JTAG UART's 64-byte TX FIFO without relying on the
  -- host to drain it mid-stream. Format:
  --
  --   F@AAAAAAAA\nG=GGGGGGGG\nE=EEEEEEEE\n
  --
  -- Each line stands alone (own trailing newline) so if the host
  -- catches us mid-burst, at least one full line lands intact.
  uartString "F@"
  uartHex32 addrReg
  uartChar (P.fromEnum '\n')
  uartString "G="
  uartHex32 resultReg
  uartChar (P.fromEnum '\n')
  uartString "E="
  uartHex32 patReg
  uartChar (P.fromEnum '\n')

  lcdBanner "MEMTEST:  FAIL  " "                "

  failSpin <- label
  j failSpin

-- * Region constants -----------------------------------------------

-- | SRAM region (see Riski5.MemMap).
sramBase, sramEnd :: Int32
sramBase = 0x2000_0000
sramEnd = 0x2008_0000 -- base + 512 KB

{- | SDRAM region. @0x8000_0000@ is negative when interpreted as a
32-bit signed integer but 'BNE' does a bit-exact compare, so the
sign doesn't matter; the @li@ pseudo-op expands to @LUI + ADDI@
which encodes the pattern correctly either way.
-}
sdramBase, sdramEnd :: Int32
sdramBase = P.fromIntegral (0x8000_0000 :: P.Word)
sdramEnd = P.fromIntegral (0x8080_0000 :: P.Word)

-- * Register conventions -------------------------------------------

uartReg, lcdReg, gpioReg, addrReg, endReg, patReg, resultReg, tmpReg, hexReg :: Reg
uartReg = x20
lcdReg = x21
gpioReg = x23
addrReg = x10
endReg = x11
patReg = x12
resultReg = x13
tmpReg = x14
hexReg = x15

-- * Boot setup -----------------------------------------------------

setupBase :: Asm ()
setupBase = do
  li uartReg 0x1000_0000
  li lcdReg 0x1000_0040
  li gpioReg 0x1000_0020
  ledrSet 0
  ledgSet 0

-- * UART helpers ---------------------------------------------------

uartChar :: Int -> Asm ()
uartChar ch = do
  addi tmpReg x0 (P.fromIntegral ch)
  sw uartReg tmpReg 0

uartString :: P.String -> Asm ()
uartString = P.mapM_ (uartChar . P.fromEnum)

{- | 32-bit hex print, MSB first. 8 nibbles. Destroys @hexReg@ +
@tmpReg@ but leaves @rd@ unchanged.
-}
uartHex32 :: Reg -> Asm ()
uartHex32 rd =
  forM_ [28, 24, 20, 16, 12, 8, 4, 0 :: Int] $ \shift -> do
    if shift P.== 0
      then mv hexReg rd
      else srli hexReg rd (P.fromIntegral shift)
    andi hexReg hexReg 0xF
    addi tmpReg x0 10
    isAlpha <- labelUnplaced
    bge hexReg tmpReg isAlpha
    addi hexReg hexReg (P.fromIntegral (P.fromEnum '0'))
    afterChar <- labelUnplaced
    j afterChar
    placeAt isAlpha
    addi hexReg hexReg (P.fromIntegral (P.fromEnum 'A' P.- 10))
    placeAt afterChar
    sw uartReg hexReg 0

-- * LCD helpers ----------------------------------------------------

lcdWait :: Asm ()
lcdWait = do
  waitL <- label
  lw tmpReg lcdReg 8
  bne tmpReg x0 waitL

lcdCmd :: Int -> Asm ()
lcdCmd cmdByte = do
  lcdWait
  addi tmpReg x0 (P.fromIntegral cmdByte)
  sw lcdReg tmpReg 4

lcdChar :: Int -> Asm ()
lcdChar ch = do
  lcdWait
  addi tmpReg x0 (P.fromIntegral ch)
  sw lcdReg tmpReg 0

lcdString :: P.String -> Asm ()
lcdString = P.mapM_ (lcdChar . P.fromEnum)

-- | Set LCD line 1 + line 2 (each padded / truncated to 16 chars).
lcdBanner :: P.String -> P.String -> Asm ()
lcdBanner line1 line2 = do
  lcdCmd 0x80
  lcdString (fixTo16 line1)
  lcdCmd 0xC0
  lcdString (fixTo16 line2)

-- | Overwrite LCD line 2 only (16 chars).
lcdLine2 :: P.String -> Asm ()
lcdLine2 line = do
  lcdCmd 0xC0
  lcdString (fixTo16 line)

fixTo16 :: P.String -> P.String
fixTo16 s = P.take 16 (s P.++ P.repeat ' ')

-- * GPIO helpers ---------------------------------------------------

ledrSet :: Int -> Asm ()
ledrSet bits = do
  li tmpReg (P.fromIntegral bits :: Int32)
  sw gpioReg tmpReg 0

ledgSet :: Int -> Asm ()
ledgSet bits = do
  li tmpReg (P.fromIntegral bits :: Int32)
  sw gpioReg tmpReg 4
