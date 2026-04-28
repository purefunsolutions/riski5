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

import Control.Exception (IOException, bracket_, catch)
import Control.Monad (unless, when)
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
  , hFlush
  , hIsEOF
  , hIsTerminalDevice
  , hPutStr
  , hPutStrLn
  , hSetBinaryMode
  , hSetBuffering
  , stderr
  , stdin
  , withBinaryFile
  )
import System.Process
  ( CreateProcess (..)
  , StdStream (CreatePipe, Inherit)
  , callProcess
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

Two phases:

  1. Load. @action@ writes the kernel + DTB (or generic blob) to
     @hin@ with the live progress bar from 'streamWithProgress'.
  2. Interactive forwarding. After the load finishes we keep
     @hin@ open and pump our stdin → @hin@ in a tight loop, so
     keystrokes the user types reach the running kernel as
     JTAG-UART RX bytes. The terminal is put into cbreak mode
     (-icanon -echo) for the duration so each keystroke flows
     immediately and the kernel-side tty layer owns echo, but
     ISIG stays on so Ctrl-C still delivers SIGINT and tears the
     loop down cleanly.

@withCreateProcess@ ensures the subprocess is reaped even if
we're killed mid-stream. The cbreak-mode @stty@ is balanced by
a @stty sane@ in 'bracket_', so the terminal is always restored
to a usable state on exit (including SIGINT — the runtime turns
it into an async exception that the bracket catches).
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
          -- Phase 1: load.
          action hin
          hPutStrLn stderr ""
          hPutStrLn
            stderr
            "Load complete. Forwarding keyboard → kernel; Ctrl-C to detach."
          hPutStrLn stderr ""
          -- Phase 2: interactive stdin → kernel forwarding. cbreak
          -- mode + no echo for per-keystroke flow with the kernel's
          -- tty layer doing the visible echoing. ISIG stays on so
          -- Ctrl-C still works.
          withCbreakMode (interactiveForward hin ph)
          waitForProcess ph >>= \case
            ExitSuccess -> pure ()
            ec -> exitWith ec
        Nothing ->
          die "internal: failed to acquire nios2-terminal stdin handle"

-- ------------------------------------------------------------------
-- Interactive forwarding
-- ------------------------------------------------------------------

{- |
Read bytes from our stdin and write them to the @nios2-terminal@
stdin pipe, one chunk at a time, until either side closes. The
pipe stays open after stdin EOFs so @nios2-terminal@ keeps
streaming JTAG-UART TX (i.e. kernel printk and any prompt the
on-board software prints) until the user presses Ctrl-C.

Pipe-write 'IOException's (e.g. SIGPIPE because @nios2-terminal@
exited first) are caught and treated as a clean exit signal —
no point continuing to forward into a closed pipe.
-}
interactiveForward :: Handle -> a -> IO ()
interactiveForward hin _ = do
  hSetBuffering stdin NoBuffering
  hSetBinaryMode stdin True
  let loop = do
        eof <- hIsEOF stdin
        unless eof $ do
          bs <- BS.hGetSome stdin 1024
          unless (BS.null bs) $ do
            BS.hPut hin bs
            hFlush hin
            loop
  loop `catch` \(_ :: IOException) -> pure ()

{- |
Put the controlling tty into cbreak mode for the duration of
@action@, then unconditionally restore it via 'stty sane'. We
shell out to @stty@ rather than pulling in @unix@ for
@tcsetattr@: stty is in coreutils (in PATH on every Nix profile),
the call cost is paid once per invocation, and the cleanup
balance survives async exceptions via 'bracket_'.

Settings:

  * @-icanon@ — disable canonical (line-buffered) input so each
    keystroke flows immediately into our stdin.
  * @-echo@ — disable the local tty's echo. The remote kernel's
    tty layer does the echoing on its end of the JTAG-UART link.
  * @min 1@ — wake @read(2)@ as soon as one byte is available
    rather than waiting for VTIME ticks.

ISIG (the bit that turns Ctrl-C into SIGINT) is left on by
default, so Ctrl-C still tears down the loop cleanly.

When stdin isn't actually a tty (CI, redirection from a file)
we no-op: stty would print a "Inappropriate ioctl for device"
warning and the cbreak settings wouldn't apply anyway.
-}
withCbreakMode :: IO a -> IO a
withCbreakMode action = do
  isTty <- hIsTerminalDevice stdin
  if isTty
    then bracket_ enable restore action
    else action
 where
  enable =
    callProcess "stty" ["-icanon", "-echo", "min", "1"]
      `catch` \(_ :: IOException) -> pure ()
  restore =
    callProcess "stty" ["sane"]
      `catch` \(_ :: IOException) -> pure ()

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
