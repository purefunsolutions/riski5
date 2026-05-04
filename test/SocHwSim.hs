-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : SocHwSim
Description : Verilator-backed whole-SoC simulation tests.

Layer 1.75 of @docs\/verification.md@: the Clash-emitted @riski5@
plus the ip-generate-emitted @riski5_jtag_uart@ IP are compiled
together under Verilator and driven from here via
[verilambda](https:\/\/github.com\/purefunsolutions\/verilambda).
The whole point is to catch peripheral-protocol bugs that our
pure-Clash @jtagUartSim@ model cannot see — most notably the
Altera IP's 1-cycle registered-write semantics which bit us in
T19-continued on real silicon (see commit 1cf99a1 for the stall
fix).

Built only when the @hwsim@ cabal flag is on:

> cabal test --flag=hwsim

which additionally requires @RISKI5_SIM_LIB_DIR@ in the
environment, pointing at @\<riski5-sim-output\>\/lib@ (produced
by @nix build .#riski5-sim@). Without the flag this module is a
no-op test placeholder so the regular @cabal test@ flow works on
any machine, Verilator or not.
-}
module SocHwSim (
  tests,
) where

#ifdef HWSIM

import Control.Monad.IO.Class (liftIO)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Kind (Type)
import Data.Word (Word16, Word32, Word8)
import Foreign.Ptr (Ptr)
import Foreign.Storable (Storable (..))
import GHC.Generics (Generic)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase)
import Verilambda (
  SimBackend (..),
  SimM,
  modifyState,
  peekState,
  pokeState,
  runSim,
  tick,
 )

-- * FFI — hand-written bindings to the verilambda-shim-gen output.
-- The shim is produced at @nix build .#riski5-sim@ time from
-- @pkgs\/riski5-sim\/clash-manifest.json@; its ABI is
-- @verilambda_riski5_sim_top_state_t@ whose fields are laid out in
-- the order of @ports_flat@ (see the manifest).

foreign import ccall unsafe "verilambda_riski5_sim_top_new"
  c_sim_new :: IO (Ptr ())

foreign import ccall unsafe "verilambda_riski5_sim_top_delete"
  c_sim_delete :: Ptr () -> IO ()

foreign import ccall unsafe "verilambda_riski5_sim_top_step"
  c_sim_step :: Ptr () -> Ptr Riski5SimTopState -> Ptr Riski5SimTopState -> IO ()

foreign import ccall unsafe "verilambda_riski5_sim_top_final"
  c_sim_final :: Ptr () -> IO ()

-- * HKD port record
--
-- Phantom index for @SimM@'s type parameter. The shim is
-- pre-generated from the JSON manifest so we don't need the
-- @Ports@ Generics walk at runtime; this empty record exists only
-- to carry kind @(Type -> Type) -> Type@ for 'SimBackend'.

data Riski5SimTopPorts (f :: Type -> Type) = Riski5SimTopPorts
  deriving stock (Generic)

-- * C-ABI state struct
--
-- Mirrors @verilambda_riski5_sim_top_state_t@ bit-for-bit. Field
-- order must match @ports_flat@ in
-- @pkgs\/riski5-sim\/clash-manifest.json@. We ordered the manifest
-- so 32-bit fields come first, then 16-bit, then 8-bit — eliminating
-- all internal padding so the byte offsets below are a flat
-- sequence. Only 1 byte of trailing padding separates the last
-- field at offset 34 from the @sizeOf = 36@ multiple-of-alignment.

data Riski5SimTopState = Riski5SimTopState
  { -- 32-bit ports (offsets 0..23)
    sMemInitAddr :: !Word32
  , sSw :: !Word32
  , sLedr :: !Word32
  , sSramAddr :: !Word32
  , sDebugPcfetch :: !Word32
  , sDebugDmemRdata :: !Word32
  , -- 16-bit ports (offsets 24..31)
    sMemInitData :: !Word16
  , sSramDqIn :: !Word16
  , sLedg :: !Word16
  , sSramDqOut :: !Word16
  , -- 8-bit ports (offsets 32..53). Phase E-b adds clk_core /
    -- rst_core_n / clk_sdram / rst_sdram_n at offsets 34..37 so the
    -- harness can drive each Clash domain's clock independently.
    sClk :: !Word8 -- bus-domain clock
  , sRstN :: !Word8 -- bus-domain reset (active low)
  , sClkCore :: !Word8
  , sRstCoreN :: !Word8
  , sClkSdram :: !Word8
  , sRstSdramN :: !Word8
  , sKey :: !Word8
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
  sizeOf _ = 56 -- 54 bytes of fields, padded to alignment 4
  alignment _ = 4
  peek p = do
    memInitAddr <- peekByteOff p 0
    sw <- peekByteOff p 4
    ledr <- peekByteOff p 8
    sramAddr <- peekByteOff p 12
    debugPcfetch <- peekByteOff p 16
    debugDmemRdata <- peekByteOff p 20
    memInitData <- peekByteOff p 24
    sramDqIn <- peekByteOff p 26
    ledg <- peekByteOff p 28
    sramDqOut <- peekByteOff p 30
    clk <- peekByteOff p 32
    rstN <- peekByteOff p 33
    clkCore <- peekByteOff p 34
    rstCoreN <- peekByteOff p 35
    clkSdram <- peekByteOff p 36
    rstSdramN <- peekByteOff p 37
    key <- peekByteOff p 38
    memInitWrite <- peekByteOff p 39
    lcdData <- peekByteOff p 40
    lcdRs <- peekByteOff p 41
    lcdRw <- peekByteOff p 42
    lcdEn <- peekByteOff p 43
    lcdOn <- peekByteOff p 44
    lcdBlon <- peekByteOff p 45
    sramDqOe <- peekByteOff p 46
    sramCeN <- peekByteOff p 47
    sramOeN <- peekByteOff p 48
    sramWeN <- peekByteOff p 49
    sramUbN <- peekByteOff p 50
    sramLbN <- peekByteOff p 51
    txValid <- peekByteOff p 52
    txByte <- peekByteOff p 53
    pure
      Riski5SimTopState
        { sMemInitAddr = memInitAddr
        , sSw = sw
        , sLedr = ledr
        , sSramAddr = sramAddr
        , sDebugPcfetch = debugPcfetch
        , sDebugDmemRdata = debugDmemRdata
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
        , sUartTxValid = txValid
        , sUartTxByte = txByte
        }
  poke p Riski5SimTopState {..} = do
    pokeByteOff p 0 sMemInitAddr
    pokeByteOff p 4 sSw
    pokeByteOff p 8 sLedr
    pokeByteOff p 12 sSramAddr
    pokeByteOff p 16 sDebugPcfetch
    pokeByteOff p 20 sDebugDmemRdata
    pokeByteOff p 24 sMemInitData
    pokeByteOff p 26 sSramDqIn
    pokeByteOff p 28 sLedg
    pokeByteOff p 30 sSramDqOut
    pokeByteOff p 32 sClk
    pokeByteOff p 33 sRstN
    pokeByteOff p 34 sClkCore
    pokeByteOff p 35 sRstCoreN
    pokeByteOff p 36 sClkSdram
    pokeByteOff p 37 sRstSdramN
    pokeByteOff p 38 sKey
    pokeByteOff p 39 sMemInitWrite
    pokeByteOff p 40 sLcdData
    pokeByteOff p 41 sLcdRs
    pokeByteOff p 42 sLcdRw
    pokeByteOff p 43 sLcdEn
    pokeByteOff p 44 sLcdOn
    pokeByteOff p 45 sLcdBlon
    pokeByteOff p 46 sSramDqOe
    pokeByteOff p 47 sSramCeN
    pokeByteOff p 48 sSramOeN
    pokeByteOff p 49 sSramWeN
    pokeByteOff p 50 sSramUbN
    pokeByteOff p 51 sSramLbN
    pokeByteOff p 52 sUartTxValid
    pokeByteOff p 53 sUartTxByte

-- * Backend wiring

initialState :: Riski5SimTopState
initialState =
  Riski5SimTopState
    { sMemInitAddr = 0
    , sSw = 0
    , sLedr = 0
    , sSramAddr = 0
    , sDebugPcfetch = 0
    , sDebugDmemRdata = 0
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
    , sKey = 0
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

-- * Clock / testbench primitives

{- | Advance one full simulation period for ALL THREE Clash domains
in lockstep — single-clock simplification. Drive @clk@ /
@clk_core@ / @clk_sdram@ low, eval, drive them high, eval. The
rising edge on the second eval triggers all synchronous logic
(core, IP, TX-tap register). The bridges still run their CDC FSMs
at minimum latency since they're synchronizers regardless of
source/dest clock equality.
-}
clockCycle :: SimM Riski5SimTopPorts Riski5SimTopState ()
clockCycle = do
  modifyState $ \s -> s {sClk = 0, sClkCore = 0, sClkSdram = 0}
  tick
  modifyState $ \s -> s {sClk = 1, sClkCore = 1, sClkSdram = 1}
  tick

{- | Simulate for up to @n@ clock periods while collecting every
byte the UART TX tap commits. Early-exits as soon as we've
gathered @stopAt@ bytes so a passing run doesn't waste cycles on
the rest of Hello's SRAM-test / LCD-write path. Returns the
collected bytes in firmware-emission order, plus the final
cycle count for diagnostics.
-}
runUartCollect ::
  -- | maximum cycles
  Int ->
  -- | stop once we've seen this many bytes
  Int ->
  SimM Riski5SimTopPorts Riski5SimTopState ([Word8], Int)
runUartCollect n stopAt = do
  bufRef <- liftIO (newIORef ([] :: [Word8]))
  let go 0 cycs = pure cycs
      go k cycs = do
        clockCycle
        s <- peekState
        cycsNew <-
          if sUartTxValid s /= 0
            then do
              liftIO (modifyIORef' bufRef (sUartTxByte s :))
              pure (cycs + 1)
            else pure (cycs + 1)
        collected <- liftIO (readIORef bufRef)
        if length collected >= stopAt
          then pure cycsNew
          else go (k - 1) cycsNew
  elapsed <- go n 0
  collected <- liftIO (readIORef bufRef)
  pure (reverse collected, elapsed)

-- * The test itself

{- | Generous cycle budget for the Hello firmware to boot and stream
its 13-byte UART greeting. At DomBus the firmware needs a few
hundred cycles per byte (IP stall + poll loop), so a 200k budget
gives ~15× headroom before the test times out.
-}
testCycleBudget :: Int
testCycleBudget = 200_000

expectedHello :: [Word8]
expectedHello =
  fmap (fromIntegral . fromEnum) ("hello, world\n" :: String)

tests :: TestTree
tests =
  testGroup
    "Riski5.SoC Verilator simulation"
    [ testCase "UART TX stream begins with 'hello, world\\n'" $ do
        (bytes, elapsed) <- runSim riski5Backend $ do
          -- Hold reset low through the first few cycles so the
          -- DUT's async-reset polarity (ActiveLow) triggers the
          -- reset path, then release. Keys default to all-released
          -- (active-low on the DE2, so 0xF). Switches left at 0.
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
          clockCycle
          clockCycle
          modifyState $ \s ->
            s {sRstN = 1, sRstCoreN = 1, sRstSdramN = 1}
          runUartCollect testCycleBudget (length expectedHello)
        let prefix = take (length expectedHello) bytes
            rendered = fmap (toEnum . fromIntegral) bytes :: String
            info =
              "collected "
                <> show (length bytes)
                <> " bytes in "
                <> show elapsed
                <> " cycles: "
                <> show rendered
                <> " (raw "
                <> show bytes
                <> "); expected prefix "
                <> show expectedHello
        assertBool
          ("UART TX stream must begin with 'hello, world\\n'. " <> info)
          (prefix == expectedHello)
    ]

#else

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)

tests :: TestTree
tests =
  testGroup
    "Riski5.SoC Verilator simulation (disabled — cabal --flag=hwsim to enable)"
    [ testCase "placeholder" (pure ())
    ]

#endif
