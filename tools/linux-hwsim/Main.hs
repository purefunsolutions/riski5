-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Main
Description : Verilator-backed runner that boots Linux against the
              Clash-emitted SoC RTL.

Mirrors @tools/linux-sim/Main.hs@ but instead of stepping the
pure-Haskell @Riski5.SocSim@ model, drives the Verilator-compiled
@riski5_sim_top@ (which wraps @riski5.v@ + @riski5_jtag_uart.v@ +
an internal @sim_sdram_chip@ — see @pkgs/riski5-sim/verilog/@).

Usage:

@
  riski5-linux-hwsim KERNEL DTB [MAX_STEPS]
@

Default MAX_STEPS = 5_000_000 (= 0.125 s simulated at 40 MHz, plenty
to reach the SLUB-init point where 40 MHz silicon hangs and to see
whether RTL hwsim takes the same path).

Pre-load: the harness writes the kernel image to SDRAM[0x80000000+]
and the DTB to SDRAM[0x80400000+] via the wrapper's MEM_INIT_*
ports while reset is held. Reset is then released; the riski5 boot
flow runs unchanged from there. UART TX bytes are captured via the
@UART_TX_VALID@ / @UART_TX_BYTE@ tap (one-cycle pulses on the cycle
the Altera IP's TX FIFO commits a byte from av_writedata).

Output: UART byte stream on stdout (same format as
@riski5-linux-sim@), diagnostics on stderr.
-}
module Main (main) where

import Control.Monad.IO.Class (liftIO)
import Data.Bits (shiftR, (.&.))
import qualified Data.ByteString as BS
import Data.ByteString (ByteString)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Kind (Type)
import Data.Word (Word16, Word32, Word8)
import Foreign.Ptr (Ptr)
import Foreign.Storable (Storable (..))
import GHC.Generics (Generic)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hFlush, hPutStrLn, stderr, stdout)
import qualified Data.ByteString.Char8 as BSC
import Verilambda (
  SimBackend (..),
  SimM,
  modifyState,
  pokeState,
  peekState,
  runSim,
  tick,
 )

-- * FFI bindings — must match
-- @pkgs/riski5-sim/cbits/verilambda_riski5_sim_top_shim.h@,
-- regenerated when riski5-sim builds.

foreign import ccall unsafe "verilambda_riski5_sim_top_new"
  c_sim_new :: IO (Ptr ())

foreign import ccall unsafe "verilambda_riski5_sim_top_delete"
  c_sim_delete :: Ptr () -> IO ()

foreign import ccall unsafe "verilambda_riski5_sim_top_step"
  c_sim_step :: Ptr () -> Ptr Riski5SimTopState -> Ptr Riski5SimTopState -> IO ()

foreign import ccall unsafe "verilambda_riski5_sim_top_final"
  c_sim_final :: Ptr () -> IO ()

-- * HKD port record (phantom, satisfies SimBackend kind).
data Riski5SimTopPorts (f :: Type -> Type) = Riski5SimTopPorts
  deriving stock (Generic)

-- * C-ABI state struct
--
-- Mirrors @verilambda_riski5_sim_top_state_t@ field-for-field. Field
-- ORDER must match the .h emitted by verilambda-shim-gen, which in
-- turn matches @ports_flat@ in
-- @pkgs/riski5-sim/clash-manifest.json@. The shim sorts ports by
-- declaration order (manifest order); we sorted the manifest by
-- width descending so there's no internal padding.

data Riski5SimTopState = Riski5SimTopState
  { -- 32-bit ports (offsets 0..15)
    sMemInitAddr :: !Word32 -- 22 used, upper 10 ignored
  , sSw :: !Word32 -- 18 used
  , sLedr :: !Word32 -- 18 used
  , sSramAddr :: !Word32 -- 18 used
  , -- 16-bit ports (offsets 16..23)
    sMemInitData :: !Word16
  , sSramDqIn :: !Word16
  , sLedg :: !Word16 -- 9 used
  , sSramDqOut :: !Word16
  , -- 8-bit ports (offsets 24..45). Phase E-b adds clk_core /
    -- rst_core_n / clk_sdram / rst_sdram_n at offsets 26..29 so the
    -- harness can drive each Clash domain's clock independently.
    sClk :: !Word8 -- bus-domain clock (clk in Verilog)
  , sRstN :: !Word8 -- bus-domain reset (active low)
  , sClkCore :: !Word8
  , sRstCoreN :: !Word8
  , sClkSdram :: !Word8
  , sRstSdramN :: !Word8
  , sKey :: !Word8 -- 4 used
  , sMemInitWrite :: !Word8
  , sLcdData :: !Word8
  , sLcdRs :: !Word8
  , sLcdRw :: !Word8
  , sLcdEn :: !Word8
  , sLcdOn :: !Word8
  , sLcdBlon :: !Word8
  , sSramDqOe :: !Word8
  , sSramCeN :: !Word8
  , sSramOeN :: !Word8
  , sSramWeN :: !Word8
  , sSramUbN :: !Word8
  , sSramLbN :: !Word8
  , sUartTxValid :: !Word8
  , sUartTxByte :: !Word8
  }
  deriving stock (Show, Eq)

instance Storable Riski5SimTopState where
  sizeOf _ = 48 -- 46 bytes of fields, padded to multiple of alignment 4
  alignment _ = 4
  peek p = do
    memInitAddr <- peekByteOff p 0
    sw <- peekByteOff p 4
    ledr <- peekByteOff p 8
    sramAddr <- peekByteOff p 12
    memInitData <- peekByteOff p 16
    sramDqIn <- peekByteOff p 18
    ledg <- peekByteOff p 20
    sramDqOut <- peekByteOff p 22
    clk <- peekByteOff p 24
    rstN <- peekByteOff p 25
    clkCore <- peekByteOff p 26
    rstCoreN <- peekByteOff p 27
    clkSdram <- peekByteOff p 28
    rstSdramN <- peekByteOff p 29
    key <- peekByteOff p 30
    memInitWrite <- peekByteOff p 31
    lcdData <- peekByteOff p 32
    lcdRs <- peekByteOff p 33
    lcdRw <- peekByteOff p 34
    lcdEn <- peekByteOff p 35
    lcdOn <- peekByteOff p 36
    lcdBlon <- peekByteOff p 37
    sramDqOe <- peekByteOff p 38
    sramCeN <- peekByteOff p 39
    sramOeN <- peekByteOff p 40
    sramWeN <- peekByteOff p 41
    sramUbN <- peekByteOff p 42
    sramLbN <- peekByteOff p 43
    uartTxValid <- peekByteOff p 44
    uartTxByte <- peekByteOff p 45
    pure
      Riski5SimTopState
        { sMemInitAddr = memInitAddr
        , sSw = sw
        , sLedr = ledr
        , sSramAddr = sramAddr
        , sMemInitData = memInitData
        , sSramDqIn = sramDqIn
        , sLedg = ledg
        , sSramDqOut = sramDqOut
        , sClk = clk
        , sRstN = rstN
        , sClkCore = clkCore
        , sRstCoreN = rstCoreN
        , sClkSdram = clkSdram
        , sRstSdramN = rstSdramN
        , sKey = key
        , sMemInitWrite = memInitWrite
        , sLcdData = lcdData
        , sLcdRs = lcdRs
        , sLcdRw = lcdRw
        , sLcdEn = lcdEn
        , sLcdOn = lcdOn
        , sLcdBlon = lcdBlon
        , sSramDqOe = sramDqOe
        , sSramCeN = sramCeN
        , sSramOeN = sramOeN
        , sSramWeN = sramWeN
        , sSramUbN = sramUbN
        , sSramLbN = sramLbN
        , sUartTxValid = uartTxValid
        , sUartTxByte = uartTxByte
        }
  poke p Riski5SimTopState {..} = do
    pokeByteOff p 0 sMemInitAddr
    pokeByteOff p 4 sSw
    pokeByteOff p 8 sLedr
    pokeByteOff p 12 sSramAddr
    pokeByteOff p 16 sMemInitData
    pokeByteOff p 18 sSramDqIn
    pokeByteOff p 20 sLedg
    pokeByteOff p 22 sSramDqOut
    pokeByteOff p 24 sClk
    pokeByteOff p 25 sRstN
    pokeByteOff p 26 sClkCore
    pokeByteOff p 27 sRstCoreN
    pokeByteOff p 28 sClkSdram
    pokeByteOff p 29 sRstSdramN
    pokeByteOff p 30 sKey
    pokeByteOff p 31 sMemInitWrite
    pokeByteOff p 32 sLcdData
    pokeByteOff p 33 sLcdRs
    pokeByteOff p 34 sLcdRw
    pokeByteOff p 35 sLcdEn
    pokeByteOff p 36 sLcdOn
    pokeByteOff p 37 sLcdBlon
    pokeByteOff p 38 sSramDqOe
    pokeByteOff p 39 sSramCeN
    pokeByteOff p 40 sSramOeN
    pokeByteOff p 41 sSramWeN
    pokeByteOff p 42 sSramUbN
    pokeByteOff p 43 sSramLbN
    pokeByteOff p 44 sUartTxValid
    pokeByteOff p 45 sUartTxByte

initialState :: Riski5SimTopState
initialState =
  Riski5SimTopState
    { sMemInitAddr = 0
    , sSw = 0
    , sLedr = 0
    , sSramAddr = 0
    , sMemInitData = 0
    , sSramDqIn = 0
    , sLedg = 0
    , sSramDqOut = 0
    , sClk = 0
    , sRstN = 0
    , sClkCore = 0
    , sRstCoreN = 0
    , sClkSdram = 0
    , sRstSdramN = 0
    , sKey = 0xF
    , sMemInitWrite = 0
    , sLcdData = 0
    , sLcdRs = 0
    , sLcdRw = 0
    , sLcdEn = 0
    , sLcdOn = 0
    , sLcdBlon = 0
    , sSramDqOe = 0
    , sSramCeN = 0
    , sSramOeN = 0
    , sSramWeN = 0
    , sSramUbN = 0
    , sSramLbN = 0
    , sUartTxValid = 0
    , sUartTxByte = 0
    }

riski5Backend :: SimBackend Riski5SimTopPorts Riski5SimTopState
riski5Backend =
  SimBackend
    { sbNew = c_sim_new
    , sbDelete = c_sim_delete
    , sbStep = c_sim_step
    , sbFinal = c_sim_final
    , sbInitialState = initialState
    , sbTraceOpen = Nothing
    , sbTraceClose = Nothing
    , sbTraceDump = Nothing
    }

-- * Driver helpers ---------------------------------------------------

-- | One full clock cycle of ALL THREE domains in lockstep — the
-- single-clock simplification. All three @clk_*@ inputs to the
-- wrapper toggle on the same simulation tick. Functionally the
-- bridges still run their CDC FSMs (they're synchronizers
-- regardless of source/dest clock equality), they just do it at
-- minimum latency.
--
-- For genuine multi-rate runs use 'multiClockTick' below, which
-- ticks each clock at its own period.
clockCycle :: SimM Riski5SimTopPorts Riski5SimTopState ()
clockCycle = do
  modifyState $ \s -> s {sClk = 0, sClkCore = 0, sClkSdram = 0}
  tick
  modifyState $ \s -> s {sClk = 1, sClkCore = 1, sClkSdram = 1}
  tick

-- | Multi-rate clock driver. Takes per-domain period counts (in
-- "fine" simulation steps) and runs the simulation for one bus
-- cycle's worth of fine ticks, toggling each clock at its own
-- period. Common useful ratios:
--
--   * @multiClockTick 2 1 0@: bus once per 2 fine ticks (= 0.5x),
--     core once per 1 (= 1x), sdram every fine tick (= 2x).
--     Models bus 40 MHz / core 80 MHz / sdram 80 MHz.
--   * @multiClockTick 5 4 2@: bus 1 / core 1.25 / sdram 2.5 ratio
--     — models bus 40 MHz / core 50 MHz / sdram 100 MHz.
--   * @multiClockTick 1 1 1@: degenerates to 'clockCycle' (all
--     three clocks tick together every simulation step).
--
-- The "fine tick" period itself is opaque — what matters is the
-- ratio between the three numbers. For a given simulation pass,
-- the sim time per fine tick is constant; the wrapper's clk_*
-- inputs just toggle when their tick-counter passes their period.
--
-- NOTE this is the building-block API; consumers will typically
-- wrap it in a per-bus-cycle helper that runs the right number of
-- fine ticks. Currently unused — added so the harness has an
-- escape hatch for the silicon-debug runs Phase D-3b /
-- Linux-mid-init-hang need.
_multiClockTick ::
  -- | bus period (fine ticks per bus half-cycle). 1 = always toggle.
  Int ->
  -- | core period (fine ticks per core half-cycle).
  Int ->
  -- | sdram period (fine ticks per sdram half-cycle).
  Int ->
  -- | current global fine-tick counter.
  Int ->
  SimM Riski5SimTopPorts Riski5SimTopState ()
_multiClockTick busP coreP sdramP t = do
  let busLevel = if (t `div` busP) `mod` 2 == 0 then 0 else 1
      coreLevel = if (t `div` coreP) `mod` 2 == 0 then 0 else 1
      sdramLevel = if (t `div` sdramP) `mod` 2 == 0 then 0 else 1
  modifyState $ \s ->
    s
      { sClk = busLevel
      , sClkCore = coreLevel
      , sClkSdram = sdramLevel
      }
  tick

-- | Translate a controller-side 22-bit half-word bus index into
-- the linear cell index of the in-Verilog SDRAM model's backing
-- array. The controller (Riski5.SdrController) uses
-- bank-interleaved addressing:
--
--   bus[7:0]   → col   (8 bits, 256 cols/row)
--   bus[9:8]   → bank  (2 bits, 4 banks)
--   bus[21:10] → row   (12 bits, 4096 rows/bank)
--
-- The SDRAM model's @mem[]@ array uses bank-major linear ordering
-- (ba × 4096 × 256 + row × 256 + col) — that's just the natural
-- way to lay the bank state out, NOT the chip's physical reality
-- (the chip is bank-row-col internal regardless of the controller's
-- address-bit choices). Without this translation the harness would
-- write to mem[i] but the controller's ACTIVATE+READ would target
-- a different chip cell.
busHwToChipCell :: Word32 -> Word32
busHwToChipCell busHw =
  let col = busHw .&. 0xff
      bank = (busHw `shiftR` 8) .&. 0x3
      row = (busHw `shiftR` 10) .&. 0xfff
   in bank * (4096 * 256) + row * 256 + col

-- | Pre-load 16-bit words into the in-Verilog SDRAM model. Drives
-- MEM_INIT_ADDR/DATA/WRITE on each cycle while reset is asserted.
loadWords ::
  Word32 ->
  -- ^ Base byte address (e.g. 0x80000000 for kernel).
  ByteString ->
  -- ^ Bytes to write. Padded to a multiple of 2.
  SimM Riski5SimTopPorts Riski5SimTopState ()
loadWords baseByte bs = do
  let padded = if BS.length bs `mod` 2 == 0 then bs else BS.snoc bs 0
      nWords = BS.length padded `div` 2
      -- Convert host byte address → 22-bit half-word bus index.
      -- The bus index is what the controller sees; busHwToChipCell
      -- then translates to the chip-model's mem[] index.
      baseBusHw = (baseByte - 0x8000_0000) `shiftR` 1
  mapM_
    ( \i -> do
        let lo = BS.index padded (i * 2)
            hi = BS.index padded (i * 2 + 1)
            w16 = fromIntegral lo + fromIntegral hi * (256 :: Word16)
            busHw = baseBusHw + fromIntegral i
            chipCell = busHwToChipCell busHw
        modifyState $ \s ->
          s
            { sMemInitAddr = chipCell
            , sMemInitData = w16
            , sMemInitWrite = 1
            }
        clockCycle
    )
    [0 .. nWords - 1]
  -- Stop pre-loading so the controller's normal traffic isn't
  -- shadowed.
  modifyState $ \s ->
    s
      { sMemInitAddr = 0
      , sMemInitData = 0
      , sMemInitWrite = 0
      }

-- | Run the sim for at most @n@ cycles, capturing every UART TX
-- byte and live-streaming it to stdout. Stops early on hang
-- detection (no UART activity for >= 1M cycles past start of
-- the run).
runUartStream ::
  Int ->
  IORef [Word8] ->
  SimM Riski5SimTopPorts Riski5SimTopState Int
runUartStream maxCycles bufRef = go maxCycles 0
 where
  go 0 cycs = pure cycs
  go k cycs = do
    clockCycle
    s <- peekState
    if sUartTxValid s /= 0
      then do
        let b = sUartTxByte s
        liftIO $ do
          modifyIORef' bufRef (b :)
          BS.hPutStr stdout (BS.singleton b)
          hFlush stdout
        go (k - 1) (cycs + 1)
      else go (k - 1) (cycs + 1)

-- * Entry point ------------------------------------------------------

main :: IO ()
main = do
  args <- getArgs
  case args of
    [k, d] -> runHwsim k d 5_000_000
    [k, d, n] -> runHwsim k d (read n)
    _ -> do
      hPutStrLn stderr "usage: riski5-linux-hwsim KERNEL DTB [MAX_STEPS]"
      exitFailure

runHwsim :: FilePath -> FilePath -> Int -> IO ()
runHwsim kPath dPath maxSteps = do
  hPutStrLn stderr $
    "linux-hwsim: kernel="
      ++ kPath
      ++ " dtb="
      ++ dPath
      ++ " max-steps="
      ++ show maxSteps
  kernel <- BS.readFile kPath
  dtb <- BS.readFile dPath
  hPutStrLn stderr $
    "  loading "
      ++ show (BS.length kernel)
      ++ "-byte kernel @ 0x80000000 + "
      ++ show (BS.length dtb)
      ++ "-byte DTB @ 0x80400000 ..."
  bufRef <- newIORef []
  cycles <- runSim riski5Backend $ do
    -- Hold ALL THREE domain resets asserted while we pre-load SDRAM
    -- (all rst_*_n=0). Each reset gates the corresponding domain's
    -- registers; deasserting them in lockstep avoids any of the
    -- three domains running while the other two are still held.
    pokeState
      initialState
        { sClk = 0
        , sClkCore = 0
        , sClkSdram = 0
        , sRstN = 0
        , sRstCoreN = 0
        , sRstSdramN = 0
        , sKey = 0xF
        }
    clockCycle
    clockCycle
    loadWords 0x8000_0000 kernel
    loadWords 0x8040_0000 dtb
    -- A few quiet cycles so the SDRAM chip's pre-load writes
    -- settle before reset releases.
    clockCycle
    clockCycle
    -- Release all three resets in lockstep.
    modifyState $ \s -> s {sRstN = 1, sRstCoreN = 1, sRstSdramN = 1}
    runUartStream maxSteps bufRef
  collected <- readIORef bufRef
  let bytes = reverse collected
  hPutStrLn stderr ""
  hPutStrLn stderr "--- linux-hwsim done ---"
  hPutStrLn stderr $ "  cycles : " ++ show cycles
  hPutStrLn stderr $ "  uart-tx: " ++ show (length bytes) ++ " bytes"
  case lastNonNullPrintk bytes of
    Just s -> hPutStrLn stderr $ "  last printk: " ++ s
    Nothing -> hPutStrLn stderr "  (no printk emitted)"

-- | Tail of the UART stream, up to a newline, rendered as ASCII.
-- Useful for the end-of-run summary.
lastNonNullPrintk :: [Word8] -> Maybe String
lastNonNullPrintk bs =
  let asString = BSC.unpack (BS.pack bs)
      lns = lines asString
   in case reverse (filter (not . null) lns) of
        (l : _) -> Just l
        [] -> Nothing

-- Suppress unused-import warnings — these are needed to keep the
-- types right but not used directly.
_unused :: (Word32, Word32)
_unused = (0 .&. 0, 0 `shiftR` 0)
