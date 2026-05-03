-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Top
Description : DE2 top entity — Clash → Verilog → Quartus → .sof.

Synthesises into a Verilog module named @riski5@ that matches the
port names in @pkgs/riski5-core/Riski5.qsf@. The UART slave bus is
exposed as five top-level output ports plus one input port
(@UART_RDATA@) so that the outer @riski5_top.v@ wrapper (generated
in @pkgs/riski5-core/package.nix@) can instantiate the Altera
@altera_avalon_jtag_uart@ IP at that boundary — sim still sees
'jtagUartSim' via 'Riski5.Soc.socSim', hardware sees the real IP,
and the core does not need to know which.

Baked-in firmware: the @Hello@ image from @firmware/phase1/Hello.hs@
— boots, UART-banners @hello, world\\n@, runs a SRAM self-test, and
displays the result on the LCD. At first hardware run this is the
canonical end-to-end smoke test for the core, bus, SRAM, LCD and
UART path combined.
-}
module Top (
  topEntity,
) where

import Clash.Annotations.TH (makeTopEntityWithName)
import Clash.Prelude
#ifdef FIRMWARE_COREMARK
import CoreMark (coreMarkFirmwareWords)
#else
import MemTest (memTestFirmwareWords)
#endif
import FetchPolicy (enableSdramFetch, enableSramFetch)
import Riski5.AvalonMm (AvalonMmBus (..))
import Riski5.Domains (DomBus, DomSdram)
import Riski5.SdramCdcBridge (sdramCdcBridge)
import Riski5.Lcd (LcdPins (..))
import Riski5.SdrController (
  SdrPins (..),
  defaultDe2Config,
  defaultDe2ConfigForClockHz,
  sdrControllerAsAlteraIp,
  sdrControllerAsAlteraIpRegistered,
 )
import Riski5.Soc (SocIn (..), SocOut (..), soc)
-- soDbgPcFetch is exported as part of SocOut (..) above; the
-- field selector is in scope thanks to RecordDotSyntax / the
-- record-import wildcard. Listed here for grep visibility.
import Riski5.Sram (SramPins (..))
import Prelude qualified as P

-- * Clock domain --------------------------------------------------

{- | Bus + core clock domain — 40 MHz, period 25 ns. Under the
multi-PLL topology in @riski5_top.v@ (task #141) this is the
output of @u_altpll|clk[0]@ (50 × 4 / 5 = 40 MHz). The riski5
SoC and the Altera JTAG-UART + JTAG-Master IPs all share this
clock; the Altera SDRAM Controller IP runs on a separate
@clkSdram@ at 30 MHz with a Verilog-side toggle-handshake CDC
bridge between the Clash @Riski5.Sdram@ adapter outputs (clkBus)
and the IP's slave port (clkSdram). Slow-85 °C STA reports
54.89 MHz Fmax with +1.78 ns slack — comfortable for the current
5-stage + async-regfile + async-dmem shape; phase 2B / 2C will
shorten the X cone (M4K regfile, sync dmem + D\$) and lift the
ceiling past 60 MHz.

The Clash top takes the PLL outputs as input clocks rather than
owning a PLL itself, so the wrapper is the single source of truth
for clock topology. Reset is held asserted until both PLLs have
locked and KEY[0] has been released.

A future commit will split the RISC-V core out onto its own
@clkCore@ domain — the wrapper already generates @clkCore@ as a
separate PLL output (currently tied electrically to @clkBus@); a
Clash-side refactor of @Riski5.Soc@ to expose the core's bus
interface as a top-entity boundary is what gates the actual
domain split.
-}
-- The DomBus / DomCore / DomSdram domain declarations live in
-- Riski5.Domains so the multi-PLL split (Phase A onwards) can
-- reference all three from one source of truth. DomBus's period
-- defaults to 25_000 ps = 40 MHz, matching the prior local
-- definition; it's CPP-overrideable via @-DSOC_BUS_PERIOD_PS@.

-- | SoC bus clock frequency in Hz. Set by the build system via
-- the @-DSOC_CLOCK_HZ=...@ CPP define from
-- @pkgs/riski5-core/package.nix@ (computed from @pllBusMultBy@:
-- @50e6 × pllBusMultBy / 5@). Defaults to 40 MHz so a plain
-- @cabal build@ without the build-system define also works.
--
-- Used by anything in DomBus that needs to know the actual clock
-- rate (currently nothing — the SDRAM controller config now reads
-- 'sdramClockHz' instead since it lives in DomSdram after Phase C).
socClockHz :: Int
socClockHz =
#ifdef SOC_CLOCK_HZ
  SOC_CLOCK_HZ
#else
  40_000_000
#endif

-- | SDRAM domain clock frequency in Hz. Set by the build system
-- via the @-DSOC_SDRAM_CLOCK_HZ=...@ CPP define from
-- @pkgs/riski5-core/package.nix@ (computed from @pllSdramMultBy@
-- and @pllSdramDivBy@: @50e6 × multBy / divBy@). Defaults to
-- 133_333_333 Hz (M=8, D=3) so a plain @cabal build@ matches
-- the chip-spec rate even without the build-system define.
--
-- This value flows into 'defaultDe2ConfigForClockHz' so the SDRAM
-- controller's refresh interval and power-up NOP delay scale
-- correctly. At 133 MHz the scaled values become refresh=2000
-- cycles (15 µs) and init NOPs=13433 cycles (≈ 100.7 µs).
sdramClockHz :: Int
sdramClockHz =
#ifdef SOC_SDRAM_CLOCK_HZ
  SOC_SDRAM_CLOCK_HZ
#else
  133_333_333
#endif

-- * Firmware --------------------------------------------------------

{- | 4096-word (16 KB) instruction memory — grown from 2048 in CM-3
to fit an eventual CoreMark firmware image (.text + .rodata ≈
14.6 KB at -O2, measured with the phase-2 port at
@firmware/phase2/coremark-port/@). The current bitstream still
bakes the phase-2-P2-A BIOS memtest firmware at the head; the
unused tail words are NOPs, so pc-overflow wraps to NOP rather
than producing undefined behaviour.

M4K cost: each @blockRam@ over a 4096 × 32-bit image is ~32 M4K
(at the 128 × 36 aspect). The SoC now instantiates two of them
— one fetch port plus one bus-read port for loads at
@0x0000_0000+@ — that share 'progInit'. Quartus's fitter will
either (a) map both onto a single true-dual-port M4K tile
(~32 M4K total) when the identical-init hint is picked up, or
(b) duplicate (~64 M4K). Either sits inside the EP2C35's 105-
block pool; we're still under the ~58-block reserve for
phase-2C caches in case (a), just slightly into it in case (b)
— follow-up commits will narrow the reserve as needed.
-}
type ProgSize = 4096

-- | Unused since CM-3. Kept as a non-zero dummy so the SoC's
-- @1 <= d@ constraint on the dataInit parameter remains satisfied;
-- the actual data-memory role at @0x0000_0000@ is now served by
-- the imem bus-read port in "Riski5.Soc".
type DataSize = 1

-- | Selected via CPP: @-DFIRMWARE_COREMARK@ bakes the CoreMark image
-- (produced by 'pkgs/coremark' + overlaid onto 'firmware/phase1/CoreMark.hs'
-- by the CoreMark-variant build in 'pkgs/riski5-core/package.nix'); the
-- default is the phase-2 BIOS memtest firmware.
firmwareImage :: Vec ProgSize (BitVector 32)
firmwareImage =
#ifdef FIRMWARE_COREMARK
  $(listToVecTH (P.take 4096 (coreMarkFirmwareWords P.++ P.repeat (0x0000_0013 :: BitVector 32))))
#else
  $(listToVecTH (P.take 4096 (memTestFirmwareWords P.++ P.repeat (0x0000_0013 :: BitVector 32))))
#endif

dataImage :: Vec DataSize (BitVector 32)
dataImage = repeat 0

-- * Top entity -----------------------------------------------------

{- |
DE2 top-level entity.
-}
topEntity ::
  {- | 40 MHz bus clock — the output of @u_altpll_bus|clk[0]@ in the
  @riski5_top.v@ wrapper outside the Clash module.
  -}
  "CLOCK_BUS" ::: Clock DomBus ->
  {- | Active-low reset, held asserted until @u_altpll_bus@ has
  locked and @KEY[0]@ has been released. Synchronised into
  DomBus by the wrapper.
  -}
  "RESET_BUS_N" ::: Reset DomBus ->
  {- | 133.33 MHz SDRAM controller clock — the output of
  @u_altpll_sdram|clk[0]@. Multi-PLL Phase C: the SDRAM
  controller and the chip-side @DRAM_*@ pin drivers move to this
  separate domain so they can run at the chip's rated clock
  without dragging the rest of the SoC up. The bus-side
  @Riski5.Sdram@ adapter (32↔16 split) stays in DomBus; CDC
  between the two is the @Riski5.SdramCdcBridge.sdramCdcBridge@
  toggle handshake instantiated in this module's body.
  -}
  "CLOCK_SDRAM" ::: Clock DomSdram ->
  {- | Active-low reset for DomSdram. Held asserted until
  @u_altpll_sdram@ has locked. Synchronised into DomSdram by
  the wrapper.
  -}
  "RESET_SDRAM_N" ::: Reset DomSdram ->
  "KEY" ::: Signal DomBus (BitVector 4) ->
  "SW" ::: Signal DomBus (BitVector 18) ->
  {- | What the SRAM is currently driving on its DQ bus, sampled
  combinationally. The pin-multiplex wrapper produced by the
  Nix build resolves this against 'SRAM_DQ_O' / 'SRAM_DQ_OE'
  on the actual bidirectional SRAM_DQ[15:0] FPGA pads.
  -}
  "SRAM_DQ_I" ::: Signal DomBus (BitVector 16) ->
  {- | Read data returned by the Altera JTAG UART IP for the last
  bus transaction. Driven by @altera_avalon_jtag_uart@'s
  @av_readdata@ output in the @riski5_top.v@ wrapper generated
  by @pkgs/riski5-core/package.nix@.
  -}
  "UART_RDATA" ::: Signal DomBus (BitVector 32) ->
  {- | Complement of the IP's @av_waitrequest@. Low for the first
  cycle of every UART transaction (when the IP latches write-data
  registered); the SoC's stall logic freezes the core until this
  goes high, so @av_writedata@ is still stable at the edge the
  IP's FIFO captures it.
  -}
  "UART_READY" ::: Signal DomBus Bool ->
  {- | The Altera JTAG-UART IP's @av_irq@ output, routed through
  the @riski5_top.v@ wrapper. Active-high while the IP wants to
  raise an interrupt — typically because firmware has set
  @CONTROL.RE@ and the RX FIFO has data, or because firmware has
  set @CONTROL.WE@ and the TX FIFO has space. The SoC routes this
  to PLIC source 1, which drives @meipS@ → @mip.MEIP@ when
  enabled. CoreMark and other phase-1 firmware never enable the
  IP's IRQ controls so the line stays low and the new wire is
  dead-coded by Quartus on the hot path.
  -}
  "UART_IRQ" ::: Signal DomBus Bool ->
  {- | What the SDRAM chip is currently driving on its DQ bus
  (@DRAM_DQ@), sampled combinationally. The pin-multiplex
  wrapper produced by the Nix build resolves this against
  @SDRAM_DQ_OUT@ / @SDRAM_DQ_OE@ on the actual bidirectional
  @DRAM_DQ[15:0]@ FPGA pads. Replaces the previous trio of
  @SDRAM_RDATA@ / @SDRAM_VALID@ / @SDRAM_READY@ inputs (which
  came from the Altera @altera_avalon_new_sdram_controller@
  IP) — task #146 swapped that IP out for a pure-Clash
  controller in 'Riski5.SdrController' so the upper-half-word
  write drop bug is fixed at the hardware layer.
  -}
  "SDRAM_DQ_IN" ::: Signal DomSdram (BitVector 16) ->
  {- | Re-arm pulse for the freeze-on-trigger capture (see
  'Riski5.Soc.SocOut.soDbgFrozenPc'). The @riski5_top.v@ wrapper
  drives this from a 1-bit @altsource_probe@ source pin so
  software can pulse @write_source_data@ to clear the
  capture state machine and re-arm the snapshot for the next
  trigger event.
  -}
  "DEBUG_RESET_CAPTURE" ::: Signal DomBus Bool ->
  {- | 2-bit offset selector for the freeze-on-trigger snapshot.
  The capture FSM stores 4 consecutive cycles starting at the
  trigger; this signal selects which one is exposed via the
  @FRZP@ / @FRZF@ probes. Driven by the @OFFS@
  @altsource_probe@ source.
  -}
  "DEBUG_CAPTURE_OFFSET" ::: Signal DomBus (Unsigned 2) ->
  {- | L-3 JTAG-load mode select. When 'True', the JTAG-load
  inputs below own the SDRAM IP slave port; when 'False' (the
  default in normal silicon operation), the riski5 core drives
  SDRAM via its existing master path. Driven on hardware by
  altsource_probe source instance @JLMD@.
  -}
  "JTAG_LOAD_MODE" ::: Signal DomBus Bool ->
  -- | L-3 JTAG-load: byte address for the next SDRAM transaction
  --   (source @JLAD@). Ignored when @JTAG_LOAD_MODE = False@.
  "JTAG_LOAD_ADDR" ::: Signal DomBus (BitVector 32) ->
  -- | L-3 JTAG-load: 32-bit write data (source @JLDW@).
  "JTAG_LOAD_WDATA" ::: Signal DomBus (BitVector 32) ->
  -- | L-3 JTAG-load: pulse-high to commit a write (source
  --   @JLWE@); the Tcl script writes 1 then 0.
  "JTAG_LOAD_WE" ::: Signal DomBus Bool ->
  -- | L-3 JTAG-load: pulse-high to issue a read (source @JLRD@).
  --   The result lands on @JTAG_LOAD_RDATA@ once
  --   @JTAG_LOAD_BUSY@ deasserts.
  "JTAG_LOAD_RD" ::: Signal DomBus Bool ->
  -- | L-3 JTAG-load: 4-bit byte-enable for the JTAG-Master write
  --   (active-high). Wired straight from the Altera
  --   JTAG-Avalon-Master IP's @master_byteenable@ output via the
  --   wrapper. Lets master_write_8 / master_write_16 actually mask
  --   the chip-side byte lanes; an earlier revision hard-coded
  --   this to @0xF@ inside @jtagMuxedSdram@ which silently
  --   promoted every JTAG sub-word write into a 32-bit write
  --   (surfaced by the LSWP probe on 2026-05-01).
  "JTAG_LOAD_BE" ::: Signal DomBus (BitVector 4) ->
  ""
    ::: ( "LEDR" ::: Signal DomBus (BitVector 18)
        , "LEDG" ::: Signal DomBus (BitVector 9)
        , "LCD_DATA" ::: Signal DomBus (BitVector 8)
        , "LCD_RS" ::: Signal DomBus Bit
        , "LCD_RW" ::: Signal DomBus Bit
        , "LCD_EN" ::: Signal DomBus Bit
        , "LCD_ON" ::: Signal DomBus Bit
        , "LCD_BLON" ::: Signal DomBus Bit
        , "SRAM_ADDR" ::: Signal DomBus (BitVector 18)
        , "SRAM_DQ_O" ::: Signal DomBus (BitVector 16)
        , "SRAM_DQ_OE" ::: Signal DomBus Bool
        , "SRAM_CE_N" ::: Signal DomBus Bit
        , "SRAM_OE_N" ::: Signal DomBus Bit
        , "SRAM_WE_N" ::: Signal DomBus Bit
        , "SRAM_UB_N" ::: Signal DomBus Bit
        , "SRAM_LB_N" ::: Signal DomBus Bit
        , -- UART bus tap — routed in @riski5_top.v@ to the Altera
          -- @altera_avalon_jtag_uart@ IP's Avalon-MM slave. The IP
          -- consumes these signals and drives @UART_RDATA@ back in
          -- on the same (DomBus) cycle.
          "UART_SEL" ::: Signal DomBus Bool
        , "UART_ADDR" ::: Signal DomBus (BitVector 32)
        , "UART_WDATA" ::: Signal DomBus (BitVector 32)
        , "UART_BE" ::: Signal DomBus (BitVector 4)
        , "UART_RE" ::: Signal DomBus Bool
        , -- SDRAM chip-side pins — driven by 'Riski5.SdrController'
          -- via the 'sdrControllerAsAlteraIp' drop-in wrapper, now
          -- elaborated in @DomSdram@ (Phase C of the multi-PLL
          -- split). The bus-side adapter @Riski5.Sdram.sdram@ stays
          -- in @DomBus@; the toggle-handshake bridge
          -- @Riski5.SdramCdcBridge.sdramCdcBridge@ in this module's
          -- body crosses the boundary. The @riski5_top.v@ wrapper
          -- routes these chip pins to the DE2 board's @DRAM_*@ FPGA
          -- pads using @u_altpll_sdram@'s clock for I/O-cell
          -- timing.
          "SDRAM_ADDR_OUT" ::: Signal DomSdram (BitVector 12)
        , "SDRAM_BA" ::: Signal DomSdram (BitVector 2)
        , "SDRAM_CAS_N" ::: Signal DomSdram Bool
        , "SDRAM_CKE" ::: Signal DomSdram Bool
        , "SDRAM_CS_N" ::: Signal DomSdram Bool
        , "SDRAM_DQ_OUT" ::: Signal DomSdram (BitVector 16)
        , "SDRAM_DQ_OE" ::: Signal DomSdram Bool
        , "SDRAM_DQM" ::: Signal DomSdram (BitVector 2)
        , "SDRAM_RAS_N" ::: Signal DomSdram Bool
        , "SDRAM_WE_N" ::: Signal DomSdram Bool
        , -- Debug tap. Carries 'soDbgPcFetch' = the core's pcFetchS.
          -- @riski5_top.v@ feeds this into an @altsource_probe@
          -- megafunction so @quartus_stp@'s @read_probe_data@ can
          -- sample the program counter at runtime over JTAG. Never
          -- assigned to a physical pin.
          "DEBUG_PCFETCH" ::: Signal DomBus (BitVector 32)
        , -- Second debug tap: 8 packed flags
          -- (stall / dataStall / fetchStall / uartAccepted /
          -- sramDataReady / uartReady / bramReady / reserved).
          "DEBUG_FLAGS" ::: Signal DomBus (BitVector 8)
        , -- All 4 freeze-on-trigger PC snapshots concatenated.
          -- bits [127:96] = pc_K (trigger cycle), [95:64] =
          -- pc_{K+1}, [63:32] = pc_{K+2}, [31:0] = pc_{K+3}.
          "DEBUG_FROZEN_PC" ::: Signal DomBus (BitVector 128)
        , -- All 4 frozen-flag snapshots concatenated. Each byte
          -- has the same layout as 'DEBUG_FLAGS' with bit [7]
          -- repurposed as @capturedS@.
          "DEBUG_FROZEN_FLAGS" ::: Signal DomBus (BitVector 32)
        , -- L-3 JTAG-load read-back. Driven by 'soJtagLoadRdata'.
          -- Exposed via altsource_probe @JLRR@.
          "JTAG_LOAD_RDATA" ::: Signal DomBus (BitVector 32)
        , -- L-3 JTAG-load busy strobe. Driven by 'soJtagLoadBusy'.
          -- Exposed via altsource_probe @JLBS@.
          "JTAG_LOAD_BUSY" ::: Signal DomBus Bool
        )
topEntity
  clkBus
  rstBus
  clkSdram
  rstSdram
  keyS
  swS
  sramDqInS
  uartRdataS
  uartReadyS
  uartIrqS
  sdramDqInS
  captureResetS
  captureOffsetS
  jtagLoadModeS
  jtagLoadAddrS
  jtagLoadWdataS
  jtagLoadWeS
  jtagLoadRdS
  jtagLoadBeS =
  withClockResetEnable clkBus rstBus enableGen
    $ let -- The SoC consumes 'sdramReplyS' inside 'inS' and produces
          -- the matching 'sdramBusS' inside 'outS'; we close the loop
          -- by feeding 'sdramBusS' into our pure-Clash SDR SDRAM
          -- controller and feeding its 'sdramReplyS' back into 'inS'.
          -- Clash's lazy 'let' tolerates the data-dependency cycle
          -- because the controller and the SoC each carry registers
          -- on this path.
          inS =
            ( \sw key dq ur urRdy urIrq sdr cr co jlm jla jlw jlwe jlrd jlbe ->
                SocIn
                  { siSwitches = sw
                  , siKeys = key
                  , siSramDqIn = dq
                  , siUartRdata = ur
                  , siUartReady = urRdy
                  , -- The Altera JTAG-UART IP's @av_irq@ output is
                    -- now routed through @riski5_top.v@ as a top-
                    -- level input on this Clash module. It feeds
                    -- PLIC source 1 (see 'Riski5.Soc.plicExtIrqsS').
                    siUartIrq = urIrq
                  , siSdramReply = sdr
                  , siCaptureReset = cr
                  , siCaptureOffset = co
                  , -- L-3 JTAG-load: when @jlm = True@ the JTAG hub
                    -- drives the SDRAM IP via @jla@/@jlw@/@jlwe@/@jlrd@;
                    -- when 'False' the riski5 core has SDRAM as usual
                    -- (the CoreMark path). The wrapper ties these to
                    -- altsource_probe sources @JLMD@ / @JLAD@ /
                    -- @JLDW@ / @JLWE@ / @JLRD@ in L-3b.
                    siJtagLoadMode = jlm
                  , siJtagLoadAddr = jla
                  , siJtagLoadWdata = jlw
                  , siJtagLoadWe = jlwe
                  , siJtagLoadRd = jlrd
                  , siJtagLoadBe = jlbe
                  })
              <$> swS
              <*> keyS
              <*> sramDqInS
              <*> uartRdataS
              <*> uartReadyS
              <*> uartIrqS
              <*> sdramReplyS
              <*> captureResetS
              <*> captureOffsetS
              <*> jtagLoadModeS
              <*> jtagLoadAddrS
              <*> jtagLoadWdataS
              <*> jtagLoadWeS
              <*> jtagLoadRdS
              <*> jtagLoadBeS
          outS = soc enableSramFetch enableSdramFetch firmwareImage dataImage inS
          sdramBusS = soSdramBus <$> outS
          -- Phase C: CDC bridge between the bus-side SDRAM bus
          -- (DomBus, from Riski5.Sdram.sdram's adapter) and the
          -- chip-side controller (DomSdram, running at the chip's
          -- 133 MHz spec). The bridge holds master-side
          -- waitrequest high for the round trip — adapter sees the
          -- same Avalon-MM protocol shape as before.
          (sdramReplyS, sdramBusInSdramS) =
            sdramCdcBridge
              clkBus rstBus enableGen
              clkSdram rstSdram enableGen
              sdramBusS
              sdramReplyInSdramS
          -- The SDRAM controller now elaborates in DomSdram. Its
          -- config uses sdramClockHz (the actual SDRAM rate), not
          -- the bus rate — so refresh interval and init NOP delay
          -- scale correctly per defaultDe2ConfigForClockHz.
          --
          -- Use the registered wrapper so Quartus can pack the
          -- DRAM_* output flops into Cyclone II I/O cells (the
          -- FAST_OUTPUT_REGISTER / FAST_OUTPUT_ENABLE_REGISTER /
          -- FAST_INPUT_REGISTER assignments in Riski5.qsf, with
          -- the matching SDC source-synchronous constraints in
          -- Riski5.sdc and the +90° DRAM_CLK in u_altpll_sdram).
          -- The two-cycle round-trip latency it adds is matched
          -- by 'sdrPipelineLatency = 2' in defaultDe2ConfigForClockHz.
          (sdramReplyInSdramS, sdramPinsS) =
            withClockResetEnable clkSdram rstSdram enableGen $
              sdrControllerAsAlteraIpRegistered
                (defaultDe2ConfigForClockHz sdramClockHz)
                sdramBusInSdramS
                sdramDqInS
          ledrS = soLedR <$> outS
          ledgS = soLedG <$> outS
          lcdDataS = lcdData . soLcdPins <$> outS
          lcdRsS = lcdRs . soLcdPins <$> outS
          lcdRwS = lcdRw . soLcdPins <$> outS
          lcdEnS = lcdE . soLcdPins <$> outS
          lcdOnS = pure high
          -- LCD_BLON is active-HIGH per the DE2 schematic
          -- (pin K2 → R14/680Ω → base of Q5 8050 NPN → BL pin of
          -- the LCD module). Hardware on this brand-new board
          -- has no backlight LED installed (T19a). Drive HIGH
          -- to match schematic intent.
          lcdBlonS = pure high
          sramAddrS = sramAddr . soSramPins <$> outS
          sramDqOutS = sramDqOut . soSramPins <$> outS
          sramDqOeS = sramDqOe . soSramPins <$> outS
          sramCeNS = sramCeN . soSramPins <$> outS
          sramOeNS = sramOeN . soSramPins <$> outS
          sramWeNS = sramWeN . soSramPins <$> outS
          sramUbNS = sramUbN . soSramPins <$> outS
          sramLbNS = sramLbN . soSramPins <$> outS
          uartBusS = soUartBus <$> outS
          uartSelS = ambSel <$> uartBusS
          uartAddrS = ambAddr <$> uartBusS
          uartWdataS = ambWdata <$> uartBusS
          uartBeS = ambBe <$> uartBusS
          uartReS = ambRe <$> uartBusS
          sdramAddrOutS = sdrAddr <$> sdramPinsS
          sdramBaS = sdrBa <$> sdramPinsS
          sdramCasNS = sdrCasN <$> sdramPinsS
          sdramCkeS = sdrCke <$> sdramPinsS
          sdramCsNS = sdrCsN <$> sdramPinsS
          sdramDqOutS = sdrDqOut <$> sdramPinsS
          sdramDqOeS = sdrDqOe <$> sdramPinsS
          sdramDqmS = sdrDqm <$> sdramPinsS
          sdramRasNS = sdrRasN <$> sdramPinsS
          sdramWeNS = sdrWeN <$> sdramPinsS
          dbgPcFetchS = soDbgPcFetch <$> outS
          dbgFlagsS' = soDbgFlags <$> outS
          dbgFrozenPcS = soDbgFrozenPcAll <$> outS
          dbgFrozenFlagsS = soDbgFrozenFlagsAll <$> outS
          jtagLoadRdataS = soJtagLoadRdata <$> outS
          jtagLoadBusyS = soJtagLoadBusy <$> outS
       in ( ledrS
          , ledgS
          , lcdDataS
          , lcdRsS
          , lcdRwS
          , lcdEnS
          , lcdOnS
          , lcdBlonS
          , sramAddrS
          , sramDqOutS
          , sramDqOeS
          , sramCeNS
          , sramOeNS
          , sramWeNS
          , sramUbNS
          , sramLbNS
          , uartSelS
          , uartAddrS
          , uartWdataS
          , uartBeS
          , uartReS
          , sdramAddrOutS
          , sdramBaS
          , sdramCasNS
          , sdramCkeS
          , sdramCsNS
          , sdramDqOutS
          , sdramDqOeS
          , sdramDqmS
          , sdramRasNS
          , sdramWeNS
          , dbgPcFetchS
          , dbgFlagsS'
          , dbgFrozenPcS
          , dbgFrozenFlagsS
          , jtagLoadRdataS
          , jtagLoadBusyS
          )

{- | Exported Clash-usable top-entity annotation so
@clash --verilog Top.hs@ emits a module named @riski5@ with the
port names declared above.
-}
makeTopEntityWithName 'topEntity "riski5"
