-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
--
-- Smoke test for Riski5.JtagAvalonMaster.step (task #133).
--
-- Drives the FSM with several packets and asserts the master-side
-- outputs against expected register/transaction values:
--
--   t1: single-word write 0xDEADBEEF → 0x80000000 (no backpressure)
--   t2: two-word burst 0xDEADBEEF + 0xCAFEBABE → 0x80000000+
--       (INCR mode; verifies address bumps and second write commits)
--   t3: same as t2 but the slave asserts waitrequest=1 for 3 cycles
--       before accepting each write (mirrors a busy SDRAM controller)
--
-- Failure of any case prints the observed signals and exits non-zero.
--
-- Run: nix develop -c cabal exec runghc scripts/jam-fsm-smoke.hs
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Main where

import Clash.Prelude (BitVector)
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

-- Build the byte stream for a write packet.
--   cmd  = 0x04 = WRITE_INCR (or 0x00 = WRITE_NON_INCR)
--   addr = byte address (low 2 bits become current_byte; the FSM
--          requires addr aligned to a word for our test cases).
--   ws   = list of 32-bit words to write back-to-back; bytes are
--          sent little-endian per word.
writePacket :: BitVector 8 -> BitVector 32 -> [BitVector 32] -> [InS]
writePacket cmd addr ws =
  [ byteI cmd True False -- SOP + cmd
  , byteI 0xff False False -- extra (ignored)
  , byteI 0x00 False False -- size_hi (ignored for writes)
  , byteI 0x00 False False -- size_lo
  , byteI (byteFromAddr 24) False False -- addr [31:24]
  , byteI (byteFromAddr 16) False False -- addr [23:16]
  , byteI (byteFromAddr 8) False False -- addr [15:8]
  , byteI (byteFromAddr 0) False False -- addr [7:0]
  ]
    <> dataBytes
 where
  byteFromAddr :: Int -> BitVector 8
  byteFromAddr sh = fromIntegral (fromIntegral addr `div` (2 ^ sh) :: Integer) -- simple shift-and-mask
  totalBytes :: [(BitVector 8, Bool)]
  totalBytes = wordsToBytes ws
  dataBytes =
    [ byteI b False eop
    | (b, eop) <- totalBytes
    ]

wordsToBytes :: [BitVector 32] -> [(BitVector 8, Bool)]
wordsToBytes ws =
  let bs = concatMap wordBytes ws
   in zipWith (\b isLast -> (b, isLast)) bs (replicate (length bs - 1) False <> [True])
 where
  wordBytes :: BitVector 32 -> [BitVector 8]
  wordBytes w =
    let w' = fromIntegral w :: Integer
        b0 = fromIntegral (w' `div` 1) :: BitVector 8
        b1 = fromIntegral ((w' `div` 0x100) ) :: BitVector 8
        b2 = fromIntegral ((w' `div` 0x10000) ) :: BitVector 8
        b3 = fromIntegral ((w' `div` 0x1000000)) :: BitVector 8
     in [b0, b1, b2, b3]

-- Drive the FSM for `n` cycles. `slaveDelay` injects waitrequest
-- backpressure: each `write` pulse must wait `slaveDelay` cycles
-- before waitrequest drops (mirrors a busy SDRAM controller).
-- Returns the list of (cycle, address, writedata, byteenable) for
-- every write commit observed.
runFsm ::
  Int ->
  Int ->
  [InS] ->
  IO [(Int, BitVector 32, BitVector 32, BitVector 4)]
runFsm cycles slaveDelay packetBytes = do
  sRef <- newIORef initS
  pendingRef <- newIORef packetBytes
  -- Backpressure counter: when > 0, waitrequest is asserted; decrements
  -- each cycle the FSM holds `write` high. Reset to slaveDelay every
  -- time a fresh write rises.
  bpRef <- newIORef (0 :: Int)
  obsRef <- newIORef ([] :: [(Int, BitVector 32, BitVector 32, BitVector 4)])

  for_ [0 .. (cycles - 1)] $ \cyc -> do
    s <- readIORef sRef
    pending <- readIORef pendingRef
    bp <- readIORef bpRef
    let
      busInValid = sInReady s -- consume one byte per cycle while ready
      iByte = case pending of
        (b : _) | busInValid -> b
        _ -> idleI
      iNow = iByte {iWaitreq = bp > 0}
      sNext = step s iNow
    -- Consume byte if handshake completed
    if busInValid && iInValid iNow
      then case pending of
        (_ : rest) -> writeIORef pendingRef rest
        [] -> pure ()
      else pure ()
    -- Track backpressure. Initialize to slaveDelay on the cycle
    -- write rises, then decrement each cycle until 0 (then waitrequest=0).
    if sWrite sNext && not (sWrite s)
      then writeIORef bpRef slaveDelay
      else
        if bp > 0
          then modifyIORef' bpRef (subtract 1)
          else pure ()
    -- Observe a write commit: the cycle when waitrequest drops while
    -- write is high. (sWrite goes low in the next state, but the
    -- transaction is captured this cycle.)
    if sWrite s && not (iWaitreq iNow)
      then modifyIORef' obsRef ((cyc, sAddr s, sWriteData s, sByteEnable s) :)
      else pure ()
    writeIORef sRef sNext

  reverse <$> readIORef obsRef

-- Test cases ---------------------------------------------------------

t1SinglePass :: IO Bool
t1SinglePass = do
  obs <- runFsm 100 0 (writePacket 0x04 0x80000000 [0xDEADBEEF])
  case obs of
    [(_, a, w, b)] | a == 0x80000000 && w == 0xDEADBEEF && b == 0xF ->
      pure True
    _ -> do
      hPutStrLn stderr ("t1 FAIL: " <> show obs)
      pure False

t2BurstPass :: IO Bool
t2BurstPass = do
  obs <- runFsm 200 0 (writePacket 0x04 0x80000000 [0xDEADBEEF, 0xCAFEBABE])
  case obs of
    [(_, a0, w0, _), (_, a1, w1, _)]
      | a0 == 0x80000000
      , w0 == 0xDEADBEEF
      , a1 == 0x80000004
      , w1 == 0xCAFEBABE -> pure True
    _ -> do
      hPutStrLn stderr ("t2 FAIL (expected 2 writes at +0/+4): " <> show obs)
      pure False

t3BurstWaitreq :: IO Bool
t3BurstWaitreq = do
  obs <- runFsm 300 3 (writePacket 0x04 0x80000000 [0xDEADBEEF, 0xCAFEBABE])
  case obs of
    [(_, a0, w0, _), (_, a1, w1, _)]
      | a0 == 0x80000000
      , w0 == 0xDEADBEEF
      , a1 == 0x80000004
      , w1 == 0xCAFEBABE -> pure True
    _ -> do
      hPutStrLn stderr ("t3 FAIL (expected 2 writes under backpressure): " <> show obs)
      pure False

main :: IO ()
main = do
  rs <- sequence [t1SinglePass, t2BurstPass, t3BurstWaitreq]
  if and rs
    then do
      putStrLn "OK: 3/3 cases — single write, 2-word burst, 2-word with waitrequest=3"
      exitSuccess
    else exitFailure
