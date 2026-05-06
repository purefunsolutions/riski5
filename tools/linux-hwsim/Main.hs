-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE BangPatterns #-}
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

import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.Bits (shiftR, (.&.))
import qualified Data.ByteString as BS
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import qualified Data.Sequence as Seq
import Data.Sequence (Seq, (|>))
import System.IO (BufferMode (..), Handle, IOMode (..), SeekMode (..),
                   hClose, hFileSize, hSeek, hSetBuffering, openBinaryFile)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Kind (Type)
import Data.List (sortBy)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Ord (Down (..), comparing)
import Data.Word (Word16, Word32, Word8)
import Foreign.Ptr (Ptr)
import Foreign.Storable (Storable (..))
import GHC.Generics (Generic)
import Numeric (showHex)
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
  { -- 32-bit ports (offsets 0..31)
    sMemInitAddr :: !Word32 -- 22 used, upper 10 ignored
  , sSw :: !Word32 -- 18 used
  , sLedr :: !Word32 -- 18 used
  , sSramAddr :: !Word32 -- 18 used
  , sDebugPcfetch :: !Word32 -- IF-stage PC, sampled every cycle
  , sDebugDmemRdata :: !Word32 -- bus-side dmem rdata (task #52)
  , sDebugBridgeDmemRdata :: !Word32 -- bridge-captured dmem rdata (task #52 debug 2)
  , sDebugSp :: !Word32 -- regfile x2 shadow tracked via writeback (task #55)
  , sDebugS0 :: !Word32 -- regfile x8 shadow tracked via writeback (task #55)
  , sDebugRa :: !Word32 -- regfile x1 shadow tracked via writeback (task #55)
  , -- 16-bit ports (offsets 40..47)
    sMemInitData :: !Word16
  , sSramDqIn :: !Word16
  , sLedg :: !Word16 -- 9 used
  , sSramDqOut :: !Word16
  , -- 8-bit ports (offsets 32..53). Phase E-b adds clk_core /
    -- rst_core_n / clk_sdram / rst_sdram_n at offsets 34..37 so the
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
  sizeOf _ = 72 -- 70 bytes of fields, padded to multiple of alignment 4
  alignment _ = 4
  peek p = do
    memInitAddr <- peekByteOff p 0
    sw <- peekByteOff p 4
    ledr <- peekByteOff p 8
    sramAddr <- peekByteOff p 12
    debugPcfetch <- peekByteOff p 16
    debugDmemRdata <- peekByteOff p 20
    debugBridgeDmemRdata <- peekByteOff p 24
    debugSp <- peekByteOff p 28
    debugS0 <- peekByteOff p 32
    debugRa <- peekByteOff p 36
    memInitData <- peekByteOff p 40
    sramDqIn <- peekByteOff p 42
    ledg <- peekByteOff p 44
    sramDqOut <- peekByteOff p 46
    clk <- peekByteOff p 48
    rstN <- peekByteOff p 49
    clkCore <- peekByteOff p 50
    rstCoreN <- peekByteOff p 51
    clkSdram <- peekByteOff p 52
    rstSdramN <- peekByteOff p 53
    key <- peekByteOff p 54
    memInitWrite <- peekByteOff p 55
    lcdData <- peekByteOff p 56
    lcdRs <- peekByteOff p 57
    lcdRw <- peekByteOff p 58
    lcdEn <- peekByteOff p 59
    lcdOn <- peekByteOff p 60
    lcdBlon <- peekByteOff p 61
    sramDqOe <- peekByteOff p 62
    sramCeN <- peekByteOff p 63
    sramOeN <- peekByteOff p 64
    sramWeN <- peekByteOff p 65
    sramUbN <- peekByteOff p 66
    sramLbN <- peekByteOff p 67
    uartTxValid <- peekByteOff p 68
    uartTxByte <- peekByteOff p 69
    pure
      Riski5SimTopState
        { sMemInitAddr = memInitAddr
        , sSw = sw
        , sLedr = ledr
        , sSramAddr = sramAddr
        , sDebugPcfetch = debugPcfetch
        , sDebugDmemRdata = debugDmemRdata
        , sDebugBridgeDmemRdata = debugBridgeDmemRdata
        , sDebugSp = debugSp
        , sDebugS0 = debugS0
        , sDebugRa = debugRa
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
    pokeByteOff p 16 sDebugPcfetch
    pokeByteOff p 20 sDebugDmemRdata
    pokeByteOff p 24 sDebugBridgeDmemRdata
    pokeByteOff p 28 sDebugSp
    pokeByteOff p 32 sDebugS0
    pokeByteOff p 36 sDebugRa
    pokeByteOff p 40 sMemInitData
    pokeByteOff p 42 sSramDqIn
    pokeByteOff p 44 sLedg
    pokeByteOff p 46 sSramDqOut
    pokeByteOff p 48 sClk
    pokeByteOff p 49 sRstN
    pokeByteOff p 50 sClkCore
    pokeByteOff p 51 sRstCoreN
    pokeByteOff p 52 sClkSdram
    pokeByteOff p 53 sRstSdramN
    pokeByteOff p 54 sKey
    pokeByteOff p 55 sMemInitWrite
    pokeByteOff p 56 sLcdData
    pokeByteOff p 57 sLcdRs
    pokeByteOff p 58 sLcdRw
    pokeByteOff p 59 sLcdEn
    pokeByteOff p 60 sLcdOn
    pokeByteOff p 61 sLcdBlon
    pokeByteOff p 62 sSramDqOe
    pokeByteOff p 63 sSramCeN
    pokeByteOff p 64 sSramOeN
    pokeByteOff p 65 sSramWeN
    pokeByteOff p 66 sSramUbN
    pokeByteOff p 67 sSramLbN
    pokeByteOff p 68 sUartTxValid
    pokeByteOff p 69 sUartTxByte

initialState :: Riski5SimTopState
initialState =
  Riski5SimTopState
    { sMemInitAddr = 0
    , sSw = 0
    , sLedr = 0
    , sSramAddr = 0
    , sDebugPcfetch = 0
    , sDebugDmemRdata = 0
    , sDebugBridgeDmemRdata = 0
    , sDebugSp = 0
    , sDebugS0 = 0
    , sDebugRa = 0
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
--
-- ALSO samples DEBUG_PCFETCH every cycle into a histogram so the
-- end-of-run summary shows where the kernel spent its time —
-- crucial for "kernel hung silently at PC X" silicon-bug debug.
-- Bucketing is by exact PC; for a tighter region rollup the caller
-- can post-process the returned map.
runUartStream ::
  Int ->
  -- | Handle to write UART bytes to (line-buffered, streaming)
  Handle ->
  -- | Counter of UART bytes emitted (for end-of-run summary)
  IORef Int ->
  IORef (Map Word32 Int) ->
  IORef (Seq (Int, Word32)) ->
  IORef (Map Word32 Int) ->
  -- ^ task #52: histogram of bus-side dmem rdata seen at PC=0x801ec468.
  IORef (Map Word32 Int) ->
  -- ^ task #52 debug 2: histogram of bridge-captured dmem rdata at the
  -- same PC. Compare to the bus-side histogram — if they differ, the
  -- bridge is presenting a different value than the bus mux shows;
  -- if they match, the bus signal IS the LW result the kernel sees.
  SimM Riski5SimTopPorts Riski5SimTopState Int
runUartStream maxCycles uartLogHandle uartByteCountRef pcRef snapsRef rdataRef bridgeRdataRef = do
  prevSpRef <- liftIO $ newIORef (0 :: Word32)
  prevRaRef <- liftIO $ newIORef (0 :: Word32)
  -- Task #55: rolling buffer of (cycle, pc, dmem_rdata, bridge_rdata, sp,
  -- s0, ra). Holds the last 5000 cycles. Dumped on the CPU-RESET event so we
  -- can see exactly which dmem load returned 0 → wound up in ra → ret to 0.
  ringRef <- liftIO $ newIORef (Seq.empty :: Seq.Seq (Int, Word32, Word32, Word32, Word32, Word32, Word32))
  go maxCycles 0 0 prevSpRef prevRaRef ringRef
 where
  go 0 cycs _prevPc _ _ _ = pure cycs
  go k cycs prevPc prevSpRef prevRaRef ringRef = do
    clockCycle
    s <- peekState
    let !pc = sDebugPcfetch s
    -- Use a strict update closure so the (+) thunk doesn't pile up
    -- as `1+(1+(1+(...)))` deep — earlier `Map.insertWith (+) pc 1`
    -- was the dominant heap leak (1 GB residency at cycle ~22M).
    -- The strict-Map insertWith only forces the spine; the value
    -- thunk it stores still chains with each cycle's identical-PC
    -- update.
    liftIO $ modifyIORef' pcRef $ \m ->
      Map.insertWith (\_new old -> let !o' = old + 1 in o') pc 1 m
    -- Task #55: append this cycle's snapshot to the rolling buffer.
    -- Keep only last 5000 entries (~5000 cycle window covering the
    -- full 6-iteration unwind that ends in CPU-RESET).
    -- Force every tuple element to WHNF before going into the Seq;
    -- the lazy field selectors (sDebugDmemRdata s etc.) would
    -- otherwise hold references to the entire `s` record alive
    -- in each entry, retaining ~200 bytes of state per cycle ×
    -- 5000-deep ring × thunk overhead = hundreds of MB after
    -- millions of cycles.
    let !d = sDebugDmemRdata s
        !br = sDebugBridgeDmemRdata s
        !sp = sDebugSp s
        !s0 = sDebugS0 s
        !ra = sDebugRa s
    liftIO $ modifyIORef' ringRef $ \xs ->
      let !entry = (cycs, pc, d, br, sp, s0, ra)
       in Seq.take 5000 (entry Seq.<| xs)
    -- Task #55: log every ra change, especially when ra becomes a
    -- value outside the kernel text region. The ROOT bug is "ra
    -- becomes a stack address" → ret to stack → bad code → eventual
    -- panic. Catching the EXACT cycle ra became wrong pinpoints
    -- the lw ra (or jal) that wrote the bad value.
    do
      prevRa <- liftIO $ readIORef prevRaRef
      when (sDebugRa s /= prevRa) $ do
        liftIO $ writeIORef prevRaRef (sDebugRa s)
        let newRa = sDebugRa s
            -- init_stack at 0x80270000-0x80272000 (per riski5-overlay
            -- config: THREAD_SIZE_ORDER=1 = 8KB stack, anchored where
            -- our boot stub sets sp = 0x20080000... wait that's SRAM.
            -- The kernel's init_stack is mapped to the RAM region;
            -- per our SP-CHANGE traces sp lives at 0x80271xxx in
            -- normal operation). Anything in the SDRAM data range
            -- (0x80200000-0x80300000 minus init.text 0x801f25c0-
            -- 0x80211940) that's NOT a valid kernel code address is
            -- suspicious.
            inText r = r >= 0x80000000 && r < 0x80211940
            inStack r = r >= 0x80270000 && r < 0x80272000
            isBadCode r = r > 0 && not (inText r)
        when (inStack newRa || isBadCode newRa) $
          liftIO $ hPutStrLn stderr
            ("[RA-SUSPECT] cycle=" ++ show cycs
              ++ " new_ra=0x" ++ showHex newRa ""
              ++ " (prev=0x" ++ showHex prevRa ")"
              ++ " pc=0x" ++ showHex pc "")
    -- Task #55: log every change to sp shadow. Limit to a window
    -- around the canary fail (cycle ~50.9M) to keep the log small.
    when (cycs > 50000000 && cycs < 51100000) $ do
      prevSp <- liftIO $ readIORef prevSpRef
      when (sDebugSp s /= prevSp) $ do
        liftIO $ hPutStrLn stderr
          ("[SP-CHANGE] cycle=" ++ show cycs
            ++ " new_sp=0x" ++ showHex (sDebugSp s) ""
            ++ " (prev=0x" ++ showHex prevSp ")"
            ++ " pc=0x" ++ showHex pc "")
        liftIO $ writeIORef prevSpRef (sDebugSp s)
    -- Sample PC every 100k cycles for a "where is the core
    -- right now" timeline. Cheaper than streaming every PC out
    -- and dense enough to localise long stalls.
    when (cycs `mod` 100_000 == 0) $
      liftIO $ modifyIORef' snapsRef (|> (cycs, pc))
    -- Task #52: 5-stage pipeline F/D/X/M/W. The LW at 0x801ec464
    -- enters X-stage 3 cycles after PC_F first sees it. PC_F gets
    -- held at 0x801ec46c during the SDRAM stall (the bnez is in F
    -- while the LW stalls X). So sample DEBUG_BRIDGE_DMEM_RDATA
    -- EVERY CYCLE PC=0x801ec46c — this captures mReply during the
    -- entire stall window. The stall-release cycle is exactly when
    -- mReply.cbrDmemRdata = the LW's actual result (= what the core
    -- retires the LW with). The histogram will show the value the
    -- LW from *(tp) actually returns, mixed with 0 from MBusy
    -- cycles.
    when (pc == 0x801ec46c) $
      liftIO $ do
        modifyIORef' rdataRef (Map.insertWith (+) (sDebugDmemRdata s) 1)
        modifyIORef' bridgeRdataRef (Map.insertWith (+) (sDebugBridgeDmemRdata s) 1)
    -- Task #52: count visits to each candidate caller of
    -- signal_wake_up_state (= the kernel function that AMOOR.W's
    -- TIF_SIGPENDING into init_task.flags). Whichever has a
    -- non-zero count points to the caller responsible for the
    -- spurious flag set.
    -- Caller PCs (jal sites): 0x80019074, 0x800196f8, 0x80019ea8,
    -- 0x80019f2c, 0x8001bee4, 0x8001c238, 0x8001c81c.
    -- Detect the two `amoor.w zero,a5,(a0)` instructions that
    -- set bit 1 of *(a0): one in signal_wake_up_state (0x8001be50),
    -- one in kthread_stop (0x80031910). Whichever fires is the
    -- AMO that writes 0x0002 to *(init_task.flags).
    when (pc == 0x8001be50 || pc == 0x80031910) $
      liftIO $ hPutStrLn stderr
        ("[AMO-SET-BIT1] cycle=" ++ show cycs
          ++ " pc=0x" ++ showHex pc ""
          ++ " (prev=0x" ++ showHex prevPc "" ++ ")")
    -- Also log FIRST visit to any PC in the signal_wake_up_state
    -- function range. If this NEVER fires, the kernel is reaching
    -- PC=0x8001be58 via a code path we don't expect.
    when (pc == 0x8001be34 && prevPc /= 0x8001be34) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-SWUS] cycle=" ++ show cycs
          ++ " entered_via_prev_pc=0x" ++ showHex prevPc "")
    -- Task #55: detect entry to __stack_chk_fail (PC = 0x801ec24c).
    -- This is the canary-fail tripwire — we want to dump the ring
    -- buffer at this moment because the LWs that decided "canary
    -- mismatched" happened in the cycles just before. Trigger this
    -- ONCE (track via prevPc to avoid re-firing on each cycle while
    -- F-stage holds at 0x801ec24c).
    when (pc == 0x801ec24c && prevPc /= 0x801ec24c) $ do
      liftIO $ hPutStrLn stderr
        ("[STACK-CHK-FAIL] cycle=" ++ show cycs
          ++ " entered __stack_chk_fail from prev_pc=0x" ++ showHex prevPc "")
      ring <- liftIO $ readIORef ringRef
      liftIO $ hPutStrLn stderr "  --- last 5000 cycles before __stack_chk_fail (RLE-compressed) ---"
      liftIO $ hPutStrLn stderr "  cycleStart..cycleEnd  pc  dmem  bridge  sp  s0  ra"
      let dumpRle' [] = pure ()
          dumpRle' ((c0, p0, dr0, br0, sp0, s00, ra0) : rest) =
            let key = (p0, dr0, br0, sp0, s00, ra0)
                sameKey (_, p, dr, br, sp, s0, ra) = (p, dr, br, sp, s0, ra) == key
                (group, after) = span sameKey rest
                cEnd = case group of
                  [] -> c0
                  _ -> case last group of (c, _, _, _, _, _, _) -> c
             in do
                  liftIO $ hPutStrLn stderr
                    ("  " ++ show c0 ++ ".." ++ show cEnd
                      ++ " 0x" ++ showHex p0 ""
                      ++ " dmem=0x" ++ showHex dr0 ""
                      ++ " bridge=0x" ++ showHex br0 ""
                      ++ " sp=0x" ++ showHex sp0 ""
                      ++ " s0=0x" ++ showHex s00 ""
                      ++ " ra=0x" ++ showHex ra0 "")
                  dumpRle' after
      dumpRle' (reverse (toList ring))
    -- Detect when PC drops from kernel (0x8xxxxxxx) back to firmware
    -- (low BRAM addresses). That's a CPU-reset event — the kernel
    -- triggered a reset somehow.
    when (prevPc >= 0x80000000 && pc < 0x10000 && cycs > 1000000) $ do
      liftIO $ hPutStrLn stderr
        ("[CPU-RESET] cycle=" ++ show cycs
          ++ " from kernel pc=0x" ++ showHex prevPc ""
          ++ " to firmware pc=0x" ++ showHex pc "")
      -- Task #55: dump the rolling buffer so we can see what data the
      -- core was loading just before ret jumped to 0. Compress
      -- consecutive identical (pc, dmem, bridge, sp, s0) tuples into
      -- a single line with a cycle range — keeps the dump readable
      -- when the core stalls for hundreds of cycles on one PC.
      ring <- liftIO $ readIORef ringRef
      liftIO $ hPutStrLn stderr "  --- last 5000 cycles before CPU-RESET (RLE-compressed) ---"
      liftIO $ hPutStrLn stderr "  cycleStart..cycleEnd  pc  dmem  bridge  sp  s0  ra"
      let dumpRle [] = pure ()
          dumpRle ((c0, p0, dr0, br0, sp0, s00, ra0) : rest) =
            let key = (p0, dr0, br0, sp0, s00, ra0)
                sameKey (_, p, dr, br, sp, s0, ra) = (p, dr, br, sp, s0, ra) == key
                (group, after) = span sameKey rest
                cEnd = case group of
                  [] -> c0
                  _ -> case last group of (c, _, _, _, _, _, _) -> c
             in do
                  liftIO $ hPutStrLn stderr
                    ("  " ++ show c0 ++ ".." ++ show cEnd
                      ++ " 0x" ++ showHex p0 ""
                      ++ " dmem=0x" ++ showHex dr0 ""
                      ++ " bridge=0x" ++ showHex br0 ""
                      ++ " sp=0x" ++ showHex sp0 ""
                      ++ " s0=0x" ++ showHex s00 ""
                      ++ " ra=0x" ++ showHex ra0 "")
                  dumpRle after
      dumpRle (reverse (toList ring))
    -- Detect entries to earlycon-related kernel functions to find
    -- where the chain breaks.
    when (pc == 0x8020a584 && prevPc /= 0x8020a584) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-SETUP-EARLYCON] cycle=" ++ show cycs
          ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x8020a858 && prevPc /= 0x8020a858) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-PARAM-SETUP-EARLYCON] cycle=" ++ show cycs
          ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x8020a8f4 && prevPc /= 0x8020a8f4) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-OF-SETUP-EARLYCON] cycle=" ++ show cycs
          ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x8020b274 && prevPc /= 0x8020b274) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-JTAGUART-EARLYCON] cycle=" ++ show cycs
          ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x8020e450 && prevPc /= 0x8020e450) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-DT-CHOSEN-STDOUT] cycle=" ++ show cycs
          ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x8020e9dc && prevPc /= 0x8020e9dc) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-DT-CHOSEN] cycle=" ++ show cycs
          ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x801f2f3c && prevPc /= 0x801f2f3c) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-START-KERNEL] cycle=" ++ show cycs
          ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x801f73c8 && prevPc /= 0x801f73c8) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-SETUP-ARCH] cycle=" ++ show cycs
          ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x80002b44 && prevPc /= 0x80002b44) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-PRINTK] cycle=" ++ show cycs
          ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x800013b4 && prevPc /= 0x800013b4) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-WARN-PRINTK] cycle=" ++ show cycs
          ++ " from prev=0x" ++ showHex prevPc "")
    -- Task #64: trace completion / wakeup / kthread path. The 1B-cycle
    -- cpio run showed kernel_init blocked in wait_for_completion
    -- (&kthreadd_done) and never reaching kernel_init_freeable. We
    -- need to know whether complete() ever fires for that completion,
    -- whether kthreadd actually starts, and whether wakeups propagate
    -- through __wake_up. PC addresses from vmlinux symbols
    -- (riski5-linux-rv32-nommu-6.18.22):
    --   complete                         0x80052a30
    --   complete_all                     0x80054370
    --   __wake_up                        0x8005156c
    --   __wake_up_common                 0x80051434
    --   __wake_up_common_lock            0x80051514
    --   try_to_wake_up                   0x8003cd44
    --   wake_up_process                  0x8003cfb0
    --   wake_up_new_task                 0x8003d500
    --   kthreadd                         0x800321a8
    --   wait_for_completion              0x801ee330
    --   rest_init                        0x801ec6c8
    when (pc == 0x80052a30 && prevPc /= 0x80052a30) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-COMPLETE] cycle=" ++ show cycs
          ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x80054370 && prevPc /= 0x80054370) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-COMPLETE-ALL] cycle=" ++ show cycs
          ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x8005156c && prevPc /= 0x8005156c) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-WAKE-UP] cycle=" ++ show cycs
          ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x8003cd44 && prevPc /= 0x8003cd44) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-TRY-TO-WAKE-UP] cycle=" ++ show cycs
          ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x8003cfb0 && prevPc /= 0x8003cfb0) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-WAKE-UP-PROCESS] cycle=" ++ show cycs
          ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x8003d500 && prevPc /= 0x8003d500) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-WAKE-UP-NEW-TASK] cycle=" ++ show cycs
          ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x800321a8 && prevPc /= 0x800321a8) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-KTHREADD] cycle=" ++ show cycs
          ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x801ee330 && prevPc /= 0x801ee330) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-WAIT-FOR-COMPLETION] cycle=" ++ show cycs
          ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x801ec6c8 && prevPc /= 0x801ec6c8) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-REST-INIT] cycle=" ++ show cycs
          ++ " from prev=0x" ++ showHex prevPc "")
    -- Task #55: sample sp at the canary save vs check PCs. Widen
    -- the match to a small range around the actual instruction
    -- PCs to handle pipeline slip; edge-detect on the WHOLE range
    -- entry so we get one log per visit.
    let inSave  = pc >= 0x801dc378 && pc <= 0x801dc380
        inCheck = pc >= 0x801dc38c && pc <= 0x801dc394
        prevInSave  = prevPc >= 0x801dc378 && prevPc <= 0x801dc380
        prevInCheck = prevPc >= 0x801dc38c && prevPc <= 0x801dc394
    when (inSave && not prevInSave) $
      liftIO $ hPutStrLn stderr
        ("[SP-SAVE] cycle=" ++ show cycs
          ++ " pc=0x" ++ showHex pc ""
          ++ " sp=0x" ++ showHex (sDebugSp s) ""
          ++ " s0=0x" ++ showHex (sDebugS0 s) "")
    when (inCheck && not prevInCheck) $
      liftIO $ hPutStrLn stderr
        ("[SP-CHECK] cycle=" ++ show cycs
          ++ " pc=0x" ++ showHex pc ""
          ++ " sp=0x" ++ showHex (sDebugSp s) ""
          ++ " s0=0x" ++ showHex (sDebugS0 s) "")
    -- Also detect ANY major PC region change (kernel ↔ firmware)
    -- to catch jumps/redirects.
    when (prevPc >= 0x80000000 && pc < 0x80000000 && pc /= prevPc && cycs > 1000000) $
      liftIO $ hPutStrLn stderr
        ("[PC-DROP] cycle=" ++ show cycs
          ++ " kernel pc=0x" ++ showHex prevPc ""
          ++ " → low pc=0x" ++ showHex pc "")
    -- Detect entry to __send_signal_locked (the trigger one level
    -- up the call chain).
    when (pc == 0x8001c400 && prevPc /= 0x8001c400) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-SSL] cycle=" ++ show cycs
          ++ " entered_via_prev_pc=0x" ++ showHex prevPc "")
    -- Detect entry to send_signal_locked (one more level up).
    -- Also instrument force_sig_info_to_task (0x8001dfc4),
    -- force_sig_fault (0x8001e870), force_sigsegv (0x8001e6a4).
    when (pc == 0x8001dfc4 && prevPc /= 0x8001dfc4) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-FSITT] cycle=" ++ show cycs
          ++ " entered_via_prev_pc=0x" ++ showHex prevPc "")
    when (pc == 0x8001e870 && prevPc /= 0x8001e870) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-FSF] cycle=" ++ show cycs
          ++ " entered_via_prev_pc=0x" ++ showHex prevPc "")
    when (pc == 0x8001e6a4 && prevPc /= 0x8001e6a4) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-FSSEGV] cycle=" ++ show cycs
          ++ " entered_via_prev_pc=0x" ++ showHex prevPc "")
    -- Detect entry to handle_exception (the kernel's trap entry).
    when (pc == 0x801f22b4 && prevPc /= 0x801f22b4) $
      liftIO $ hPutStrLn stderr
        ("[CALLED-HE] cycle=" ++ show cycs
          ++ " entered_via_prev_pc=0x" ++ showHex prevPc "")
    -- Detect entries to do_trap_* functions.
    when (pc == 0x80009d18 && prevPc /= 0x80009d18) $
      liftIO $ hPutStrLn stderr
        ("[TRAP-ERROR] cycle=" ++ show cycs ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x80009d7c && prevPc /= 0x80009d7c) $
      liftIO $ hPutStrLn stderr
        ("[TRAP-MISALIGNED] cycle=" ++ show cycs ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x801ebcc8 && prevPc /= 0x801ebcc8) $
      liftIO $ hPutStrLn stderr
        ("[TRAP-STORE-FAULT] cycle=" ++ show cycs ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x801ebc94 && prevPc /= 0x801ebc94) $
      liftIO $ hPutStrLn stderr
        ("[TRAP-STORE-MISALIGN] cycle=" ++ show cycs ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x801eb878 && prevPc /= 0x801eb878) $
      liftIO $ hPutStrLn stderr
        ("[TRAP-UNKNOWN] cycle=" ++ show cycs ++ " from prev=0x" ++ showHex prevPc "")
    when (pc == 0x80009c28 && prevPc /= 0x80009c28) $
      liftIO $ hPutStrLn stderr
        ("[DO-TRAP] cycle=" ++ show cycs ++ " from prev=0x" ++ showHex prevPc "")
    -- Sanity: log first visits to a BROADER kernel range we expect
    -- the kernel to visit during early init (anywhere in 0x8001b
    -- range = ~256 KB of kernel code). If THIS never fires either,
    -- the kernel's PC range must be somewhere else entirely.
    when (cycs == 5_000_000) $
      liftIO $ hPutStrLn stderr
        ("[CHECKPOINT] cycle=5M pc=0x" ++ showHex pc "")
    when (cycs == 10_000_000) $
      liftIO $ hPutStrLn stderr
        ("[CHECKPOINT] cycle=10M pc=0x" ++ showHex pc "")
    when (cycs == 15_000_000) $
      liftIO $ hPutStrLn stderr
        ("[CHECKPOINT] cycle=15M pc=0x" ++ showHex pc "")
    if sUartTxValid s /= 0
      then do
        let b = sUartTxByte s
        liftIO $ do
          -- Stream UART byte directly to disk (uartLogHandle, line-
          -- buffered) — bounded ~constant memory regardless of cycle
          -- count. Replaces the prior `bufRef <> word8 b` Builder
          -- accumulator that retained every byte for end-of-run dump.
          BS.hPut uartLogHandle (BS.singleton b)
          modifyIORef' uartByteCountRef (+ 1)
        go (k - 1) (cycs + 1) pc prevSpRef prevRaRef ringRef
      else go (k - 1) (cycs + 1) pc prevSpRef prevRaRef ringRef

-- * Entry point ------------------------------------------------------

main :: IO ()
main = do
  args <- getArgs
  case args of
    [k, d] -> runHwsim k d Nothing 5_000_000
    [k, d, n] -> runHwsim k d Nothing (read n)
    [k, d, n, c] -> runHwsim k d (Just c) (read n)
    _ -> do
      hPutStrLn stderr "usage: riski5-linux-hwsim KERNEL DTB [MAX_STEPS [CPIO]]"
      hPutStrLn stderr "  CPIO is loaded at 0x80700000 (must match the DTB's"
      hPutStrLn stderr "  chosen.linux,initrd-start property — change DTS to"
      hPutStrLn stderr "  point initrd at 0x80700000 if you supply this)."
      exitFailure

runHwsim :: FilePath -> FilePath -> Maybe FilePath -> Int -> IO ()
runHwsim kPath dPath mCpioPath maxSteps = do
  hPutStrLn stderr $
    "linux-hwsim: kernel="
      ++ kPath
      ++ " dtb="
      ++ dPath
      ++ maybe "" (\p -> " cpio=" ++ p) mCpioPath
      ++ " max-steps="
      ++ show maxSteps
  kernel <- BS.readFile kPath
  dtb <- BS.readFile dPath
  mCpio <- traverse BS.readFile mCpioPath
  hPutStrLn stderr $
    "  loading "
      ++ show (BS.length kernel)
      ++ "-byte kernel @ 0x80000000 + "
      ++ show (BS.length dtb)
      ++ "-byte DTB @ 0x80400000"
      ++ maybe "" (\bs -> " + " ++ show (BS.length bs) ++ "-byte cpio @ 0x80700000") mCpio
      ++ " ..."
  -- Stream UART bytes to disk (riski5-linux-hwsim.uart.bin) instead
  -- of accumulating them in a Builder. This was the second-largest
  -- heap cost in long Linux-boot runs (Builder retained every byte
  -- ever emitted for the end-of-run summary; for a verbose Linux
  -- boot with thousands of printks that's MBs that shouldn't be
  -- pinned). The `uartByteCountRef` retains just the count; the
  -- end-of-run summary reads the tail of the file for "last printk".
  uartLogPath <- pure ("riski5-linux-hwsim.uart.bin" :: FilePath)
  uartLogHandle <- openBinaryFile uartLogPath WriteMode
  -- NoBuffering so each UART byte hits disk immediately. The kernel
  -- emits ~one byte every several thousand cycles (printk rate-
  -- limited by JTAG-UART FIFO drain), so per-byte syscall overhead
  -- is irrelevant. Critical: a SIGKILL in mid-run still leaves a
  -- coherent on-disk view of every byte the sim emitted up to that
  -- moment, instead of losing the last 4 KB of Haskell buffer.
  hSetBuffering uartLogHandle NoBuffering
  uartByteCountRef <- newIORef (0 :: Int)
  pcRef <- newIORef Map.empty
  -- Strict-spine Seq for cycle/PC snapshots — avoids the lazy-list
  -- thunk pile-up the rolling-cons pattern produces.
  snapsRef <- newIORef (Seq.empty :: Seq (Int, Word32))
  rdataRef <- newIORef Map.empty
  bridgeRdataRef <- newIORef Map.empty
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
    mapM_ (loadWords 0x8070_0000) mCpio
    -- A few quiet cycles so the SDRAM chip's pre-load writes
    -- settle before reset releases.
    clockCycle
    clockCycle
    -- Release all three resets in lockstep.
    modifyState $ \s -> s {sRstN = 1, sRstCoreN = 1, sRstSdramN = 1}
    runUartStream maxSteps uartLogHandle uartByteCountRef pcRef snapsRef rdataRef bridgeRdataRef
  -- Flush + close the UART log so end-of-run reads see all bytes.
  hClose uartLogHandle
  byteCount <- readIORef uartByteCountRef
  pcMap <- readIORef pcRef
  snaps <- readIORef snapsRef
  rdataMap <- readIORef rdataRef
  -- Read just the last 4 KB of the UART log to find the most recent
  -- printk. Bounded memory regardless of total log size.
  bytes <- do
    h <- openBinaryFile uartLogPath ReadMode
    sz <- hFileSize h
    let tailLen = min 4096 (fromInteger sz :: Int)
    hSeek h SeekFromEnd (negate (fromIntegral tailLen))
    tailBs <- BS.hGet h tailLen
    hClose h
    pure (BS.unpack tailBs)
  hPutStrLn stderr ""
  hPutStrLn stderr "--- linux-hwsim done ---"
  hPutStrLn stderr $ "  cycles : " ++ show cycles
  hPutStrLn stderr $ "  uart-tx: " ++ show byteCount ++ " bytes (full stream → " ++ uartLogPath ++ ")"
  case lastNonNullPrintk bytes of
    Just s -> hPutStrLn stderr $ "  last printk: " ++ s
    Nothing -> hPutStrLn stderr "  (no printk emitted)"
  hPutStrLn stderr ""
  hPutStrLn stderr "--- Top-20 PC histogram (where the core spent its time) ---"
  let topPcs =
        take 20 $
          sortBy (comparing (Down . snd)) (Map.toList pcMap)
      total = sum (Map.elems pcMap)
  mapM_
    ( \(pc, n) ->
        hPutStrLn stderr $
          "  0x" ++ pad8 (showHex pc "")
            ++ "  "
            ++ show n
            ++ " cycles ("
            ++ show ((n * 100) `div` max 1 total)
            ++ "%)"
    )
    topPcs
  -- Also report regional breakdown of where time was spent.
  let regionOf pc
        | pc < 0x1000_0000 = "BRAM (0x0000_0000)"
        | pc < 0x2000_0000 = "MMIO (0x1000_0000)"
        | pc < 0x8000_0000 = "SRAM (0x2000_0000)"
        | otherwise = "SDRAM (0x8000_0000+)"
      regions =
        Map.toList $
          Map.fromListWith (+) [(regionOf pc, n) | (pc, n) <- Map.toList pcMap]
  hPutStrLn stderr ""
  hPutStrLn stderr "--- Time spent per memory region ---"
  mapM_
    ( \(r, n) ->
        hPutStrLn stderr $
          "  " ++ r
            ++ ": "
            ++ show n
            ++ " cycles ("
            ++ show ((n * 100) `div` max 1 total)
            ++ "%)"
    )
    (sortBy (comparing (Down . snd)) regions)
  hPutStrLn stderr ""
  hPutStrLn stderr "--- PC snapshot every 100k cycles ---"
  mapM_
    ( \(c, pc) ->
        hPutStrLn stderr $
          "  cycle " ++ show c ++ ": PC = 0x" ++ pad8 (showHex pc "")
    )
    (toList snaps)
  hPutStrLn stderr ""
  hPutStrLn stderr "--- BUS-side DMEM rdata histogram at PC=0x801ec46c (LW in X-stage) ---"
  printRdataHistogram rdataMap
  bridgeRdataMap <- readIORef bridgeRdataRef
  hPutStrLn stderr ""
  hPutStrLn stderr "--- BRIDGE-captured DMEM rdata histogram at PC=0x801ec46c (LW in X-stage) ---"
  printRdataHistogram bridgeRdataMap
  where
    pad8 :: String -> String
    pad8 s = replicate (8 - length s) '0' ++ s
    printRdataHistogram m =
      if Map.null m
        then hPutStrLn stderr "  (kernel never reached PC=0x801ec468)"
        else
          mapM_
            ( \(rdata, n) ->
                hPutStrLn stderr $
                  "  rdata = 0x" ++ pad8 (showHex rdata "")
                    ++ "  ("
                    ++ show n
                    ++ " samples)"
            )
            (sortBy (comparing (Down . snd)) (Map.toList m))

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
