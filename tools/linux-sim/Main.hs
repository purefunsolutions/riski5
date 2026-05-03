-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause

{- |
Module      : Main
Description : Pure-Haskell simulator runner for the riski5 Linux kernel.

Drives 'Riski5.SocSim' against a kernel image + DTB so we can debug
kernel hangs without burning silicon iteration time.

Usage:
@
  riski5-linux-sim KERNEL DTB [MAX_STEPS]
  riski5-linux-sim --trace KERNEL DTB [MAX_STEPS]
@

Default MAX_STEPS is 10 million instructions. With --trace, every
retired instruction's PC is logged to stderr — useful for finding
the exact instruction where the kernel hangs.

Stops early if "Linux version" appears in the UART output OR if PC
is unchanged for 1000 steps (hang detection).
-}
module Main (main) where

import Data.IORef (IORef, newIORef, readIORef)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import Data.Word (Word8, Word32)
import Riski5.Reference (memory, pc, regs)
import Riski5.SocSim
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hFlush, hPutStrLn, stderr, stdout)
import Text.Printf (printf)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [kPath, dPath]                       -> runSim kPath dPath 10_000_000 False StopOnLinuxVersion
    [kPath, dPath, n]                    -> runSim kPath dPath (read n) False StopOnLinuxVersion
    ["--full", kPath, dPath]             -> runSim kPath dPath 10_000_000 False StopOnPanicOnly
    ["--full", kPath, dPath, n]          -> runSim kPath dPath (read n) False StopOnPanicOnly
    ["--trace", kPath, dPath]            -> runSim kPath dPath 10_000_000 True  StopOnLinuxVersion
    ["--trace", kPath, dPath, n]         -> runSim kPath dPath (read n) True  StopOnLinuxVersion
    _ -> do
      hPutStrLn stderr "usage: riski5-linux-sim [--trace|--full] KERNEL DTB [MAX_STEPS]"
      hPutStrLn stderr "  default: stop on first 'Linux version' UART output"
      hPutStrLn stderr "  --full:  run until 'Kernel panic' or MAX_STEPS"
      hPutStrLn stderr "  --trace: per-step PC trace to stderr"
      exitFailure

data StopMode = StopOnLinuxVersion | StopOnPanicOnly

runSim :: FilePath -> FilePath -> Int -> Bool -> StopMode -> IO ()
runSim kPath dPath maxSteps trace mode = do
  hPutStrLn stderr $ "linux-sim: kernel=" ++ kPath ++ " dtb=" ++ dPath
                    ++ " max-steps=" ++ show maxSteps ++ " trace=" ++ show trace
  st0 <- loadKernelDtb kPath 0x80000000 dPath 0x80400000
  ref <- newIORef st0
  hPutStrLn stderr "linux-sim: starting..."
  let stopPred = case mode of
        StopOnLinuxVersion -> ("Linux version" `isInfixOf`)
        StopOnPanicOnly    -> ("Kernel panic" `isInfixOf`)
  if trace
    then runWithTrace maxSteps ref
    else runSoc maxSteps stopPred ref
  hFlush stdout
  st <- readIORef ref
  hPutStrLn stderr "\n--- linux-sim done ---"
  hPutStrLn stderr $ "  cycles : " ++ show (socCycles st)
  hPutStrLn stderr $ printf "  pc     : 0x%08x" (pc (socMach st))
  hPutStrLn stderr $ "  uart-tx: " ++ show (length (socUartTx st)) ++ " bytes"
  hPutStrLn stderr "  regs   :"
  mapM_ (\n -> hPutStrLn stderr $ printf "    x%d = 0x%08x" (n :: Int)
                                          (Map.findWithDefault 0 (fromIntegral n) (regs (socMach st))))
        [(1 :: Int) .. 31]

-- | Tracing variant: prints PC + raw instruction bits to stderr at
-- every retire. Useful for finding the EXACT step where a hang
-- starts.
runWithTrace :: Int -> IORef SocState -> IO ()
runWithTrace 0 _ = pure ()
runWithTrace n ref = do
  st <- readIORef ref
  let m = socMach st
      pc' = pc m
      ibits = readWord32 pc' (memory m)
  hPutStrLn stderr $ printf "[%08d] pc=0x%08x instr=0x%08x"
                            (fromIntegral (socCycles st) :: Int) pc' ibits
  stepSoc ref
  st' <- readIORef ref
  if socCycles st' == socCycles st + 1 && pc (socMach st') == pc'
    && socCycles st' > 1000
    then hPutStrLn stderr $ printf "linux-sim: hang detected, PC stuck at 0x%08x" pc'
    else runWithTrace (n - 1) ref

readWord32 :: Word32 -> Map.Map Word32 Word8 -> Word32
readWord32 a mem =
    fromIntegral (byte 0)
    + fromIntegral (byte 1) * 256
    + fromIntegral (byte 2) * 65536
    + fromIntegral (byte 3) * 16777216
  where
    byte i = Map.findWithDefault 0 (a + i) mem
