-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Riski5.SpikeDriver
Description : Run the official Spike ISS and parse its commit log.

Layer-1.5 plumbing (see @docs/verification.md@). Given a list of
RV32I instructions, this module:

  1. Assembles + links them into an ELF via 'Riski5.Elf.buildElf'.
  2. Runs @spike --isa=rv32i --priv=m --log-commits@ against the
     ELF, capturing the per-retire trace from stderr.
  3. Parses the trace lines into 'SpikeCommit' records:
     @core N: P 0xPC (0xINSN) [xREG 0xVAL] [mem 0xADDR]@.

Spike doesn't know when to stop on a program without @tohost@
semantics, so we bound the run by @maxCommits@ — the driver kills
spike once that many commits have arrived, then returns. That
also dodges the "spike spirals in an exception loop" behaviour
you get when firmware touches unmapped MMIO, because we terminate
before the spiral becomes a time sink.

Intended consumer: 'test/SpikeDiffSpec.hs' (landing next), which
diffs each CoreSimSpec program's Spike retire trace against its
'Riski5.Reference' trace and the Clash core's 'writeBack' stream,
flagging any two-against-one disagreement.
-}
module Riski5.SpikeDriver (
  -- * Spike invocation
  runSpike,
  runSpikeOnFirmware,
  SpikeOptions (..),
  defaultSpikeOptions,

  -- * Parsed trace
  SpikeCommit (..),
  parseCommitLine,

  -- * Filtering
  firmwareCommits,
) where

import Clash.Prelude (BitVector)
import Control.Concurrent.Async (race)
import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Data.Char (isHexDigit, isSpace)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isSuffixOf)
import Data.Word (Word32)
import Numeric (readHex)
import Riski5.Elf (buildElf, spikeElfBaseAddr)
import System.FilePath ((</>))
import System.IO (
  BufferMode (LineBuffering),
  Handle,
  hGetLine,
  hIsEOF,
  hSetBuffering,
 )
import System.IO.Temp (withSystemTempDirectory)
import System.Process (
  CreateProcess (std_err, std_out),
  StdStream (CreatePipe, NoStream),
  createProcess,
  proc,
  terminateProcess,
  waitForProcess,
 )

import qualified Data.ByteString.Lazy as BL

-- * Types

-- | One parsed line of @spike --log-commits@ output.
--
-- Spike emits one such line per retired instruction. The commit
-- log doesn't carry the stored /value/ (only the address), so
-- memory-write contents aren't directly diffable — we compare
-- register-file effects and memory /addresses/, and leave store
-- data reconstruction to the reference interpreter.
data SpikeCommit = SpikeCommit
  { scPc :: !Word32
  -- ^ @pc_rdata@ — address of the instruction that retired.
  , scInsn :: !Word32
  -- ^ the 32-bit instruction word.
  , scRegWrite :: !(Maybe (BitVector 5, Word32))
  -- ^ @rd_addr + rd_wdata@ if the instruction wrote a GPR.
  , scMemAddr :: !(Maybe Word32)
  -- ^ memory access address if the instruction touched dmem.
  }
  deriving stock (Eq, Show)

-- | Host-side knobs for the Spike process. Defaults match the
-- riski5 phase-1 scope (@rv32i@ / @m@-mode / no compressed).
data SpikeOptions = SpikeOptions
  { spikeExecutable :: !FilePath
  , spikeIsa :: !String
  , spikePriv :: !String
  , spikeBaseAddr :: !Word32
  -- ^ ELF load and reset-PC address. Matches 'spikeElfBaseAddr'
  -- by default so a fresh @SpikeOptions@ works without
  -- additional setup.
  , spikeMaxCommits :: !Int
  -- ^ hard cap on number of successfully-parsed commits to
  -- collect. Acts as a bounded replacement for @tohost@ —
  -- when we've reached this many commits we @terminateProcess@
  -- spike and return.
  , spikeMaxLines :: !Int
  -- ^ hard cap on total lines read from spike's stderr.
  -- Belt-and-braces defence against a run where spike spirals
  -- into an exception loop (e.g. trap → mtvec=0 → trap loop):
  -- exception lines don't parse as commits, so @spikeMaxCommits@
  -- alone wouldn't terminate the read loop. Set generously
  -- larger than 'spikeMaxCommits' — a few times is plenty.
  , spikeTimeoutMillis :: !Int
  -- ^ wallclock deadline for the whole Spike invocation, in
  -- milliseconds. Once it elapses we @terminateProcess@ Spike
  -- and return whatever commits we've accumulated so far.
  -- Catches the case where Spike stops emitting stderr (e.g.
  -- after hitting an exception where the decoder silently
  -- spins) which would otherwise hang @hGetLine@ forever.
  }
  deriving stock (Eq, Show)

{- | Defaults tuned for small catalog programs.

'spikeIsa' defaults to @rv32im@ (phase 2B) so the golden-model
differential test covers the eight RV32M ops the core now
implements alongside the base integer set. Spike's @rv32im@
is a superset of @rv32i@ — RV32I programs still execute
identically. Tests targeting strictly base-integer semantics
(e.g. verifying illegal-instruction traps for M encodings on
a hypothetical @tiny32@-only variant) can override via
@defaultSpikeOptions { spikeIsa = \"rv32i\" }@.
-}
defaultSpikeOptions :: SpikeOptions
defaultSpikeOptions =
  SpikeOptions
    { spikeExecutable = "spike"
    , spikeIsa = "rv32im"
    , spikePriv = "m"
    , spikeBaseAddr = spikeElfBaseAddr
    , spikeMaxCommits = 200
    , spikeMaxLines = 500
    , spikeTimeoutMillis = 3_000
    }

-- * Invocation

{- | Run Spike against a list of instruction words and return the
parsed commit trace.

The ELF is built in a temporary directory (cleaned up after the
return) via 'buildElf', which itself shells out to binutils.
Spike is spawned with @--log-commits@; the trace lines come out
on stderr (Spike's I/O convention). We read up to
'spikeMaxCommits' lines, then terminate the Spike process —
Spike has no concept of "stop after N instructions", so bounded
reading is how we avoid infinite runs on firmware that lacks a
@tohost@ exit handshake.
-}
runSpike :: SpikeOptions -> [Word32] -> IO [SpikeCommit]
runSpike opts@SpikeOptions {..} instrWords = do
  elfBytes <- buildElf spikeBaseAddr instrWords
  withSystemTempDirectory "riski5-spike" $ \dir -> do
    let elfPath = dir </> "firmware.elf"
    BL.writeFile elfPath elfBytes
    runSpikeOnFirmware opts elfPath

{- | Run Spike against an existing ELF on disk and collect the
commit trace. Factored out of 'runSpike' so higher-level tooling
(e.g. Spike vs DE2 bitstream comparison) can point at firmware
it didn't build itself.
-}
runSpikeOnFirmware :: SpikeOptions -> FilePath -> IO [SpikeCommit]
runSpikeOnFirmware SpikeOptions {..} elfPath = do
  -- Force line-buffered stderr via `stdbuf -eL`. Without it, spike's
  -- stderr is fully buffered when the destination is a pipe, so
  -- lines only surface when a full block has been written — and our
  -- firmware runs rapidly enough after the 5-line boot ROM that a
  -- partial block sits in glibc forever.
  let args =
        [ "-eL"
        , spikeExecutable
        , "--isa=" <> spikeIsa
        , "--priv=" <> spikePriv
        , "--pc=0x" <> showHex32 spikeBaseAddr
        , "--log-commits"
        , elfPath
        ]
      cp =
        (proc "stdbuf" args)
          { std_out = NoStream
          , std_err = CreatePipe
          }
  bracket
    (createProcess cp)
    cleanup
    ( \(_, _, mErr, _) -> case mErr of
        Nothing -> pure []
        Just h -> do
          hSetBuffering h LineBuffering
          accRef <- newIORef []
          _ <-
            race
              (threadDelay (spikeTimeoutMillis * 1000))
              (collectCommits spikeMaxCommits spikeMaxLines h accRef)
          -- Whichever branch won, accRef already holds every commit
          -- we managed to parse.
          reverse <$> readIORef accRef
    )
 where
  cleanup (_, _, _, ph) = do
    terminateProcess ph
    _ <- waitForProcess ph
    pure ()

{- | Read lines from Spike's stderr and parse them as commits,
appending each one to @accRef@ so the caller can retrieve the
partial trace even if this function never returns (wallclock
timeout path).

Two budgets apply:

  * @maxCommits@ — stop once we've successfully parsed this many
    commits. The common case.
  * @maxLines@ — stop after reading this many raw lines, parsed
    or not. Prevents a hang when Spike enters an exception loop
    and emits lines that don't match the commit format.

Non-commit lines (the @warning: tohost …@ banner, trap reports,
interactive-mode prompts) are skipped towards the @maxLines@
budget but not the @maxCommits@ one.
-}
collectCommits ::
  Int ->
  Int ->
  Handle ->
  IORef [SpikeCommit] ->
  IO ()
collectCommits maxCommits maxLines h accRef = go maxCommits maxLines
 where
  go 0 _ = pure ()
  go _ 0 = pure ()
  go cRem lRem = do
    eof <- hIsEOF h
    if eof
      then pure ()
      else do
        line <- hGetLine h
        case parseCommitLine line of
          Nothing -> go cRem (lRem - 1)
          Just c -> do
            modifyIORef' accRef (c :)
            go (cRem - 1) (lRem - 1)

-- * Parsing

{- | Parse a single @--log-commits@ line into a 'SpikeCommit'.

Expected format (whitespace-insensitive between tokens):

@
core   0: 3 0x00001000 (0x00000297) x5  0x00001000
core   0: 3 0x0000100c (0x0182a283) x5  0x80000000 mem 0x00001018
core   0: 3 0x00001010 (0x00028067)
@

Returns 'Nothing' for non-commit lines (headers, warnings,
exceptions, interactive prompts) so the caller can filter them
out en-masse with @mapMaybe@.
-}
parseCommitLine :: String -> Maybe SpikeCommit
parseCommitLine line = case words line of
  ("core" : coreIdTok : _privTok : pcTok : insnTok : rest)
    | ":" `isSuffixOf` coreIdTok
    , Just scPc <- parseHexWord pcTok
    , Just scInsn <- parseParenHex insnTok ->
        let (scRegWrite, scMemAddr) = parseExtras rest
         in Just SpikeCommit {..}
  _ -> Nothing

-- | Walk the trailing tokens after @(insn)@ picking up an optional
-- register write and an optional @mem@ annotation.
parseExtras :: [String] -> (Maybe (BitVector 5, Word32), Maybe Word32)
parseExtras = go Nothing Nothing
 where
  go rw mem [] = (rw, mem)
  go _ mem (('x' : digits) : valTok : rest)
    | not (null digits)
    , all (`elem` "0123456789") digits
    , Just idx <- readMaybeDec digits
    , idx < (32 :: Int)
    , Just val <- parseHexWord valTok =
        go (Just (fromIntegral idx, val)) mem rest
  go rw _ ("mem" : addrTok : rest)
    | Just addr <- parseHexWord addrTok =
        go rw (Just addr) rest
  go rw mem (_ : rest) = go rw mem rest

-- * Filtering

{- | Keep only the commits whose PC falls inside the firmware
region we loaded. Drops Spike's reset-vector boot-ROM prelude
(the five instructions at @0x1000@ that read the DTB and jump
to our entry point) and anything past the firmware tail.
-}
firmwareCommits :: Word32 -> Int -> [SpikeCommit] -> [SpikeCommit]
firmwareCommits baseAddr instrCount =
  filter $ \SpikeCommit {scPc} ->
    scPc >= baseAddr && scPc < baseAddr + fromIntegral (4 * instrCount)

-- * Internal helpers

-- | Parse @0xXXXX@ → 'Word32'.
parseHexWord :: String -> Maybe Word32
parseHexWord s = case dropWhile isSpace s of
  '0' : 'x' : rest
    | not (null rest)
    , all isHexDigit rest
    , [(n, "")] <- readHex rest ->
        Just n
  _ -> Nothing

-- | Parse @(0xXXXX)@ → 'Word32'.
parseParenHex :: String -> Maybe Word32
parseParenHex s = case s of
  '(' : inner
    | ")" `isSuffixOf` inner ->
        parseHexWord (take (length inner - 1) inner)
  _ -> Nothing

-- | Format a 'Word32' as @XXXXXXXX@ (no @0x@ prefix).
showHex32 :: Word32 -> String
showHex32 w = let s = go w in replicate (8 - length s) '0' <> s
 where
  go 0 = "0"
  go n = goNonZero n ""
  goNonZero 0 acc = acc
  goNonZero n acc =
    let (q, r) = n `quotRem` 16
     in goNonZero q (hexDigit r : acc)
  hexDigit :: Word32 -> Char
  hexDigit d
    | d < 10 = toEnum (fromEnum '0' + fromIntegral d)
    | otherwise = toEnum (fromEnum 'a' + fromIntegral (d - 10))

-- | Parse a plain decimal 'Int'.
readMaybeDec :: String -> Maybe Int
readMaybeDec s = case reads s of
  [(n, "")] -> Just n
  _ -> Nothing
