-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE RebindableSyntax #-}

{- |
Module      : Main
Description : Boot-ROM Copilot spec → C99 emitter (B-1 + B-2).

Generates @boot_rom_step.{c,h}@ from a Haskell Copilot-eDSL
spec. The accompanying hand-written @firmware/phase2/boot-rom/start.c@
links those generated step / state functions with the RISC-V Linux
boot-ABI handoff and MMIO trigger bodies; @riscv64-unknown-linux-gnu-gcc@
in the L-5 cross-toolchain produces the final flat binary that
embeds into BRAM as @LinuxBoot.linuxBootFirmwareWords@.

Usage:

> riski5-boot-rom-gen <output-dir>

Emits @<output-dir>/boot_rom_step.c@ and
@<output-dir>/boot_rom_step.h@.

== B-1 contents — minimal handshake

The first Copilot pass keeps the spec deliberately tiny so the
plumbing (Copilot codegen → riscv-gcc → objcopy → BRAM literal)
gets validated before the full state machine lands in B-2:

  * One @counter@ stream advancing every step.
  * One trigger @boot_emit_tick@ firing every 1000 ticks; the
    hand-written start.c side hooks that to a UART byte write
    so silicon shows the boot ROM is alive.

== B-2 (next iteration)

Replace the placeholder spec with the full SDRAM-loader state
machine — @phase@, @shift@, @kWords@, @dWords@, @written@,
@sdramPtr@ streams + @uart_read_data@, @sdram_write@,
@uart_write_byte@, @boot_finish@ triggers — see
@docs/boot-rom-copilot.md@ §B-2.
-}
module Main (main) where

import Copilot.Compile.C99 (compile)
import Language.Copilot
import Prelude (FilePath, IO, ($))
import qualified Prelude as P
import qualified System.Directory as Dir
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath ((</>))

main :: IO ()
main = do
  args <- getArgs
  outDir <- case args of
    [d] -> P.pure d
    _ -> die "usage: riski5-boot-rom-gen <output-dir>"

  Dir.createDirectoryIfMissing P.True outDir

  -- Copilot's compile writes to the *current* working directory.
  -- Run from outDir so the .c/.h emitted land where we want.
  -- 'reify' converts the surface 'Spec' (a writer-monad accumulator
  -- over 'SpecItem's) into the core AST the C99 backend consumes.
  oldCwd <- Dir.getCurrentDirectory
  Dir.setCurrentDirectory outDir
  reified <- reify bootRomSpec
  compile "boot_rom_step" reified
  Dir.setCurrentDirectory oldCwd

  P.putStrLn $ "Wrote: " P.++ (outDir </> "boot_rom_step.c")
  P.putStrLn $ "Wrote: " P.++ (outDir </> "boot_rom_step.h")

-- ------------------------------------------------------------------
-- B-1: minimal placeholder spec
-- ------------------------------------------------------------------

bootRomSpec :: Spec
bootRomSpec = do
  trigger "boot_emit_tick" everyKilo []

-- | A 'Word32' stream that increments by 1 each step. Initial
-- value 0; thereafter @counter (n+1) = counter n + 1@.
counter :: Stream Word32
counter = [0] ++ counter + 1

-- | Boolean stream that's True every 1000th step.
everyKilo :: Stream Bool
everyKilo = counter `mod'` 1000 == 0

-- | 'mod' on Copilot streams. Re-exported under a renamed symbol
-- because Prelude's 'mod' would collide with Copilot's
-- 'Language.Copilot.mod'-on-streams; tagging it locally keeps
-- the spec grammar obvious in this single file.
mod' :: Stream Word32 -> Stream Word32 -> Stream Word32
mod' = (Language.Copilot.mod)
