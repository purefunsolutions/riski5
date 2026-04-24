-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : HelloSramExec
Description : Debug firmware — try to execute code from SRAM.

Answers the question: does the core fetch correctly when the PC
is in the SRAM address range (0x2000_0000..0x2007_FFFF)? The
current SoC wires @imemDataS@ directly to the BRAM 'progInit'
with @pcFetch \`mod\` ProgSize@ as the index, so __by construction
any fetch wraps into BRAM__. This firmware makes that hypothesis
observable on silicon.

Flow:

  1. UART-print @B@ — confirms we're executing from BRAM and
     the bus + UART are up.

  2. Write two pre-assembled instructions into SRAM via the
     bus:

       SRAM[0x2000_0000] = @sw x14, 0(x10)@   ; 0x00E5_2023
       SRAM[0x2000_0004] = @ebreak@           ; 0x0010_0073

     @x10@ holds the UART DATA address, @x14@ holds the
     constant 'S'. The @sw@ prints 'S'; the @ebreak@ triggers
     a breakpoint trap so we don't wander off into whatever
     SRAM[0x2000_0008..] contains.

  3. @jalr x0, x12, 0@ where @x12 = 0x2000_0000@ — jump to
     SRAM's first instruction.

Observable outcomes on the UART:

  * __@BS@__ (then silence from the ebreak trap)
      — SRAM execution __works__. The core fetched SRAM[0],
        ran the @sw@, then fetched SRAM[4] (ebreak) and
        jumped to @mtvec.base@ which (in this firmware) sits
        on unmapped code and traps again or spins.

  * __@BBBB...@__ (infinite @B@ stream)
      — SRAM execution __does not work__. The @jalr@ set PC
        to @0x2000_0000@, but the SoC's @addrToImemIdx@ hashes
        that @\`mod\` 4096 = 0@ and returns the first word of
        BRAM — which restarts the firmware. Each loop prints
        a fresh 'B' and loops back.

  * Anything else
      — interesting surprise; note the exact byte stream and
        trace from there.

This firmware is the simplest possible probe; if "SRAM exec works"
we'd follow up with richer patterns (reads from @.rodata@ placed
in SRAM, function calls between BRAM and SRAM, etc.) to validate
the fetch path under more of the cases CoreMark would hit.
-}
module HelloSramExec (
  helloSramExecFirmware,
  helloSramExecFirmwareWords,
) where

import Clash.Prelude (BitVector, Signed)
import Data.Either qualified as DE
import Data.Int (Int32)
import Riski5.Asm
import Riski5.ISA
import Prelude qualified as P

-- | Pre-computed instruction encodings — avoid depending on
-- runtime assembly for these two bytes inside SRAM. Verify by
-- hand (or with `riscv32-none-elf-as`) if touched.
--
-- Encoding breakdown:
--
--   sw x14, 0(x10)   = S-type
--     opcode = 0100011, funct3 = 010,
--     rs1 = 01010 (x10), rs2 = 01110 (x14), imm = 0
--     ⇒ 0b0000000_01110_01010_010_00000_0100011 = 0x00E5_2023
--
--   ebreak           = I-type immediate in funct12 slot
--     opcode = 1110011, funct3 = 000,
--     rd = 0, rs1 = 0, imm = 0x001
--     ⇒ 0b000000000001_00000_000_00000_1110011 = 0x0010_0073
encodedSw_x14_0_x10 :: Int32
encodedSw_x14_0_x10 = 0x00E5_2023

encodedEbreak :: Int32
encodedEbreak = 0x0010_0073

-- * Firmware -------------------------------------------------------

helloSramExecFirmware :: Asm ()
helloSramExecFirmware = do
  -- UART DATA register = 0x1000_0000.
  li uartReg 0x1000_0000

  -- Print 'B' — first byte on the wire confirms BRAM exec +
  -- bus + UART all work.
  addi tmpReg x0 (0x42 :: Signed 12) -- 'B'
  sw uartReg tmpReg 0

  -- Pin 'S' into x14 so the SRAM routine can use it as rs2 of
  -- the SW it's about to execute.
  addi sramChar x0 (0x53 :: Signed 12) -- 'S'

  -- SRAM base.
  li sramAddr 0x2000_0000

  -- Write SRAM[0] = `sw x14, 0(x10)`.
  li encReg encodedSw_x14_0_x10
  sw sramAddr encReg 0

  -- Write SRAM[4] = `ebreak`.
  li encReg encodedEbreak
  sw sramAddr encReg 4

  -- Jump to SRAM[0] — the moment of truth.
  jalr x0 sramAddr 0

  -- Fallback: only reached if the JALR somehow doesn't take
  -- (shouldn't happen). Spin.
  halt <- label
  j halt
 where
  uartReg = x10 -- a0
  tmpReg = x11 -- a1
  sramChar = x14 -- a4: carries 'S' to the SRAM routine
  sramAddr = x12 -- a2
  encReg = x13 -- a3

helloSramExecFirmwareWords :: [BitVector 32]
helloSramExecFirmwareWords =
  DE.fromRight
    (P.error "helloSramExecFirmware failed to assemble")
    (assemble helloSramExecFirmware)
