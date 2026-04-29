-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
--
-- Smoke test for Riski5.JtagAvalonMaster.step (task #133).
--
-- Drives the FSM with a single write packet (0x04 = WRITE_INCR,
-- 4 bytes, address 0x80000000, data 0xDEADBEEF) and prints the
-- master-side outputs each cycle. Fails fast (printed to stderr +
-- exitFailure) if the expected write transaction never appears.
--
-- Run: nix develop -c cabal exec runghc scripts/jam-fsm-smoke.hs
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Main where

import Clash.Prelude (BitVector)
import Clash.Prelude qualified as C
import Data.Foldable (for_)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Riski5.JtagAvalonMaster
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)
import Prelude

idleI :: InS
idleI =
  InS
    { iInValid = False
    , iInData = 0
    , iInSop = False
    , iInEop = False
    , iOutReady = True
    , iReaddata = 0
    , iWaitreq = False
    , iReaddataVld = False
    }

byteI :: BitVector 8 -> Bool -> Bool -> InS
byteI b sop eop =
  idleI
    { iInValid = True
    , iInData = b
    , iInSop = sop
    , iInEop = eop
    }

-- Write packet: cmd=0x04 (WRITE_INCR), extra, size_hi, size_lo,
-- addr[31:24], [23:16], [15:8], [7:0], then 4 data bytes
-- (little-endian: 0xEF 0xBE 0xAD 0xDE for value 0xDEADBEEF).
-- size is unused for writes (counter stays 0).
writePacket :: [InS]
writePacket =
  [ byteI 0x04 True False -- SOP + cmd
  , byteI 0xff False False -- extra
  , byteI 0x00 False False -- size_hi (ignored)
  , byteI 0x00 False False -- size_lo (ignored)
  , byteI 0x80 False False -- addr [31:24]
  , byteI 0x00 False False -- addr [23:16]
  , byteI 0x00 False False -- addr [15:8]
  , byteI 0x00 False False -- addr [7:0]
  , byteI 0xEF False False -- data byte 0
  , byteI 0xBE False False -- data byte 1
  , byteI 0xAD False False -- data byte 2
  , byteI 0xDE False True -- data byte 3 + EOP
  ]

main :: IO ()
main = do
  sRef <- newIORef initS
  -- Bytes pending to feed: as long as in_ready was high last cycle,
  -- consume one byte per cycle. (Mirrors the Avalon-ST handshake.)
  pendingRef <- newIORef writePacket
  observedWrite <- newIORef False
  observedAddr <- newIORef (0 :: BitVector 32)
  observedData <- newIORef (0 :: BitVector 32)
  observedBe <- newIORef (0 :: BitVector 4)

  for_ [0 .. (200 :: Int)] $ \cyc -> do
    s <- readIORef sRef
    pending <- readIORef pendingRef
    let
      iNow =
        if sInReady s
          then case pending of
            (b : _) -> b
            [] -> idleI
          else idleI
      -- Honour Avalon-MM waitrequest=0 (slave always ready)
      -- For PWriteWait → assume slave accepts immediately.
      sNext = step s iNow
    -- Consume the byte iff it was actually transferred this cycle.
    if sInReady s && iInValid iNow
      then case pending of
        (_ : rest) -> writeIORef pendingRef rest
        [] -> pure ()
      else pure ()
    if sWrite sNext && not (sWrite s)
      then do
        writeIORef observedWrite True
        writeIORef observedAddr (sAddr sNext)
        writeIORef observedData (sWriteData sNext)
        writeIORef observedBe (sByteEnable sNext)
        hPutStrLn stderr $
          "cycle "
            <> show cyc
            <> ": WRITE addr="
            <> show (sAddr sNext)
            <> " wdata="
            <> show (sWriteData sNext)
            <> " be="
            <> show (sByteEnable sNext)
      else pure ()
    writeIORef sRef sNext

  ok <- readIORef observedWrite
  addr <- readIORef observedAddr
  wdata <- readIORef observedData
  be <- readIORef observedBe
  if ok && addr == 0x80000000 && wdata == 0xDEADBEEF && be == 0xF
    then do
      putStrLn "OK: FSM committed write 0xDEADBEEF to 0x80000000 with be=0xF"
      exitSuccess
    else do
      hPutStrLn stderr $
        "FAIL: ok="
          <> show ok
          <> " addr="
          <> show addr
          <> " wdata="
          <> show wdata
          <> " be="
          <> show be
      exitFailure
