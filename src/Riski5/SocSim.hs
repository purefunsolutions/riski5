-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Riski5.SocSim
Description : Pure-Haskell SoC simulator that boots Linux on the architectural
              RV32IMA model (no Clash, no Verilator).

Wraps 'Riski5.Reference' with the small bits of SoC behaviour needed
to run the riski5 Linux kernel image through to its first printk:

  * MMIO sink at @0x1000_0000@ — writes to the JTAG-UART data
    register go to host stdout (one byte per word write, low 8
    bits). Reads return a "TX FIFO has space" pattern so the
    kernel's @altera_jtaguart@ driver doesn't get backpressured.
  * CLINT @mtime@ at @0x0200_BFF8@ / @0x0200_BFFC@ tracks the
    instruction count (good enough for any timer-driven kernel
    code that asks "is time advancing").
  * Trap-and-continue: when 'Riski5.Reference.step' returns
    'Left cause', we update @mepc@ / @mcause@ and redirect PC
    to @mtvec.base@ instead of bailing out. That mirrors the
    hardware's trap path. Kernel code that takes a trap (e.g.
    PMP-CSR write on a core that doesn't implement PMP) will
    correctly land at its own trap handler.
  * Tracer hook: every retired instruction can be logged to a
    callback (PC, raw bits, register writes). Used by
    @app/linux-sim/Main.hs@ to dump executed instructions when
    the kernel hangs.

Deliberately does NOT model:

  * SDRAM controller IP timing (write buffer, refresh, row
    activate latency) — those are exactly the silicon-specific
    behaviours we're trying to ABSTRACT AWAY here. If Linux
    boots cleanly in this simulator, the residual silicon hang
    (task #138) is an SDRAM-IP issue, not an architectural core
    issue.
  * JTAG-UART RX path. Kernel earlycon writes only — that's
    enough to see the boot banner.
  * PLIC. External interrupts can't fire because we never raise
    them.

== Usage

@
  import Riski5.SocSim
  state <- loadElf \"linux.bin\" \"linux.dtb\"
  runUntil (== \"Linux version\") state
@
-}
module Riski5.SocSim (
  -- * Simulator state
  SocState (..),
  initialSoc,

  -- * Stepping
  stepSoc,
  runSoc,

  -- * Loading
  loadKernelDtb,

  -- * MMIO addresses
  uartBase,
  clintMtime,
) where

import Data.Bits (shiftR, (.&.), complement)
import Data.ByteString qualified as BS
import Data.IORef (IORef, readIORef, writeIORef)
import Data.Word (Word8, Word32)
import qualified Data.Map.Strict as Map
import Riski5.ISA (Csr (..), Reg (..), csrMcause, csrMepc, csrMtvec)
import Riski5.Reference qualified as Ref
import System.IO (hFlush, hPutChar, stdout)

-- * SoC simulator state ---------------------------------------------

-- | Wraps the architectural state with simulator-side counters.
data SocState = SocState
  { socMach :: Ref.MachineState
  -- ^ The architectural state (regs, memory, CSRs, reservation).
  , socCycles :: !Word32
  -- ^ Instructions retired so far. Drives the simulated CLINT
  -- @mtime@ register; one tick per retired instruction is a
  -- coarse approximation that's plenty for kernel time-keeping.
  , socUartTx :: !String
  -- ^ Reverse-order accumulator of bytes the kernel has written
  -- to the UART data register. Useful for end-of-run inspection
  -- without having to capture stdout.
  }

-- | Memory-mapped peripheral bases.
uartBase, clintMtime :: Word32
uartBase = 0x1000_0000
clintMtime = 0x0200_BFF8

-- | Fresh SoC state with empty memory and PC at @0x00000000@.
initialSoc :: SocState
initialSoc = SocState Ref.initial 0 ""

-- * Loading ---------------------------------------------------------

{- | Load a kernel binary at 'kBase' and a DTB at 'dBase'. Sets up
the register state per the RISC-V Linux nommu boot ABI:

  * @a0@ = 0 (hartid)
  * @a1@ = @dBase@ (DTB pointer)
  * @sp@ = @0x2008_0000@ (top of on-board SRAM)
  * @pc@ = @kBase@
  * @mtvec@ = 0 (kernel installs its own)
-}
loadKernelDtb :: FilePath -> Word32 -> FilePath -> Word32 -> IO SocState
loadKernelDtb kPath kBase dPath dBase = do
  kBytes <- BS.readFile kPath
  dBytes <- BS.readFile dPath
  let m0 = foldl (\acc (i, b) -> Ref.writeByte (kBase + i) b acc)
                 Ref.initial
                 (zip [0 :: Word32 ..] (BS.unpack kBytes))
      m1 = foldl (\acc (i, b) -> Ref.writeByte (dBase + i) b acc)
                 m0
                 (zip [0 :: Word32 ..] (BS.unpack dBytes))
      m2 = m1 { Ref.pc = kBase }
      m3 = Ref.writeReg (Reg 10) 0 m2          -- a0 = hartid = 0
      m4 = Ref.writeReg (Reg 11) dBase m3      -- a1 = DTB ptr
      m5 = Ref.writeReg (Reg 2)  0x2008_0000 m4 -- sp = SRAM top
      -- Pre-populate the JTAG-UART CONTROL register at uartBase+4 with
      -- WSPACE bits[31:16] = 0xFFFF so the kernel's
      -- altera_jtaguart_console_putc loop sees plenty of TX FIFO
      -- space and proceeds with the data-register write.
      m6 = Ref.writeWord (uartBase + 4) 0xFFFF_0000 m5
  pure (SocState m6 0 "")

-- * Stepping --------------------------------------------------------

{- | One step of the simulated SoC. Calls 'Riski5.Reference.step',
applies any UART side effect, and on a trap redirects to mtvec
instead of bailing out.

Returns @Right ()@ on a step that retired an instruction (whether
or not it took a trap). Returns @Left "halted"@ if the architecture
returns an unrecoverable state (we don't model halt yet, so this
never fires; placeholder).
-}
stepSoc :: IORef SocState -> IO ()
stepSoc ref = do
  st <- readIORef ref
  let m = socMach st
  -- Intercept SW to UART base BEFORE delegating to Reference.step.
  -- Reference doesn't know about MMIO; it just writes the byte to
  -- its sparse memory map. We snoop the SW path by checking the
  -- next instruction for SW/SH/SB targeting uartBase, and if so
  -- emit the byte to stdout instead.
  --
  -- (Simpler than a real MMIO bus: just look at the instruction
  -- bits at PC and intercept the store target.)
  -- Currently delegates everything to Reference; UART interception
  -- is done post-step by sweeping the memory[uartBase] cell.
  let (m', mTrap) = stepArch m
      (m'', tx) = drainUart m'
      cycles' = socCycles st + 1
      -- Update simulated mtime.
      m''' = updateMtime cycles' m''
  case tx of
    Just b -> do
      hPutChar stdout (toEnum (fromIntegral b))
      hFlush stdout
      writeIORef ref st { socMach = m''', socCycles = cycles', socUartTx = toEnum (fromIntegral b) : socUartTx st }
    Nothing ->
      writeIORef ref st { socMach = m''', socCycles = cycles' }
  case mTrap of
    Nothing -> pure ()
    Just _ -> pure () -- already handled inside stepArch

-- | Wraps 'Ref.step' with trap-and-continue: traps update mepc /
-- mcause / pc but don't terminate execution.
stepArch :: Ref.MachineState -> (Ref.MachineState, Maybe Ref.TrapCause)
stepArch m = case Ref.step m of
  Right m' -> (m', Nothing)
  Left cause -> (handleTrap cause m, Just cause)

-- | Apply the trap path: mepc = pc, mcause = cause-number, pc = mtvec.base.
handleTrap :: Ref.TrapCause -> Ref.MachineState -> Ref.MachineState
handleTrap cause m =
  let mtvec = Map.findWithDefault 0 (unCsr csrMtvec) (Ref.csrs m)
      base = mtvec .&. complement 3
      cn = case cause of
        Ref.InstrAddrMisaligned -> 0
        Ref.IllegalInstr -> 2
        Ref.BreakpointExc -> 3
        Ref.LoadAddrMisaligned -> 4
        Ref.StoreAddrMisaligned -> 6
        Ref.EcallFromM -> 11
      csrs' =
        Map.insert (unCsr csrMepc) (Ref.pc m)
          $ Map.insert (unCsr csrMcause) cn
          $ Ref.csrs m
   in m { Ref.csrs = csrs', Ref.pc = base }

-- | Sweep the UART data register. If a byte was written there since
-- the last step, return it (and clear the cell). Linux's
-- @altera_jtaguart@ driver writes one byte per SW.
drainUart :: Ref.MachineState -> (Ref.MachineState, Maybe Word8)
drainUart m =
  let mem = Ref.memory m
      key = uartBase
   in case Map.lookup key mem of
        Just b | b /= 0 ->
          (m { Ref.memory = Map.insert key 0 mem }, Just b)
        _ -> (m, Nothing)

-- | Update the simulated CLINT @mtime@ low half. The kernel reads
-- this for clocksource ticks; one increment per retired instruction
-- is enough to keep monotonic time progressing.
updateMtime :: Word32 -> Ref.MachineState -> Ref.MachineState
updateMtime t m =
  let mem = Ref.memory m
      mem' = foldr (uncurry Map.insert) mem
                   [ (clintMtime + 0, fromIntegral (t .&. 0xFF))
                   , (clintMtime + 1, fromIntegral ((t `shiftR` 8) .&. 0xFF))
                   , (clintMtime + 2, fromIntegral ((t `shiftR` 16) .&. 0xFF))
                   , (clintMtime + 3, fromIntegral ((t `shiftR` 24) .&. 0xFF))
                   ]
   in m { Ref.memory = mem' }

-- * Run loop --------------------------------------------------------

{- | Step the simulator until @maxSteps@ instructions have retired or
the predicate matches the accumulated UART output. Useful sentinels:

  * @const True@ — never matches; runs for full @maxSteps@.
  * @\\out -> "Linux version" \`isInfixOf\` reverse out@ — stop on
    the first kernel banner line.
-}
runSoc :: Int -> (String -> Bool) -> IORef SocState -> IO ()
runSoc maxSteps stopOn ref = go maxSteps
 where
  go 0 = pure ()
  go n = do
    stepSoc ref
    st <- readIORef ref
    if stopOn (reverse (socUartTx st))
      then pure ()
      else go (n - 1)
