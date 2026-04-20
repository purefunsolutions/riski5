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
  { -- 32-bit ports
    sSw :: !Word32
  , sLedr :: !Word32
  , sSramAddr :: !Word32
  , -- 16-bit ports
    sSramDqIn :: !Word16
  , sLedg :: !Word16
  , sSramDqOut :: !Word16
  , -- 8-bit ports
    sClk :: !Word8
  , sRstN :: !Word8
  , sKey :: !Word8
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
  sizeOf _ = 36
  alignment _ = 4
  peek p = do
    sw <- peekByteOff p 0
    ledr <- peekByteOff p 4
    sramAddr <- peekByteOff p 8
    sramDqIn <- peekByteOff p 12
    ledg <- peekByteOff p 14
    sramDqOut <- peekByteOff p 16
    clk <- peekByteOff p 18
    rstN <- peekByteOff p 19
    key <- peekByteOff p 20
    lcdData <- peekByteOff p 21
    lcdRs <- peekByteOff p 22
    lcdRw <- peekByteOff p 23
    lcdEn <- peekByteOff p 24
    lcdOn <- peekByteOff p 25
    lcdBlon <- peekByteOff p 26
    sramDqOe <- peekByteOff p 27
    sramCeN <- peekByteOff p 28
    sramOeN <- peekByteOff p 29
    sramWeN <- peekByteOff p 30
    sramUbN <- peekByteOff p 31
    sramLbN <- peekByteOff p 32
    txValid <- peekByteOff p 33
    txByte <- peekByteOff p 34
    pure
      Riski5SimTopState
        { sSw = sw
        , sLedr = ledr
        , sSramAddr = sramAddr
        , sSramDqIn = sramDqIn
        , sLedg = ledg
        , sSramDqOut = sramDqOut
        , sClk = clk
        , sRstN = rstN
        , sKey = key
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
    pokeByteOff p 0 sSw
    pokeByteOff p 4 sLedr
    pokeByteOff p 8 sSramAddr
    pokeByteOff p 12 sSramDqIn
    pokeByteOff p 14 sLedg
    pokeByteOff p 16 sSramDqOut
    pokeByteOff p 18 sClk
    pokeByteOff p 19 sRstN
    pokeByteOff p 20 sKey
    pokeByteOff p 21 sLcdData
    pokeByteOff p 22 sLcdRs
    pokeByteOff p 23 sLcdRw
    pokeByteOff p 24 sLcdEn
    pokeByteOff p 25 sLcdOn
    pokeByteOff p 26 sLcdBlon
    pokeByteOff p 27 sSramDqOe
    pokeByteOff p 28 sSramCeN
    pokeByteOff p 29 sSramOeN
    pokeByteOff p 30 sSramWeN
    pokeByteOff p 31 sSramUbN
    pokeByteOff p 32 sSramLbN
    pokeByteOff p 33 sUartTxValid
    pokeByteOff p 34 sUartTxByte

-- * Backend wiring

initialState :: Riski5SimTopState
initialState =
  Riski5SimTopState
    { sSw = 0
    , sLedr = 0
    , sSramAddr = 0
    , sSramDqIn = 0
    , sLedg = 0
    , sSramDqOut = 0
    , sClk = 0
    , sRstN = 0
    , sKey = 0
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

{- | Advance one full simulation period: drive @clk@ low, eval, drive
@clk@ high, eval. The rising edge on the second eval is what
triggers all synchronous logic (core, IP, TX-tap register).
-}
clockCycle :: SimM Riski5SimTopPorts Riski5SimTopState ()
clockCycle = do
  modifyState $ \s -> s {sClk = 0}
  tick
  modifyState $ \s -> s {sClk = 1}
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
its 13-byte UART greeting. At Dom30 the firmware needs a few
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
          pokeState initialState {sClk = 0, sRstN = 0, sKey = 0xF}
          clockCycle
          clockCycle
          clockCycle
          clockCycle
          modifyState $ \s -> s {sRstN = 1}
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
