-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Riski5.Soc
Description : Riski5 SoC top — core + memory + peripherals on a bus.

Wires 'Riski5.Core.core' up to its memory map: a pair of BRAM
instances (imem + dmem) plus the JTAG UART, LCD, and GPIO
peripherals, all selected by a trivial address decoder derived
from 'Riski5.MemMap.slaveOf'.

Phase-1 SoC layout:

@
  ┌───────────┐
  │   Core    │◀── imemData ── Bram (program)
  │           │◀── dmemRData ─┬─ Bram (data)
  │           │── pc ─────────┘
  │           │── dmemAddr ──────┬── bus decoder
  │           │── dmemWdata/be ──┤
  │           │── dmemRen ───────┘       │
  └───────────┘                          │
                 ┌───────────────────────┤
                 │          │            │
                 ▼          ▼            ▼
             JtagUart    Lcd          Gpio
                 │          │            │
                 ▼          ▼            ▼
              TX byte    LCD pins      LEDR / LEDG
@

The imem is a parameterised 'Vec' so tests can load different
programs; the data BRAM starts zero-initialised. On real hardware,
Quartus's @.mif@ loader populates the imem at power-on and the
core simply executes from address 0.
-}
module Riski5.Soc (
  soc,
  socSim,
  socSimAlteraUart,
  socSimFull,
  SocIn (..),
  SocInSim (..),
  SocInFull (..),
  SocOut (..),
  SocOutSim (..),
) where

import Clash.Prelude hiding (And, Xor, not)
import Clash.Prelude qualified as CP
import Data.Proxy (Proxy (..))
import Riski5.AvalonMm (AvalonMmBus (..))
import Riski5.Core.Assembly (coreWith)
import Riski5.Core.Presets (tiny32M)
import Riski5.Gpio (GpioIn (..), GpioOut (..), gpio)
import Riski5.JtagUart (jtagUartAlteraSim, jtagUartSim)
import Riski5.Lcd (LcdPins (..), lcd)
import Riski5.MemMap (SlaveId (..), slaveOf)
import Riski5.Sdram (SdramIpBus, SdramIpReply, sdram, sdramIpSim)
import Riski5.Sram (SramPins (..), sram, sramChipSim)

{- |
Inputs the SoC reads from the board.

The UART read-data channel @siUartRdata@ is an externalised bus tap:
the SoC's bus decoder produces a UART-slave select via 'soUartBus'
and the slave (either the Altera IP on hardware or 'jtagUartSim' in
simulation) drives @siUartRdata@ back in the same cycle. Tests use
'socSim' which wires this loop up automatically.
-}
data SocIn = SocIn
  { siSwitches :: BitVector 18
  , siKeys :: BitVector 4
  , siSramDqIn :: BitVector 16
  {- ^ What the off-chip SRAM is currently driving on @SRAM_DQ@.
  Read combinationally on the cycle the controller is reading
  (i.e. @SRAM_OE_N == 0@); ignored otherwise. In simulation,
  the test harness wraps the SoC with 'Riski5.Sram.sramSim' to
  provide a model of the off-chip chip.
  -}
  , siUartRdata :: BitVector 32
  {- ^ Read data from the UART slave (either the Altera IP on
  hardware or 'jtagUartSim' in simulation). Driven combinationally
  from 'soUartBus' within the same cycle.
  -}
  , siUartReady :: Bool
  {- ^ Complement of the Altera IP's @av_waitrequest@. The IP
  asserts waitrequest on the first cycle of every transaction
  (it latches write-data one cycle after the master presents it);
  until it deasserts we must hold bus signals. The 'jtagUartSim'
  model returns constant @True@ because the sim model has no
  registered write-data path.
  -}
  , siSdramReply :: SdramIpReply
  {- ^ Slave → master return channel from the Altera SDRAM
  Controller IP (or 'sdramIpSim' in sim). Carries @za_data@,
  @za_valid@, and @~za_waitrequest@; the SoC's stall logic
  feeds @~waitrequest@ back to the core and the 'Riski5.Sdram'
  adapter latches @za_data@ when @za_valid@ pulses.
  -}
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- |
Outputs the SoC drives to the board.
-}
data SocOut = SocOut
  { soLedR :: BitVector 18
  , soLedG :: BitVector 9
  , soLcdPins :: LcdPins
  , soLcdIrq :: Bool
  {- ^ Rising on the busy-falling edge of the LCD controller, held
  until firmware writes-1-to-clear STATUS[1]. Wire through the
  phase-3 PLIC when we have one; today the simulation harness
  watches it so tests don't need to spin on the busy flag.
  -}
  , soSramPins :: SramPins
  , soUartBus :: AvalonMmBus
  {- ^ Live bus tap for the UART slave, in the canonical Avalon-MM
  master-side shape (see "Riski5.AvalonMm"). On hardware, routed
  through 'app/Top.hs' to the Altera JTAG UART IP; in simulation,
  'socSim' pipes it into 'jtagUartSim' and feeds the resulting
  read-data back into 'siUartRdata'.
  -}
  , soSdramBus :: SdramIpBus
  {- ^ Live bus tap for the SDRAM slave. 16-bit Avalon-MM master
  signals produced by the 32 ↔ 16 width adapter in
  "Riski5.Sdram". On hardware, routed through the Verilog
  wrapper to the Altera SDRAM Controller IP; in simulation,
  'socSim' pipes it into 'sdramIpSim' and feeds the resulting
  reply back into 'siSdramReply'.
  -}
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- |
Simpler inputs for the sim wrapper 'socSim' — identical to 'SocIn'
minus the UART read-data field (which 'socSim' fills in itself from
the sim UART model).
-}
data SocInSim = SocInSim
  { sisSwitches :: BitVector 18
  , sisKeys :: BitVector 4
  , sisSramDqIn :: BitVector 16
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- |
Output bundle from 'socSim': the full 'SocOut' plus the TX byte that
'jtagUartSim' observed this cycle, for tests to assert against.
-}
data SocOutSim = SocOutSim
  { sosOut :: SocOut
  , sosUartTx :: Maybe (BitVector 8)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- |
SoC top. Parameterised on the program vector (size @p@) and a
blank data RAM of size @d@. For phase-1 tests both default to 128
words (512 bytes); real hardware picks larger sizes in the SoC
instantiation inside @app\/Top.hs@.
-}
soc ::
  forall dom p d.
  ( HiddenClockResetEnable dom
  , KnownNat p
  , 1 <= p
  , KnownNat d
  , 1 <= d
  ) =>
  -- | initial imem contents (RV32I machine-code words)
  Vec p (BitVector 32) ->
  -- | initial dmem contents — unused since CM-3 replaced the 64-word
  -- writable Vec-based dmem with the imem bus-port (a second blockRam
  -- mirroring 'progInit'). Kept in the signature so existing test
  -- callers don't break; drop the parameter in a later phase once
  -- the test harnesses are updated in the same commit.
  Vec d (BitVector 32) ->
  -- | board-level inputs (switches, keys)
  Signal dom SocIn ->
  Signal dom SocOut
soc progInit _dataInit inS = outS
 where
  -- ----- Core instance -----------------------------------------
  -- The stall signal comes from the bus mux: any slave that needs
  -- multi-cycle service can deassert ready and the core freezes
  -- until the data settles.
  -- The core now exposes two PC signals: 'pcFetchS' drives the
  -- imem, 'pcExecS' is the PC of the instruction currently in the
  -- execute stage. In the phase-1 pipelineless core they're
  -- identical; phase-2 pipelining will make them differ by one
  -- cycle (fetch leads execute).
  (pcFetchS, _pcExecS, dAddrS, dWdataS, dBeS, dRenS, _wbS, _rvfiS) =
    coreWith tiny32M imemDataS imemReadyS dmemRdataS stallS

  -- Fetch-side ready signal. BRAM fetches are always 1-cycle
  -- sync-read, so 'imemReadyS' is 'pure True' — the core's
  -- imem-capture logic treats that as the "BRAM-always-ready"
  -- contract. Multi-cycle fetch paths (SRAM / SDRAM code) will
  -- re-route this through an arbiter + transaction-ready pulse
  -- when they land. For now, no SRAM-fetch support.
  imemReadyS :: Signal dom Bool
  imemReadyS = CP.pure True

  -- ----- Instruction memory (M4K-backed sync read) ------------
  -- Two read ports over the same @progInit@:
  --
  --   * 'imemDataS' — fetch port, addressed by 'pcFetchS'.
  --     Read-only. The 1-cycle sync-read latency matches the
  --     pipelined core's F → D hand-off (see 'Riski5.Core').
  --   * 'bramRdataS' — bus port, addressed by 'dAddrS'. Served
  --     to the core via the 'SlaveBram' case of the bus read
  --     mux. The 1-cycle sync-read latency costs one stall cycle
  --     per load (see 'bramReadyS' below); in return, CoreMark
  --     and other firmware can resolve @.rodata@ loads at
  --     @0x0000_0000+@ against the imem contents (CM-3).
  --
  -- Both blockRam calls share 'progInit', so Quartus maps them to
  -- the same M4K tile in true-dual-port mode (one initial-contents
  -- image, two independent read ports) when the fitter spots the
  -- identical init. Two 32 × 4096-word instances would otherwise
  -- cost 64 M4K; dual-port mapping brings it down to 32.
  imemDataS :: Signal dom (BitVector 32)
  imemDataS =
    blockRam progInit (addrToImemIdx <$> pcFetchS) (CP.pure Nothing)

  bramRdataS :: Signal dom (BitVector 32)
  bramRdataS =
    blockRam progInit (addrToImemIdx <$> dAddrS) (CP.pure Nothing)

  -- Byte-address → word-index into the @p@-sized imem. The low two
  -- bits are ignored (word-aligned reads only — SB/SH/LB/LH paths
  -- in the core mask/shift before getting here). 'mod' gives a
  -- defined wrap for out-of-range addresses; the bus decoder's
  -- 'slaveOf' already filters, so wrap happens only on deliberate
  -- modular access.
  addrToImemIdx :: BitVector 32 -> Index p
  addrToImemIdx b =
    let w :: Unsigned 32
        w = unpack (b `shiftR` 2)
        nMax :: Unsigned 32
        nMax = fromInteger (natVal (Proxy :: Proxy p))
     in fromIntegral (w `mod` nMax)

  bramSelS = (\a -> slaveOf a == SlaveBram) <$> dAddrS

  -- 1-cycle stall per SlaveBram read: the sync-read blockRam
  -- returns data one cycle after the address is latched, so the
  -- core needs to hold the M-stage request in place for exactly
  -- one extra cycle before capturing. 'bramWaitingS' is True on
  -- the cycle when data is ready (i.e., we've already stalled
  -- once for the current request); 'bramReadyS' lets the bus
  -- stall mux unstall the core.
  --
  -- Writes to SlaveBram silently drop — the bus port is read-only
  -- so firmware treating the @0x0000_0000+@ range as a scratch
  -- region won't see its stores persist. CoreMark's .text +
  -- .rodata live here and never write; other firmware uses SRAM
  -- (0x2000_0000) or SDRAM (0x8000_0000) for writable data, so
  -- dropping writes here is a non-regression.
  bramReadReqS :: Signal dom Bool
  bramReadReqS =
    (\sel re -> if sel then re else False) <$> bramSelS <*> dRenS

  bramWaitingS :: Signal dom Bool
  bramWaitingS =
    register False
      ( (\waiting req -> if waiting then False else req)
          <$> bramWaitingS
          <*> bramReadReqS
      )

  bramReadyS :: Signal dom Bool
  bramReadyS =
    (\waiting req -> if waiting then True else CP.not req)
      <$> bramWaitingS
      <*> bramReadReqS

  -- ----- JTAG UART (bus externalised) --------------------------
  -- The UART slave lives outside the SoC boundary: we expose the
  -- selected bus signals via 'soUartBus' and receive the read-data
  -- back on 'siUartRdata'. For sim, 'socSim' wires that loop up to
  -- 'jtagUartSim'; for hardware, 'app/Top.hs' wires it to the
  -- Altera @altera_avalon_jtag_uart@ IP instantiated in
  -- @pkgs/riski5-core@'s Verilog wrapper.
  jtagSelS = (\a -> slaveOf a == SlaveJtagUart) <$> dAddrS
  uartRdataS = siUartRdata <$> inS
  uartBusS =
    ( \sel a wd be re ->
        AvalonMmBus
          { ambSel = sel
          , ambAddr = a
          , ambWdata = wd
          , ambBe = be
          , ambRe = re
          }
    )
      <$> jtagSelS
      <*> dAddrS
      <*> dWdataS
      <*> dBeS
      <*> dRenS

  -- ----- LCD ---------------------------------------------------
  -- The LCD controller runs its own HD44780 wake + init sequence
  -- from reset, handles per-command timing, and raises an IRQ on
  -- each busy-falling edge. Firmware can polling on STATUS[0] as
  -- before, or enable the IRQ via CTRL[0] and sleep until woken.
  lcdSelS = (\a -> slaveOf a == SlaveLcd) <$> dAddrS
  (lcdRdataS, lcdPinsS, lcdIrqS) =
    lcd lcdSelS dAddrS dWdataS dBeS dRenS

  -- ----- GPIO --------------------------------------------------
  gpioSelS = (\a -> slaveOf a == SlaveGpio) <$> dAddrS
  gpInS = (\SocIn {..} -> GpioIn {gpiSwitches = siSwitches, gpiKeys = siKeys}) <$> inS
  (gpioRdataS, gpOutS) =
    gpio gpioSelS dAddrS dWdataS dBeS dRenS gpInS

  -- ----- SRAM (off-chip 512 KB IS61LV25616-class) --------------
  -- Pure half-word controller — see 'Riski5.Sram' for the
  -- pipelineless 16-bit-only contract (T31a tracks 32-bit access).
  -- 'sramReadyS' is False on the first cycle of a freshly-issued
  -- read; the core stalls via 'stallS' until it goes True.
  sramSelS = (\a -> slaveOf a == SlaveSram) <$> dAddrS
  sramDqInS = siSramDqIn <$> inS
  (sramRdataS, sramPinsS, sramReadyS) =
    sram sramSelS dAddrS dWdataS dBeS dRenS sramDqInS

  -- ----- SDRAM (off-chip 8 MB IS42S16400-class via Altera IP) --
  -- 'Riski5.Sdram.sdram' is the 32 ↔ 16 adapter FSM; the actual
  -- SDRAM controller is the Altera IP instantiated in the Verilog
  -- wrapper outside the Clash boundary. Like SRAM, 'sdramReadyS'
  -- is False while a transaction is in flight; the core stalls
  -- via 'stallS' until it goes True.
  sdramSelS = (\a -> slaveOf a == SlaveSdram) <$> dAddrS
  sdramReplyS = siSdramReply <$> inS
  (sdramRdataS, sdramBusS, sdramReadyS) =
    sdram sdramSelS dAddrS dWdataS dBeS dRenS sdramReplyS

  -- Bus-level stall: any selected slave can deassert ready.
  --   * SRAM + SDRAM stall on read-latency.
  --   * UART stalls for the 1-cycle-registered @av_waitrequest@
  --     the Altera @altera_avalon_jtag_uart@ IP asserts on the
  --     first cycle of every Avalon-MM transaction.
  --   * BRAM (imem-bus-port) stalls for exactly one cycle per
  --     read so the sync-read blockRam output lines up with the
  --     M-stage capture (CM-3).
  --   * GPIO / LCD remain single-cycle.
  uartReadyS = siUartReady <$> inS
  stallS =
    ( \s sramRdy sdramRdy uartRdy bramRdy ->
        case s of
          SlaveSram -> not sramRdy
          SlaveSdram -> not sdramRdy
          SlaveJtagUart -> not uartRdy
          SlaveBram -> not bramRdy
          _ -> False
    )
      <$> (slaveOf <$> dAddrS)
      <*> sramReadyS
      <*> sdramReadyS
      <*> uartReadyS
      <*> bramReadyS

  -- ----- Bus read mux ------------------------------------------
  dmemRdataS :: Signal dom (BitVector 32)
  dmemRdataS =
    ( \s bR uR lR gR sR dR ->
        case s of
          SlaveBram -> bR
          SlaveJtagUart -> uR
          SlaveLcd -> lR
          SlaveGpio -> gR
          SlaveSram -> sR
          SlaveSdram -> dR
          _ -> 0
    )
      <$> (slaveOf <$> dAddrS)
      <*> bramRdataS
      <*> uartRdataS
      <*> lcdRdataS
      <*> gpioRdataS
      <*> sramRdataS
      <*> sdramRdataS

  -- ----- Bundle outputs ----------------------------------------
  outS =
    ( \gpo lcdPins lcdIrq sramPins uartBus sdramBus ->
        SocOut
          { soLedR = gpoLedR gpo
          , soLedG = gpoLedG gpo
          , soLcdPins = lcdPins
          , soLcdIrq = lcdIrq
          , soSramPins = sramPins
          , soUartBus = uartBus
          , soSdramBus = sdramBus
          }
    )
      <$> gpOutS
      <*> lcdPinsS
      <*> lcdIrqS
      <*> sramPinsS
      <*> uartBusS
      <*> sdramBusS

{- |
Simulation wrapper that plugs 'jtagUartSim' back in at the UART bus
boundary. Test harnesses use this rather than 'soc' so they don't
have to materialise a UART model themselves, and so they can observe
TX bytes through 'sosUartTx'.
-}
socSim ::
  forall dom p d.
  ( HiddenClockResetEnable dom
  , KnownNat p
  , 1 <= p
  , KnownNat d
  , 1 <= d
  ) =>
  Vec p (BitVector 32) ->
  Vec d (BitVector 32) ->
  Signal dom SocInSim ->
  Signal dom SocOutSim
socSim progInit dataInit inSimS = outSimS
 where
  fullInS =
    ( \SocInSim {..} ur sdr ->
        SocIn
          { siSwitches = sisSwitches
          , siKeys = sisKeys
          , siSramDqIn = sisSramDqIn
          , siUartRdata = ur
          , siUartReady = True
          , siSdramReply = sdr
          }
    )
      <$> inSimS
      <*> uartRdataS
      <*> sdramReplyS
  outS = soc progInit dataInit fullInS

  -- JTAG UART sim-model tap.
  uartBusS = soUartBus <$> outS
  (uartRdataS, uartTxS) =
    jtagUartSim
      (ambSel <$> uartBusS)
      (ambAddr <$> uartBusS)
      (ambWdata <$> uartBusS)
      (ambBe <$> uartBusS)
      (ambRe <$> uartBusS)

  -- SDRAM sim-model tap. 16 Ki half-words = 32 KB of addressable
  -- sim memory; tests that only touch the lower portion of the
  -- 8 MB SDRAM address space are fine, and 'sdramIpSim' wraps
  -- modulo the vector length anyway.
  sdramBusS = soSdramBus <$> outS
  sdramReplyS = sdramIpSim simMem sdramBusS
  simMem :: Vec 16384 (BitVector 16)
  simMem = CP.repeat 0

  outSimS = (\o t -> SocOutSim {sosOut = o, sosUartTx = t}) <$> outS <*> uartTxS

{- |
Sim-wrapper input for 'socSimFull': like 'SocInSim' but without
@sisSramDqIn@, because the full-sim wrapper drives that signal
itself via 'sramChipSim' based on the SoC's own SRAM-pin output.
-}
data SocInFull = SocInFull
  { sifSwitches :: BitVector 18
  , sifKeys :: BitVector 4
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- |
Fullest sim wrapper currently available: Altera-IP-faithful UART
('jtagUartAlteraSim') __and__ a closed-loop SRAM chip-model
('sramChipSim') wired together with 'soc'. Lets tests exercise
multi-cycle SRAM stalls through the full pipeline, back-to-back
with BRAM loads and UART writes — the combination CoreMark's
startup code hits in its .data-init loop plus early @ee_printf@.

The SRAM backing is a @Vec n (BitVector 16)@ (half-words, matching
the real IS61LV25616 chip's DQ width). Size 'n' is set by the test
harness; tests that only touch the low portion of the SRAM address
space are fine with modest 'n' — 'sramChipSim' wraps the address
modulo the vector length.
-}
socSimFull ::
  forall dom p d n.
  ( HiddenClockResetEnable dom
  , KnownNat p
  , 1 <= p
  , KnownNat d
  , 1 <= d
  , KnownNat n
  , 1 <= n
  ) =>
  Vec p (BitVector 32) ->
  Vec d (BitVector 32) ->
  Vec n (BitVector 16) ->
  Signal dom SocInFull ->
  Signal dom SocOutSim
socSimFull progInit dataInit sramInit inFullS = outSimS
 where
  fullInS =
    ( \SocInFull {..} dq ur urRdy sdr ->
        SocIn
          { siSwitches = sifSwitches
          , siKeys = sifKeys
          , siSramDqIn = dq
          , siUartRdata = ur
          , siUartReady = urRdy
          , siSdramReply = sdr
          }
    )
      <$> inFullS
      <*> sramDqInS
      <*> uartRdataS
      <*> uartReadyS
      <*> sdramReplyS
  outS = soc progInit dataInit fullInS

  -- SRAM chip model — watches the pins the SoC's internal sram
  -- controller drives, feeds DQ-in back combinationally.
  sramPinsS = soSramPins <$> outS
  (sramDqInS, _sramStoreS) = sramChipSim sramInit sramPinsS

  uartBusS = soUartBus <$> outS
  (uartRdataS, uartTxS, uartReadyS) =
    jtagUartAlteraSim
      (ambSel <$> uartBusS)
      (ambAddr <$> uartBusS)
      (ambWdata <$> uartBusS)
      (ambBe <$> uartBusS)
      (ambRe <$> uartBusS)

  sdramBusS = soSdramBus <$> outS
  sdramReplyS = sdramIpSim simMem sdramBusS
  simMem :: Vec 16384 (BitVector 16)
  simMem = CP.repeat 0

  outSimS = (\o t -> SocOutSim {sosOut = o, sosUartTx = t}) <$> outS <*> uartTxS

{- |
Sim wrapper that uses 'jtagUartAlteraSim' (the finite-FIFO +
drain-gap-requirement model) instead of the simple 'jtagUartSim'.
Same @SocInSim@ / @SocOutSim@ interface; the difference is that
writes to UART DATA now stall the core via @siUartReady@ when the
model's 64-byte FIFO is full, and back-to-back writes with no gap
deadlock the model (matching the silicon bug that CM-4 uncovered
and the CM-2 port's WSPACE poll fixed).

Use this wrapper in regression tests that want to catch firmware
regressions around the back-to-back-write / drain-gap contract
(see @test/UartBackpressureSpec.hs@). Default sim tests that
don't care about UART back-pressure keep using 'socSim'.
-}
socSimAlteraUart ::
  forall dom p d.
  ( HiddenClockResetEnable dom
  , KnownNat p
  , 1 <= p
  , KnownNat d
  , 1 <= d
  ) =>
  Vec p (BitVector 32) ->
  Vec d (BitVector 32) ->
  Signal dom SocInSim ->
  Signal dom SocOutSim
socSimAlteraUart progInit dataInit inSimS = outSimS
 where
  fullInS =
    ( \SocInSim {..} ur urRdy sdr ->
        SocIn
          { siSwitches = sisSwitches
          , siKeys = sisKeys
          , siSramDqIn = sisSramDqIn
          , siUartRdata = ur
          , siUartReady = urRdy
          , siSdramReply = sdr
          }
    )
      <$> inSimS
      <*> uartRdataS
      <*> uartReadyS
      <*> sdramReplyS
  outS = soc progInit dataInit fullInS

  uartBusS = soUartBus <$> outS
  (uartRdataS, uartTxS, uartReadyS) =
    jtagUartAlteraSim
      (ambSel <$> uartBusS)
      (ambAddr <$> uartBusS)
      (ambWdata <$> uartBusS)
      (ambBe <$> uartBusS)
      (ambRe <$> uartBusS)

  sdramBusS = soSdramBus <$> outS
  sdramReplyS = sdramIpSim simMem sdramBusS
  simMem :: Vec 16384 (BitVector 16)
  simMem = CP.repeat 0

  outSimS = (\o t -> SocOutSim {sosOut = o, sosUartTx = t}) <$> outS <*> uartTxS
