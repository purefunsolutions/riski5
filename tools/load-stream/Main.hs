-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}

{- |
@riski5-load-stream@ — host-side companion to the on-board
JTAG-UART loader bitstreams. Replaces the older Python heredoc
inside the Nix-app text. Owns the @nios2-terminal@ subprocess
directly: writes the kernel + DTB (or generic blob) into its
stdin pipe with a live progress bar on stderr, and inherits
@nios2-terminal@'s stdout so kernel printk arrives right in the
user's terminal once the on-board firmware JALRs into the loaded
image.

== Subcommands

  * @sdram-jtag \<words\> \<bin\>@ — single-blob protocol used by
    @firmware\/phase1\/SdramLoader.hs@. Emits a 4-byte LE word
    count followed by @bin@'s contents (zero-padded to a 4-byte
    boundary).

  * @linux \<kwords\> \<dwords\> \<kernel\> \<dtb\>@ — two-blob
    protocol used by @firmware\/phase1\/LinuxBoot.hs@. Emits two
    4-byte LE word counts (kernel then DTB), then both blobs in
    that order, each zero-padded to a 4-byte boundary.

== UX layout

Stderr (progress bar, redraws in place via @\\r@):

@
  [#######.............] 35%  2.8 MB / 8.0 MB  @  100 KB/s  ETA  53s
@

Stdout (inherited @nios2-terminal@ output):

@
  L                                ← loader ready (printed before load)
  D                                ← load complete
  [    0.000000] Linux version …   ← kernel boot
@

Progress is paced by the OS pipe between Haskell and
@nios2-terminal@: with @NoBuffering@ on the pipe write end and a
~64 KB kernel pipe buffer, the bytes-written counter tracks
on-the-wire JTAG-UART transmission to within ~640 ms of headroom
at the IP's ~100 KB/s rate. Plenty good enough as a "still alive"
indicator.

== Why a Haskell subprocess and not a shell pipe

The earlier nix-app pipe @python3 ... | nios2-terminal@ ran two
processes glued by a shell pipe and depended on the @python3@
runtime. Owning @nios2-terminal@ from Haskell drops the
@python3@ dependency, lets us hold the subprocess handle so a
clean Ctrl-C exits both processes together via
@withCreateProcess@'s exception cleanup, and keeps host tooling
in the project's primary language. The Copilot-eDSL boot ROM
generator that lands later shares this Haskell host environment.
-}
module Main (main) where

import Control.Exception (bracket_)
import Control.Monad (when)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BSL
import Data.IORef
  ( modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Int (Int64)
import Data.Word (Word32)
import GHC.Clock (getMonotonicTime)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), die, exitWith)
import System.IO
  ( BufferMode (..)
  , Handle
  , IOMode (..)
  , hClose
  , hFlush
  , hPutStr
  , hPutStrLn
  , hSetBinaryMode
  , hSetBuffering
  , stderr
  , withBinaryFile
  )
import System.Process
  ( CreateProcess (..)
  , StdStream (CreatePipe, Inherit)
  , proc
  , waitForProcess
  , withCreateProcess
  )
import Text.Printf (hPrintf)

main :: IO ()
main = do
  hSetBuffering stderr NoBuffering
  args <- getArgs
  case args of
    ["sdram-jtag", wordsStr, binPath] ->
      runWithTerminal $ \h ->
        cmdSdramJtag h (parseWord32 "words" wordsStr) binPath
    ["linux", kStr, dStr, kPath, dPath] ->
      runWithTerminal $ \h ->
        cmdLinux
          h
          (parseWord32 "kernel-words" kStr)
          (parseWord32 "dtb-words" dStr)
          kPath
          dPath
    _ -> usage

usage :: IO a
usage =
  die $
    unlines
      [ "usage:"
      , "  riski5-load-stream sdram-jtag <words> <bin-path>"
      , "  riski5-load-stream linux <kernel-words> <dtb-words> <kernel-path> <dtb-path>"
      , ""
      , "Spawns nios2-terminal, sends the length-prefixed byte stream"
      , "the on-board JTAG-UART loaders expect, then keeps the"
      , "terminal attached so kernel output streams to your shell."
      , "Progress bar on stderr."
      ]

parseWord32 :: String -> String -> Word32
parseWord32 label s = case reads s of
  [(n, "")]
    | n >= 0 && n <= toInteger (maxBound :: Word32) -> fromInteger n
    | otherwise ->
        errorWithoutStackTrace $
          label <> ": " <> s <> " is out of [0, 2^32) range"
  _ ->
    errorWithoutStackTrace $
      label <> ": " <> s <> " is not a non-negative integer"

-- ------------------------------------------------------------------
-- Subprocess management
-- ------------------------------------------------------------------

{- |
Spawn @nios2-terminal@ with its stdin connected to a pipe we
control; its stdout and stderr inherit the parent's so any
@nios2-terminal@ messages and the JTAG-UART TX bytes the
on-board firmware emits land directly in the user's shell.

After @action@ returns we close our end of the stdin pipe (so
@nios2-terminal@ stops waiting for more load bytes) and then
@waitForProcess@ blocks until the user presses Ctrl-C —
@nios2-terminal@ stays attached as a passive viewer in the
meantime, streaming kernel output. @withCreateProcess@ ensures
the subprocess is reaped even if we're killed mid-stream.
-}
runWithTerminal :: (Handle -> IO ()) -> IO ()
runWithTerminal action =
  withCreateProcess
    (proc "nios2-terminal" [])
      { std_in = CreatePipe
      , std_out = Inherit
      , std_err = Inherit
      }
    $ \mIn _ _ ph ->
      case mIn of
        Just hin -> do
          hSetBinaryMode hin True
          hSetBuffering hin NoBuffering
          -- Run the load. After it returns, close the stdin pipe
          -- so nios2-terminal stops trying to read; it then keeps
          -- printing JTAG-UART TX (kernel output) until the user
          -- presses Ctrl-C.
          bracket_ (pure ()) (hClose hin) (action hin)
          hPutStrLn stderr ""
          hPutStrLn
            stderr
            "Load complete. nios2-terminal stays attached — Ctrl-C to detach."
          waitForProcess ph >>= \case
            ExitSuccess -> pure ()
            ec -> exitWith ec
        Nothing ->
          die "internal: failed to acquire nios2-terminal stdin handle"

-- ------------------------------------------------------------------
-- Subcommand bodies
-- ------------------------------------------------------------------

cmdSdramJtag :: Handle -> Word32 -> FilePath -> IO ()
cmdSdramJtag hin nWords binPath =
  withBinaryFile binPath ReadMode $ \h -> do
    bs <- BSL.hGetContents h
    let header = BB.toLazyByteString (BB.word32LE nWords)
        blob = padTo4 bs
        total = BSL.length header + BSL.length blob
    announceLoad
      total
      [ ("blob", binPath, BSL.length blob)
      ]
    streamWithProgress hin total [header, blob]

cmdLinux :: Handle -> Word32 -> Word32 -> FilePath -> FilePath -> IO ()
cmdLinux hin kWords dWords kernelPath dtbPath =
  withBinaryFile kernelPath ReadMode $ \kh ->
    withBinaryFile dtbPath ReadMode $ \dh -> do
      kbs <- BSL.hGetContents kh
      dbs <- BSL.hGetContents dh
      let header =
            BB.toLazyByteString
              (BB.word32LE kWords <> BB.word32LE dWords)
          kBlob = padTo4 kbs
          dBlob = padTo4 dbs
          total = BSL.length header + BSL.length kBlob + BSL.length dBlob
      announceLoad
        total
        [ ("kernel", kernelPath, BSL.length kBlob)
        , ("dtb", dtbPath, BSL.length dBlob)
        ]
      streamWithProgress hin total [header, kBlob, dBlob]

-- | Print a one-time pre-load summary on stderr so the user can
-- sanity-check the file paths + sizes before the progress bar
-- starts redrawing in place.
announceLoad :: Int64 -> [(String, FilePath, Int64)] -> IO ()
announceLoad totalBytes parts = do
  hPutStrLn stderr "riski5-load-stream:"
  mapM_
    ( \(name, path, size) ->
        hPrintf stderr "  %-7s %s (%s)\n" name path (humanBytes size)
    )
    parts
  hPrintf
    stderr
    "  total   %s (incl. headers)\n"
    (humanBytes totalBytes)
  hPutStrLn
    stderr
    "Make sure the loader bitstream is flashed and KEY0 has been pressed."
  hPutStrLn stderr ""

-- | Zero-pad a lazy bytestring to the next multiple of 4 bytes.
-- The on-board loaders read in 4-byte chunks and would otherwise
-- hang waiting for the trailing bytes of an unaligned blob.
padTo4 :: BSL.ByteString -> BSL.ByteString
padTo4 bs =
  let n = BSL.length bs
      pad = (-n) `mod` 4
   in bs <> BSL.replicate pad 0

-- ------------------------------------------------------------------
-- Streaming + progress
-- ------------------------------------------------------------------

-- | Stream a list of lazy bytestrings to @hin@, redrawing a
-- progress bar on stderr roughly every 100 ms. Pipe backpressure
-- from @nios2-terminal@ paces the writes to ~JTAG-UART rate.
streamWithProgress :: Handle -> Int64 -> [BSL.ByteString] -> IO ()
streamWithProgress hin totalBytes parts = do
  t0 <- getMonotonicTime
  writtenRef <- newIORef (0 :: Int64)
  lastDrawRef <- newIORef (0 :: Double)

  let allChunks :: [BS.ByteString]
      allChunks = concatMap BSL.toChunks parts

      sendChunk :: BS.ByteString -> IO ()
      sendChunk chunk = do
        BS.hPut hin chunk
        let !chunkLen = fromIntegral (BS.length chunk) :: Int64
        modifyIORef' writtenRef (+ chunkLen)
        now <- getMonotonicTime
        lastDraw <- readIORef lastDrawRef
        when (now - lastDraw > 0.1) $ do
          writeIORef lastDrawRef now
          w <- readIORef writtenRef
          drawProgress w totalBytes (now - t0)

  mapM_ sendChunk allChunks

  -- Final 100 % redraw + newline so subsequent kernel output
  -- starts on its own line.
  finalNow <- getMonotonicTime
  drawProgress totalBytes totalBytes (finalNow - t0)
  hFlush hin

-- | Draw a single progress-line update on stderr. Carriage-return
-- prefix overwrites the previous line in place.
drawProgress :: Int64 -> Int64 -> Double -> IO ()
drawProgress current total elapsed = do
  let pct :: Int
      pct
        | total <= 0 = 100
        | otherwise = fromIntegral ((100 * current) `div` total)
      barWidth = 20
      filled = min barWidth (pct * barWidth `div` 100)
      bar = replicate filled '#' <> replicate (barWidth - filled) '.'
      kbPerSec :: Double
      kbPerSec
        | elapsed > 0 = fromIntegral current / elapsed / 1024.0
        | otherwise = 0
      etaSec :: Int
      etaSec
        | kbPerSec > 0 =
            round
              ( fromIntegral (max 0 (total - current))
                  / (kbPerSec * 1024.0)
              )
        | otherwise = 0
  hPutStr stderr "\r"
  hPrintf
    stderr
    "[%s] %3d%%  %s / %s  @ %5.0f KB/s  ETA %3ds"
    bar
    pct
    (humanBytes current)
    (humanBytes total)
    kbPerSec
    etaSec

-- | Human-friendly byte-size formatting (1024-based, like most CLI
-- tools' progress bars).
humanBytes :: Int64 -> String
humanBytes n
  | n < 1024 = show n <> " B "
  | n < 1024 * 1024 =
      formatTwo (fromIntegral n / 1024.0) "KB"
  | n < 1024 * 1024 * 1024 =
      formatTwo (fromIntegral n / (1024.0 * 1024.0)) "MB"
  | otherwise =
      formatTwo (fromIntegral n / (1024.0 * 1024.0 * 1024.0)) "GB"
 where
  formatTwo :: Double -> String -> String
  formatTwo x unit =
    -- Tenths of the unit (i.e. 1.2 instead of 1.234).
    let tenths :: Int
        tenths = round (x * 10)
        whole = tenths `div` 10
        frac = tenths `mod` 10
     in show whole <> "." <> show frac <> " " <> unit
