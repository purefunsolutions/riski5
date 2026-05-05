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
  socWithExternalCore,
  socSim,
  socSimAlteraUart,
  socSimFull,
  socSimFullWith,
  SocIn (..),
  SocInSim (..),
  defaultSocInSim,
  SocInFull (..),
  SocOut (..),
  SocOutSim (..),
) where

import Clash.Prelude hiding (And, Or, Xor, not, (||))
import Clash.Prelude qualified as CP
import Data.Proxy (Proxy (..))
import Riski5.AvalonMm (AvalonMmBus (..))
import Riski5.Core.Assembly (coreWith)
import Riski5.CoreCdcBridge (CoreBusReply (..), CoreBusReq (..))
import Riski5.Core.Presets (tiny32M)
import Riski5.Gpio (GpioIn (..), GpioOut (..), gpio)
import Riski5.JtagUart (jtagUartAlteraSim, jtagUartSim)
import Riski5.JtagUartAdapter (jtagUartAdapter)
import Riski5.Clint (clint)
import Riski5.Lcd (LcdPins (..), lcd)
import Riski5.MemMap (SlaveId (..), slaveOf)
import Riski5.Plic (PlicSources, plic)
import Riski5.Sdram (SdramIpBus, SdramIpReply (..), sdram, sdramIpSim, sdramSinglePort)
import Riski5.Sram (SramPins (..), sram, sramChipSim, sramSinglePort)

{- |
Sticky arbiter state for the SDRAM bus mux that selects between
the riski5 core and the JTAG-Avalon-Master IP. The combinational
mux this replaced switched on @siJtagLoadMode@ each cycle, which
let the IP's @master_write@ pulse drag the mux JTAG-side and then
release back to core mid-transaction — corrupting in-flight writes
at the SDRAM IP. The sticky arbiter latches the owner until the
SDRAM controller signals an idle / completion edge
(@sdramRawReadyS@), then re-picks for the next transaction.

JTAG has priority on simultaneous arrival: kernel + DTB uploads
are bursty (continuous @master_write@ stream until the host
finishes), and stalling the core is the intended behaviour during
the boot stub's poll loop anyway.
-}
data JtagMuxOwner = JmxNone | JmxCore | JmxJtag
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- |
Next-state for 'JtagMuxOwner'. Args: current owner, "core wants
SDRAM this cycle" (any port — data or fetch), "JTAG wants SDRAM
this cycle", "SDRAM controller signalling ready/idle this cycle".

Hold the owner whenever @!idle@ — that's the cycle window where a
transaction is in flight and switching the mux would race the
@Riski5.Sdram@ FSM. On the @idle@ pulse re-pick: JTAG-priority,
otherwise core, otherwise none.
-}
nextJtagMuxOwner :: JtagMuxOwner -> Bool -> Bool -> Bool -> JtagMuxOwner
nextJtagMuxOwner JmxNone _ True _ = JmxJtag
nextJtagMuxOwner JmxNone True False _ = JmxCore
nextJtagMuxOwner JmxNone False False _ = JmxNone
nextJtagMuxOwner JmxCore _ _ False = JmxCore
nextJtagMuxOwner JmxCore _ True True = JmxJtag
nextJtagMuxOwner JmxCore True False True = JmxCore
nextJtagMuxOwner JmxCore False False True = JmxNone
nextJtagMuxOwner JmxJtag _ _ False = JmxJtag
nextJtagMuxOwner JmxJtag _ True True = JmxJtag
nextJtagMuxOwner JmxJtag True False True = JmxCore
nextJtagMuxOwner JmxJtag False False True = JmxNone

-- The inner SRAM/SDRAM fetch-vs-data arbiter used to live here as
-- 'nextSramOwner'. Replaced by per-controller two-port internal
-- arbitration in 'Riski5.Sram.sram' / 'Riski5.Sdram.sdram' (tasks
-- #21 + #22) — both now expose fetch + data ports directly and
-- latch the picked request atomically with the FSM transition out
-- of SIdle, so the SoC no longer needs to maintain a registered
-- owner that the inner FSM has to mirror.

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
  , siUartIrq :: Bool
  {- ^ Altera JTAG-UART IP's @av_irq@ output. The real IP asserts
  it whenever @CONTROL.RE && CONTROL.RI@ — read-interrupt enabled
  and the RX FIFO is non-empty. We route this through the SoC into
  PLIC source 1; firmware that has set both @plic.priority[1] >
  threshold@ and @mie.MEIE@ will see a machine-external interrupt
  on the next cycle. Tied to 'pure False' in the sim wrappers
  ('socSim' / 'socSimFullWith') because the simulation models
  don't yet implement an RX-FIFO interrupt path; the live wiring
  comes online when the firmware enables RX on real silicon.
  -}
  , siSdramReply :: SdramIpReply
  {- ^ Slave → master return channel from the Altera SDRAM
  Controller IP (or 'sdramIpSim' in sim). Carries @za_data@,
  @za_valid@, and @~za_waitrequest@; the SoC's stall logic
  feeds @~waitrequest@ back to the core and the 'Riski5.Sdram'
  adapter latches @za_data@ when @za_valid@ pulses.
  -}
  , siCaptureReset :: Bool
  {- ^ Re-arm the freeze-on-trigger snapshot used to debug the
  SDRAM-exec multi-byte residual. Driven on hardware by an
  Altera @altsource_probe@ megafunction's source pin (instance
  ID @CAPR@); software writes 1 via @quartus_stp@'s
  @write_source_data@, the SoC clears the capture state machine
  next cycle, and the snapshot re-arms for the next trigger
  event. In simulation this is hardcoded 'False' (snapshot fires
  once and holds; sim tests don't drive the reset).
  -}
  , siCaptureOffset :: Unsigned 2
  {- ^ Unused — historical artefact from the source-driven mux
  approach to the freeze-on-trigger capture. Multi-bit
  altsource_probe sources don't propagate reliably through
  Quartus 13.0sp1's JTAG hub on this design; the working
  alternative is to expose all 4 captured cycles as a single
  wide probe (see @soDbgFrozenPcAll@ / @soDbgFrozenFlagsAll@).
  Kept in the record for now to avoid a wide refactor.
  -}
  , siJtagLoadMode :: Bool
  {- ^ L-3 JTAG-load: when 'True', the JTAG hub drives the SDRAM
  IP via the @siJtagLoad*@ inputs below; when 'False', the riski5
  core has the SDRAM as usual. Driven on hardware by an
  altsource_probe source instance @JLMD@; tied to 'False' in
  every sim wrapper so existing tests are unaffected. The mux
  point is upstream of 'Riski5.Sdram.sdram' so the 32 ↔ 16
  width conversion still applies in either mode.
  -}
  , siJtagLoadAddr :: BitVector 32
  -- ^ L-3 JTAG-load: byte address for the next SDRAM transaction.
  --   Driven by altsource_probe source @JLAD@. Ignored unless
  --   @siJtagLoadMode = True@.
  , siJtagLoadWdata :: BitVector 32
  -- ^ L-3 JTAG-load: 32-bit write data. Source @JLDW@.
  , siJtagLoadWe :: Bool
  -- ^ L-3 JTAG-load: pulse-high to commit a write at
  --   (siJtagLoadAddr, siJtagLoadWdata). Source @JLWE@. The Tcl
  --   script writes 1, then 0, to issue one transaction.
  , siJtagLoadRd :: Bool
  -- ^ L-3 JTAG-load: pulse-high to issue a read from
  --   siJtagLoadAddr. Source @JLRD@. The result lands on
  --   'soJtagLoadRdata' once 'soJtagLoadBusy' deasserts.
  , siJtagLoadBe :: BitVector 4
  -- ^ L-3 JTAG-load: active-high byte-enable for the JTAG-Master
  --   write. Wired through to 'jtagMuxedSdram' so 'master_write_8'
  --   and 'master_write_16' from system-console actually mask the
  --   chip-side byte writes correctly. With the JTAG-Master IP
  --   issuing all four bytes for a 'master_write_32', this comes
  --   in as @0xF@; for sub-word writes the IP sets only the
  --   active byte lanes. The Tcl-script L-3 path that drives this
  --   port directly via altsource_probe (no IP in the loop) just
  --   ties this to @0xF@ for its kernel-image upload path, which
  --   is 32-bit-aligned by construction.
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
  , soDbgPcFetch :: BitVector 32
  {- ^ The core's @pcFetchS@ — exposed unconditionally for
  on-chip debug. On hardware @app\/Top.hs@ exposes this as the
  @DEBUG_PCFETCH@ output, which the @riski5_top.v@ wrapper
  feeds into an Altera @altsource_probe@ megafunction so
  @quartus_stp@'s @read_probe_data@ can sample the program
  counter at any time over JTAG. Used to root-cause silicon
  hangs (the @sramexec@ iter-2 issue specifically) without
  needing SignalTap II's full waveform capture flow.
  -}
  , soDbgDmemRdata :: BitVector 32
  {- ^ The bus-side @dmemRdataS@ — what the SoC body returns
  to the core's data port for the most recent LW. Exposed for
  the Linux mid-init hang debug (task #52): the kernel's
  @irqentry_exit_to_user_mode@ loop spins on a @lw s1, 0(tp)@
  whose result has stuck flag bits, but we don't know WHICH bits
  without reading the LW's actual return value. Sampling this
  signal whenever DEBUG_PCFETCH == 0x801ec464 reveals the
  thread_info.flags value the kernel is seeing.
  -}
  , soDbgFlags :: BitVector 8
  {- ^ Packed diagnostic flags for the second @altsource_probe@.
  Bit layout:

  @
    [0] stallS
    [1] dataStallS
    [2] fetchStallS    ( = !imemReadyS )
    [3] uartAcceptedS
    [4] sramDataReadyS ( = sramReadyS gated by OwnData )
    [5] uartReadyS
    [6] bramReadyS
    [7] reserved (0)
  @
  -}
  , soDbgFrozenPcAll :: BitVector 128
  {- ^ Concatenation of all 4 freeze-on-trigger snapshots' PC
  values: @{pc_K, pc_{K+1}, pc_{K+2}, pc_{K+3}}@ where K is the
  trigger cycle. Each PC is 32 bits; bits [127:96] hold @pc_K@,
  bits [95:64] hold @pc_{K+1}@, etc. Held until
  @siCaptureReset@ pulses 'True'. Exposed via the @FRZP@
  @altsource_probe@.

  Trigger condition: @stallS && jtagSelS && (dBeS != 0)
  && uartReadyS && !uartAcceptedS@ — the cycle where the
  master-side @uartAcceptedS@ latch __should__ engage. By
  capturing 4 consecutive cycles starting at K, we can see
  the latch's transition pattern: @uartAcceptedS@ at K should
  be 0 and at K+1 should be 1, with the master gated from K+1
  onwards.
  -}
  , soDbgFrozenFlagsAll :: BitVector 32
  {- ^ Concatenation of all 4 freeze-on-trigger snapshots'
  flag bytes: @{flags_K, flags_{K+1}, flags_{K+2}, flags_{K+3}}@.
  Each flag byte uses the same bit layout as 'soDbgFlags', with
  bit [7] of each byte repurposed as @capturedS@ for that
  snapshot's slot. Software polls bit [7] of any byte (they're
  all written together) to know when the snapshot is valid.

  @
    bits [31:24] = flags_K     (trigger cycle)
    bits [23:16] = flags_{K+1}
    bits [15: 8] = flags_{K+2}
    bits [ 7: 0] = flags_{K+3}
  @
  -}
  , soMtip :: Bool
  {- ^ Machine-timer interrupt pending — combinational
  @mtime >= mtimecmp@ from the on-chip CLINT
  ('Riski5.Clint'). The CSR file's @mip.MTIP@ bit follows
  this signal; once @mie.MTIE && mstatus.MIE@ are set, the
  core takes a machine-timer interrupt and traps into
  @mtvec.base@. Exposed on 'SocOut' so simulation harnesses
  and on-chip debug probes can observe the strobe directly.
  -}
  , soJtagLoadRdata :: BitVector 32
  -- ^ L-3 JTAG-load: last read result returned by the SDRAM IP.
  --   Exposed via altsource_probe @JLRR@.
  , soJtagLoadBusy :: Bool
  -- ^ L-3 JTAG-load: 'True' while the SDRAM IP holds
  --   @av_waitrequest@ for the JTAG-load transaction. The Tcl
  --   script polls this between transactions to avoid issuing a
  --   new write before the previous one completes. Exposed via
  --   probe @JLBS@.
  , soDbgSdramRdata :: BitVector 32
  -- ^ Debug tap on the SDRAM data-port rdata signal, the value
  --   the core's data port receives on a load completion. Used by
  --   integration tests to verify the SoC + sdram interaction
  --   delivers the right value to the core. NOT a board-output
  --   pin — sim only.
  , soDbgSdramDataReady :: Bool
  -- ^ Debug tap on sdramDataReadyS — the gated dataReady the
  --   core sees from the SDRAM data port.
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
  , sisUartIrq :: Bool
  -- ^ Per-cycle override for the JTAG-UART IP's @av_irq@ output —
  -- forwarded to 'SocIn.siUartIrq'. Tests that exercise the
  -- machine-external-interrupt trap path (PLIC source 1 →
  -- @mip.MEIP@ → handler) drive this 'True' on selected cycles.
  -- Existing tests can leave it 'False' (the default for the
  -- record-with-defaults pattern below).
  , sisJtagLoadMode :: Bool
  -- ^ Per-cycle override for L-3 JTAG-load mode bit. Forwarded
  -- to 'SocIn.siJtagLoadMode'. The L-3 sticky arbiter only
  -- routes JTAG signals to the SDRAM bus when this is asserted
  -- and the JTAG path actually wins arbitration; tests use it
  -- alongside the four siJtagLoad* signals below to drive the
  -- 'jtagMuxedSdram' mux directly. Defaults 'False'.
  , sisJtagLoadAddr :: BitVector 32
  -- ^ Forwarded to 'SocIn.siJtagLoadAddr'. Defaults 0.
  , sisJtagLoadWdata :: BitVector 32
  -- ^ Forwarded to 'SocIn.siJtagLoadWdata'. Defaults 0.
  , sisJtagLoadWe :: Bool
  -- ^ Forwarded to 'SocIn.siJtagLoadWe'. Defaults 'False'.
  , sisJtagLoadRd :: Bool
  -- ^ Forwarded to 'SocIn.siJtagLoadRd'. Defaults 'False'.
  , sisJtagLoadBe :: BitVector 4
  -- ^ Forwarded to 'SocIn.siJtagLoadBe'. Defaults 0; tests that
  -- exercise sub-word JTAG-Master writes set this to 0b0011 / 0b1100
  -- / 0b0001 / etc.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

-- | Default 'SocInSim' value with all switches cleared, all keys
-- de-asserted (active-low — 0xF means "no key pressed"), no SRAM
-- DQ activity, and no UART IRQ. Tests that only need to override
-- one field can use record-update syntax against this default.
defaultSocInSim :: SocInSim
defaultSocInSim =
  SocInSim
    { sisSwitches = 0
    , sisKeys = 0xF
    , sisSramDqIn = 0
    , sisUartIrq = False
    , sisJtagLoadMode = False
    , sisJtagLoadAddr = 0
    , sisJtagLoadWdata = 0
    , sisJtagLoadWe = False
    , sisJtagLoadRd = False
    , sisJtagLoadBe = 0
    }

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
{- |
Variant of 'soc' that takes the core's bus signals as an external
input ('CoreBusReq') and returns the bus reply alongside SocOut.
Lets the caller (typically @app/Top.hs@) instantiate the core in
a different clock domain and bridge across via
'Riski5.CoreCdcBridge.coreCdcBridge' for the multi-PLL Phase D-2
split.

Behaviour is otherwise identical to 'soc'. The plain 'soc' below
is now a thin wrapper that instantiates 'coreWith' locally and
calls into this function.
-}
socWithExternalCore ::
  forall dom p d.
  ( HiddenClockResetEnable dom
  , KnownNat p
  , 1 <= p
  , KnownNat d
  , 1 <= d
  ) =>
  Bool -> -- ^ Enable fetch-side SRAM routing (see 'soc').
  Bool -> -- ^ Enable fetch-side SDRAM routing (see 'soc').
  Vec p (BitVector 32) -> -- ^ initial imem contents
  Vec d (BitVector 32) -> -- ^ initial dmem contents (unused)
  Signal dom SocIn ->
  Signal dom CoreBusReq ->
  -- | (board-level outputs, reply going back to the core)
  (Signal dom SocOut, Signal dom CoreBusReply)
socWithExternalCore enableSramFetch enableSdramFetch progInit _dataInit inS coreReqS =
  (outS, coreReplyS)
 where
  -- ----- Core bus interface (Phase D-2: from external core) ----
  -- Instead of instantiating the core locally, destructure the
  -- 'CoreBusReq' input. The reply goes back via 'coreReplyS' at
  -- the bottom of this where-clause. Caller uses
  -- 'Riski5.CoreCdcBridge.coreCdcBridge' to cross domains; in the
  -- single-domain wrapper 'soc' below the same signals stay in
  -- 'dom' with no bridge.
  --
  -- The original phase-1 phase comment about pcFetchS vs pcExecS:
  -- the core exposes two PC signals — 'pcFetchS' drives the
  -- imem, 'pcExecS' is the PC of the instruction currently in
  -- the execute stage. The pipelineless phase-1 core makes them
  -- identical; the bus only consumes pcFetchS, so pcExecS isn't
  -- carried over the bridge.
  pcFetchS = cbrPcFetch <$> coreReqS
  dAddrS = cbrDAddr <$> coreReqS
  dWdataS = cbrDWdata <$> coreReqS
  dBeS = cbrDBe <$> coreReqS
  dRenS = cbrDRen <$> coreReqS

  -- ----- Instruction memory (M4K-backed sync read) ------------
  -- Two read ports over the same @progInit@:
  --
  --   * 'imemDataBramS' — fetch port, addressed by 'pcFetchS'.
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
  imemDataBramS :: Signal dom (BitVector 32)
  imemDataBramS =
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
  --
  -- __Master-side post-acceptance gating.__ The Altera JTAG-UART IP
  -- commits a byte every clock edge where its @av_waitrequest@ is
  -- False with @av_write@ asserted, so once the riski5 core's SW
  -- has retired the strobe but the X-stage stalls for an unrelated
  -- reason (typically a multi-cycle imem fetch from off-chip SRAM
  -- during the @sramexec@ bitstream's loop), the IP would otherwise
  -- see one fresh transaction per held cycle — the @BSSS×N@
  -- silicon symptom. 'uartAcceptedS' is a tiny one-bit latch local
  -- to the UART tap that flips True the cycle after the IP accepts
  -- (= @uartReadyS=True@ with the master writing) and gates the
  -- write strobe to 0 for subsequent cycles in the same X tenure,
  -- with reset when the master itself deasserts. Localising the
  -- gating to just the UART bus tap (rather than the global
  -- dBeS / dRenS path used by every slave) keeps the rest of the
  -- bus structurally identical to the pre-fix baseline so Quartus
  -- reproduces its placement.
  jtagSelS = (\a -> slaveOf a == SlaveJtagUart) <$> dAddrS

  -- 'Riski5.JtagUartAdapter.jtagUartAdapter' wraps the Altera
  -- @altera_avalon_jtag_uart@ IP and translates its quirky
  -- "commit-on-waitrequest=1, drop-silently-on-FIFO-full"
  -- behaviour into standard Avalon-MM backpressure semantics.
  -- The adapter:
  --   * tracks the IP's TX FIFO occupancy locally (initialised
  --     to 64 bytes — the IP's default depth);
  --   * holds the master with @waitrequest=1@ when the FIFO is
  --     full, instead of letting the IP silently drop the byte;
  --   * issues its own CTRL reads to the IP while held to track
  --     drain, releasing the master as soon as a slot opens;
  --   * passes CTRL accesses through transparently and snoops
  --     read responses to refresh its occupancy estimate.
  --
  -- Master-side firmware no longer needs to poll WSPACE — it
  -- can issue back-to-back @sw@s to the UART and the SoC takes
  -- care of backpressure. The existing 'uartAcceptedS' gating
  -- (below) sits in front of the adapter and continues to
  -- handle the IP's quirky @waitrequest@-toggle protocol within
  -- a single transaction (1 commit per master assertion);
  -- 'jtagUartAdapter' adds the FIFO-full backpressure on top.
  --
  -- See @Riski5.JtagUartAdapter@ for the full design rationale.
  ( uartRdataS
    , uartReadyAdapterS
    , uartIpBusS
    ) =
      jtagUartAdapter uartBusS (siUartRdata <$> inS) (siUartReady <$> inS)

  uartWrMasterS :: Signal dom Bool
  uartWrMasterS =
    (\sel be -> case (sel, be /= 0) of (True, True) -> True; _ -> False)
      <$> jtagSelS
      <*> dBeS

  uartAcceptedS :: Signal dom Bool
  uartAcceptedS = register False uartAcceptedNextS

  uartAcceptedNextS :: Signal dom Bool
  uartAcceptedNextS =
    ( \stall accepted wrMaster ipReady ->
        case (stall, accepted, wrMaster, ipReady) of
          (False, _, _, _) -> False
          (True, True, _, _) -> True
          (True, False, True, True) -> True
          _ -> False
    )
      <$> stallS
      <*> uartAcceptedS
      <*> uartWrMasterS
      <*> uartReadyS

  -- Gate __both__ ambSel and ambBe once accepted. Probing the
  -- @sramexec@ silicon at the iter-2 halt with BE-only gating
  -- showed @uartReadyS=False@ stuck (IP's @av_waitrequest@
  -- pinned high) — apparently the Altera JTAG-UART IP treats
  -- sustained @av_chipselect=1@ with no read/write strobe as
  -- "transaction still pending" and never deasserts waitrequest.
  -- Forcing chipselect=0 along with be=0 once accepted leaves
  -- the IP in a clean idle state.
  uartBusS =
    ( \sel a wd be re acc ->
        AvalonMmBus
          { ambSel = if acc then False else sel
          , ambAddr = a
          , ambWdata = wd
          , ambBe = if acc then 0 else be
          , ambRe = re
          }
    )
      <$> jtagSelS
      <*> dAddrS
      <*> dWdataS
      <*> dBeS
      <*> dRenS
      <*> uartAcceptedS

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

  -- ----- CLINT (timer + software-interrupt source) ------------
  -- Free-running 64-bit @mtime@ + 64-bit @mtimecmp@; raises
  -- 'mtipS' when @mtime >= mtimecmp@. The CSR file's @mip.MTIP@
  -- bit follows this signal so a machine-timer interrupt fires
  -- once both @mie.MTIE@ and @mstatus.MIE@ are set. Memory-
  -- mapped at 'clintBase' (32-byte register window inside the
  -- 64-byte slot the memory map reserves).
  clintSelS = (\a -> slaveOf a == SlaveClint) <$> dAddrS
  (clintRdataS, mtipS) =
    clint clintSelS dAddrS dWdataS dBeS dRenS

  -- ----- PLIC (SiFive-1.0.0-compatible interrupt controller) ---
  -- Memory-mapped at 'plicBase' = 0x4000_0000. Owns the full top-4-bit
  -- chunk (256 MB) so the SiFive sparse register layout — priority
  -- at 0x0004, pending at 0x1000, enable at 0x2000, threshold/claim
  -- at 0x0020_0000 — fits without wrapping. Drives @meipS@ →
  -- core's @mip.MEIP@ bit.
  --
  -- The external IRQ source vector is currently pinned to 0 (no
  -- peripheral wired). Once T-LI2 (16550 UART) and the LCD-IRQ work
  -- (P2-H) land, those slaves' @irq@ outputs feed bits 1 and 2 of
  -- this vector and the trap path is fully active. Until then the
  -- block is dead-coded by Quartus on the CoreMark hot loop because
  -- @meipS = 0@ identically.
  plicSelS = (\a -> slaveOf a == SlavePlic) <$> dAddrS
  -- External IRQ source vector. Bit 0 is reserved per SiFive PLIC
  -- spec (firmware never enables source 0). Bit 1 = JTAG-UART RX
  -- (the IP's @av_irq@ pin asserts on @CONTROL.RE && RI@ once
  -- firmware has set RE). Bits 2..7 reserved for future peripheral
  -- IRQs (LCD-ready, GPIO edge, SDRAM-bus error, etc.).
  --
  -- Each peripheral IRQ is registered before fanning into the PLIC's
  -- combinational pending-and-arbitrate cone. The Altera JTAG-UART
  -- IP's @av_irq@ output drives directly off the IP's internal
  -- registers but in the same clock domain — registering at the SoC
  -- boundary still adds one cycle of latency (irrelevant for OS-grade
  -- IRQ semantics) and gives Quartus a clean register stage between
  -- the IP-IRQ output and the riski5 fabric. Without this stage, on
  -- silicon the live @av_irq@ → @plicExtIrqsS@ → @pendingS@ → bus
  -- mux fan-out triggered a Quartus place-and-route shift that broke
  -- BRAM fetches (CoreMark hung at boot) — see commit message of
  -- L-1's hardware fix.
  uartIrqRegS :: Signal dom Bool
  uartIrqRegS = register False (siUartIrq <$> inS)

  plicExtIrqsS :: Signal dom (BitVector PlicSources)
  plicExtIrqsS =
    (\uartIrq -> if uartIrq then 0b10 else 0) <$> uartIrqRegS
  (plicRdataS, meipS) =
    plic plicSelS dAddrS dWdataS dBeS dRenS plicExtIrqsS

  -- ----- SRAM (off-chip 512 KB IS61LV25616-class) --------------
  -- Pure half-word controller — see 'Riski5.Sram' for the
  -- pipelineless 16-bit-only contract (T31a tracks 32-bit access).
  --
  -- __Two structural variants, selected at synthesis time by the
  -- 'enableSramFetch' flag.__ The enabled branch stands up a
  -- stateless data-priority arbiter so @pcFetch@ in SRAM range
  -- can reach the controller; the disabled branch wires the
  -- controller inputs directly to the data-side bus, matching
  -- the pre-arbiter SoC __bit-identically__ at the Verilog level.
  -- This is load-bearing: the arbiter muxes alone, even when the
  -- fetch request is pinned to 'pure False', were enough to shift
  -- Quartus 13.0sp1's placement and regress CoreMark on silicon
  -- — see @docs/perf/sram-exec-probe-2026-04-24.md@. Using a
  -- compile-time 'if' (rather than a signal-level one) guarantees
  -- GHC Core + Clash strip the unused branch before the synth
  -- backend sees it.
  --
  -- The block returns five signals:
  --
  --   * @sramRdataS@      — controller read-data presented to the
  --     data-side bus mux.
  --   * @sramPinsS@       — driven onto the SRAM_* board pins.
  --   * @sramDataReadyS@  — feeds 'dataStallS' for the data side.
  --     Equals the controller's raw @readyS@ in the pass-through
  --     branch; gated by the arbiter's owner in the enabled branch.
  --   * @sramFetchDataS@  — read-data routed to the fetch mux when
  --     the SRAM-fetch path is enabled. Pinned to constant @0@ in
  --     the disabled branch (dead-coded by the fetch mux's
  --     @(False, _)@ arms).
  --   * @sramFetchReadyS@ — fetch-side ready. @False@ in the
  --     disabled branch, gated by owner @==@ 'OwnFetch' in the
  --     enabled branch.
  sramDataReqS = (\a -> slaveOf a == SlaveSram) <$> dAddrS
  sramDqInS = siSramDqIn <$> inS

  ( sramRdataS
    , sramPinsS
    , sramDataReadyS
    , sramFetchDataS
    , sramFetchReadyS
    ) =
      if enableSramFetch
        then
          -- Two-port controller: internal arbitration. Same
          -- architectural fix as 'Riski5.Sdram.sdram' — kills the
          -- old @sramOwnerS@ / @sramAddrArbS@ multiplex hazard
          -- (a registered owner could lag the live request by one
          -- cycle on switches, presenting wrong addr to the chip
          -- mid-FSM). Now both the picked request and the
          -- serving-port enum are latched atomically with the FSM
          -- transition out of SIdle.
          let
            sramFetchInS :: Signal dom Bool
            sramFetchInS = (\fs -> fs == SlaveSram) <$> (slaveOf <$> pcFetchS)
            ( sramFetchRdataS'
              , sramFetchReadyS'
              , sramDataRdataS'
              , sramDataReadyS'
              , sramPinsS'
              ) =
                sram
                  sramFetchInS
                  pcFetchS
                  sramDataReqS
                  dAddrS
                  dWdataS
                  dBeS
                  dRenS
                  sramDqInS
           in
            ( sramDataRdataS'
            , sramPinsS'
            , sramDataReadyS'
            , sramFetchRdataS'
            , sramFetchReadyS'
            )
        else
          -- Pass-through: the SRAM controller is driven by the
          -- data side only. Bit-identical to the pre-arbiter SoC
          -- wiring, so Quartus reproduces the CoreMark-validated
          -- placement.
          let
            (sramRdataS', sramPinsS', sramReadyS') =
              sramSinglePort sramDataReqS dAddrS dWdataS dBeS dRenS sramDqInS
           in
            ( sramRdataS'
            , sramPinsS'
            , sramReadyS' -- data is the only requester
            , CP.pure 0 -- fetch path inert
            , CP.pure False -- fetch never ready
            )

  -- ----- SDRAM (off-chip 8 MB IS42S16400-class via Altera IP) --
  -- 'Riski5.Sdram.sdram' is the 32 ↔ 16 adapter FSM; the actual
  -- SDRAM controller is the Altera IP instantiated in the Verilog
  -- wrapper outside the Clash boundary. Like SRAM, the adapter's
  -- @readyS@ is False while a transaction is in flight; the core
  -- stalls via 'stallS' until it goes True.
  --
  -- __Two structural variants, selected at synthesis time by the
  -- 'enableSdramFetch' flag.__ Mirrors the SRAM block's
  -- arbiter-or-pass-through pattern: when the flag is 'False' the
  -- SDRAM block is bit-identical to the pre-SDRAM-fetch SoC; when
  -- 'True' a stateless data-priority arbiter routes
  -- @pcFetch in SDRAM range@ through the controller. Same
  -- compile-time-@if@ rationale as the SRAM block — the arbiter
  -- muxes change Quartus's placement and regress CoreMark on
  -- silicon if not gated structurally.
  --
  -- __Caveat — stateless arbiter on a multi-cycle FSM.__ The SDRAM
  -- adapter holds state across cycles (SReadLoReq → SReadLoWait →
  -- SReadHiReq → SReadHiWait); its @addrS@ input is sampled per
  -- cycle in @busFor@. If the arbiter switched ownership
  -- mid-transaction (e.g. data raced in while fetch was in
  -- SReadLoWait), the FSM would present mismatched address bits
  -- on the IP-facing leg. The probe firmware
  -- 'firmware\/phase1\/HelloSdramExec.hs' avoids the race by
  -- construction (data accesses go to the UART; SDRAM is
  -- fetch-only inside the SDRAM-resident routine). A registered
  -- "owner-locked" arbiter is the right next step when a future
  -- firmware overlaps data + fetch on SDRAM — track in the
  -- SX-follow-up section of @TODO.md@.
  -- "Data port wants SDRAM" must be gated on an actual read-or-
  -- write request, not just on the address. The data port drives
  -- @dAddrS@ continuously (it's whatever the next-load/store address
  -- calculation produces), and after a JR into SDRAM the address
  -- often still points back into SDRAM even though @dRenS@ /
  -- @dBeS@ are both inactive. Without the gating below the arbiter
  -- in the @enableSdramFetch=True@ path picks @OwnData@ on those
  -- spurious cycles, hijacks the SDRAM IP into a phantom read at
  -- @dAddrS@, and starves fetch — visible on silicon as the kernel
  -- running NOPs after the boot stub's JR (no UART output, no trap
  -- back to BRAM mtvec). @|| be /= 0@ is the canonical "is this
  -- cycle a write" test the rest of @Riski5.Sdram@ uses; @r@ is
  -- the read-enable from the data port.
  sdramSelDataS =
    (\a r b -> slaveOf a == SlaveSdram CP.&& (r CP.|| b /= 0))
      <$> dAddrS
      <*> dRenS
      <*> dBeS
  sdramReplyS = siSdramReply <$> inS

  -- L-3 JTAG-load source signals. The JTAG-Avalon-Master IP's
  -- @master_*@ outputs (or, in the L-3 sdramload variant, the
  -- altsource_probe @JLAD@ / @JLDW@ / @JLWE@ / @JLRD@ sources) land
  -- here unmodified — the sticky arbiter immediately below decides
  -- when these reach the SDRAM controller. The arbiter sits
  -- __upstream__ of the existing fetch / data arbiter so the
  -- 32 ↔ 16 conversion still runs and the SDRAM IP's 16-bit slave
  -- port sees clean transactions on either side of the mux.
  sdramJtagAddrS = siJtagLoadAddr <$> inS
  sdramJtagWdataS = siJtagLoadWdata <$> inS
  sdramJtagWeS = siJtagLoadWe <$> inS
  sdramJtagRdS = siJtagLoadRd <$> inS
  sdramJtagBeS = siJtagLoadBe <$> inS

  -- Sticky-arbiter source signals.
  --
  -- @sdramFetchAnyS@: True when the core's IF-stage is targeting the
  -- SDRAM range (only meaningful with @enableSdramFetch=True@).
  -- Hoisted here so the arbiter can see fetch requests even though
  -- the rest of the fetch-side wiring lives inside the
  -- @if enableSdramFetch@ block below.
  --
  -- @coreReqAnySdramS@: any core port (data or fetch) wants a
  -- transaction this cycle. Used as the "core asking" input to the
  -- arbiter.
  --
  -- @jtagReqS@: the JTAG-Avalon-Master IP (or the L-3 altsource_probe
  -- driver) is asserting either @write@ or @read@. Held high through
  -- the IP's transaction by @jam_master_waitrequest@ (= jtagLoadBusyS).
  sdramFetchAnyS :: Signal dom Bool
  sdramFetchAnyS =
    if enableSdramFetch
      then (\fs -> fs == SlaveSdram) <$> (slaveOf <$> pcFetchS)
      else CP.pure False

  coreReqAnySdramS :: Signal dom Bool
  coreReqAnySdramS = (CP.||) <$> sdramSelDataS <*> sdramFetchAnyS

  jtagReqS :: Signal dom Bool
  jtagReqS = (CP.||) <$> sdramJtagWeS <*> sdramJtagRdS

  -- Sticky arbiter for the SDRAM bus mux. Replaces the previous
  -- combinational select on @siJtagLoadMode@ which let the IP's
  -- @master_write@ pulse drag the mux JTAG-side and then release
  -- back to core mid-transaction — corrupting in-flight 16-bit
  -- sub-writes inside @Riski5.Sdram@. The register only updates on
  -- cycles where the SDRAM FSM signals @sdramRawReadyS@ (idle or
  -- about-to-go-idle), so the mux never flips while the controller
  -- has a transaction in flight. JTAG has priority on simultaneous
  -- arrival because uploads are bursty and the boot stub's poll
  -- loop is supposed to stall during the upload anyway.
  jtagMuxOwnerS :: Signal dom JtagMuxOwner
  jtagMuxOwnerS =
    register JmxNone
      $ nextJtagMuxOwner
      <$> jtagMuxOwnerS
      <*> coreReqAnySdramS
      <*> jtagReqS
      <*> sdramRawReadyS

  -- Bus-signal mux: applies the registered owner to a single
  -- (sel, addr, wdata, be, ren) tuple. Used by both the
  -- @enableSdramFetch=True@ arbitered arm and the @=False@ direct arm
  -- below, keeping the JTAG-load contract identical across variants.
  -- With @JmxNone@ no master is driving — the IP sees @sel = False@
  -- and stays in @SIdle@ for the cycle, which makes the next-state
  -- pick well-defined.
  jtagMuxedSdram ::
    Signal dom Bool ->
    Signal dom (BitVector 32) ->
    Signal dom (BitVector 32) ->
    Signal dom (BitVector 4) ->
    Signal dom Bool ->
    ( Signal dom Bool
    , Signal dom (BitVector 32)
    , Signal dom (BitVector 32)
    , Signal dom (BitVector 4)
    , Signal dom Bool
    )
  jtagMuxedSdram selS_ addrS_ wdataS_ beS_ renS_ =
    let sel' =
          ( \o s je jr -> case o of
              JmxJtag -> je CP.|| jr
              JmxCore -> s
              JmxNone -> False
          )
            <$> jtagMuxOwnerS
            <*> selS_
            <*> sdramJtagWeS
            <*> sdramJtagRdS
        addr' =
          ( \o a ja -> case o of
              JmxJtag -> ja
              _ -> a
          )
            <$> jtagMuxOwnerS
            <*> addrS_
            <*> sdramJtagAddrS
        wdata' =
          ( \o w jw -> case o of
              JmxJtag -> jw
              _ -> w
          )
            <$> jtagMuxOwnerS
            <*> wdataS_
            <*> sdramJtagWdataS
        be' =
          ( \o b je jbe -> case o of
              -- JTAG owns the bus: forward the JTAG-Master IP's
              -- byteenable so master_write_8 / master_write_16
              -- actually mask the inactive byte lanes. Earlier
              -- revisions hard-coded this to @0xF@ on the JTAG
              -- arm, which silently promoted every JTAG sub-word
              -- write into a full 32-bit write — surfaced by the
              -- LSWP probe (write_count incremented by 2 for a
              -- 16-bit master_write_16 instead of 1, with the
              -- second chip write driving stale wdata). Goes to
              -- @0@ when JTAG isn't actively writing — same shape
              -- as before.
              JmxJtag -> if je then jbe else 0
              _ -> b
          )
            <$> jtagMuxOwnerS
            <*> beS_
            <*> sdramJtagWeS
            <*> sdramJtagBeS
        ren' =
          ( \o r jr -> case o of
              JmxJtag -> jr
              _ -> r
          )
            <$> jtagMuxOwnerS
            <*> renS_
            <*> sdramJtagRdS
     in (sel', addr', wdata', be', ren')

  ( sdramRdataS
    , sdramBusS
    , sdramDataReadyS
    , sdramFetchDataS
    , sdramFetchReadyS
    , sdramRawReadyS
    ) =
      if enableSdramFetch
        then
          let
            -- Two-port 'Riski5.Sdram.sdram' arbitrates internally
            -- between the core's IF-stage fetch and the data port
            -- (= core's data port muxed with the JTAG-Master IP via
            -- the 'JtagMuxOwner' arbiter that still sits at the data
            -- port). Replaces the SoC-side 'sdramOwnerS' /
            -- 'sdramSelArbS' / 'sdramAddrArbS' multiplex which had
            -- a race: the live arbiter mux (combinational on a
            -- registered owner) could disagree with the cycle the
            -- inner Sdram FSM captured the address, so an
            -- SDRAM-resident @lw@ would return the IF-stage's
            -- prefetched word instead of the load's actual data.
            -- Task #19 silicon capture pinned this; task #21
            -- replaces the broken arbiter with the per-port-aware
            -- design here.
            (selJ, addrJ, wdataJ, beJ, renJ) =
              jtagMuxedSdram sdramSelDataS dAddrS dWdataS dBeS dRenS
            ( sdramFetchDataS''
              , sdramFetchReadyS''
              , sdramRdataS'
              , sdramReadyS'
              , sdramBusS'
              ) =
                sdram
                  sdramFetchAnyS
                  pcFetchS
                  selJ
                  addrJ
                  wdataJ
                  beJ
                  renJ
                  sdramReplyS
            -- Gate the core's data-side "ready" by the JTAG mux
            -- owner: when JTAG owns the data port, the data ready
            -- is the IP completing a JTAG transaction, not the
            -- core's load. Same gating discipline as before — only
            -- the SOURCE of the multiplex changed.
            sdramDataReadyS' =
              ( \jo rdy -> case jo of
                  JmxCore -> rdy
                  _ -> False
              )
                <$> jtagMuxOwnerS
                <*> sdramReadyS'
            -- Fetch ready is unconditionally for the core's IF
            -- stage (JTAG-Master never fetches instructions; it
            -- only writes via the data port).
            sdramFetchReadyS' = sdramFetchReadyS''
           in
            ( sdramRdataS'
            , sdramBusS'
            , sdramDataReadyS'
            , sdramFetchDataS''
            , sdramFetchReadyS'
            , sdramReadyS' -- raw FSM ready (= data-side completion); JTAG-load busy uses this directly
            )
        else
          let
            (selJ, addrJ, wdataJ, beJ, renJ) =
              jtagMuxedSdram sdramSelDataS dAddrS dWdataS dBeS dRenS
            (sdramRdataS', sdramBusS', sdramReadyS') =
              sdramSinglePort selJ addrJ wdataJ beJ renJ sdramReplyS
            -- Gate by sticky-arbiter owner so the core ignores JTAG-
            -- transaction completions on its data port (see the
            -- mirror comment in the @enableSdramFetch=True@ arm).
            sdramDataReadyS' =
              ( \jo rdy -> case jo of
                  JmxCore -> rdy
                  _ -> False
              )
                <$> jtagMuxOwnerS
                <*> sdramReadyS'
           in
            ( sdramRdataS'
            , sdramBusS'
            , sdramDataReadyS'
            , CP.pure 0
            , CP.pure False
            , sdramReadyS' -- raw FSM ready (same as data ready in this branch)
            )

  -- ----- Fetch mux ---------------------------------------------
  -- Combines the BRAM, SRAM, and SDRAM fetch sources into a single
  -- @(imemDataS, imemReadyS, fetchStallS)@ triple driven into the
  -- core's IF-stage. The case-of on @(enableSramFetch,
  -- enableSdramFetch)@ ensures GHC + Clash compile-time-reduce to
  -- exactly the structural wiring needed by each variant — the
  -- @(False, False)@ arm is a literal pass-through to BRAM with no
  -- mux logic emitted, preserving the pre-arbiter Quartus
  -- placement for the CoreMark bitstream.
  fetchSlaveS :: Signal dom SlaveId
  fetchSlaveS = slaveOf <$> pcFetchS

  (imemDataS, imemReadyS, fetchStallS) =
    case (enableSramFetch, enableSdramFetch) of
      (False, False) ->
        ( imemDataBramS
        , CP.pure True
        , CP.pure False
        )
      (True, False) ->
        let
          imemDataS' =
            ( \fs br sr -> case fs of
                SlaveSram -> sr
                _ -> br
            )
              <$> fetchSlaveS
              <*> imemDataBramS
              <*> sramFetchDataS
          imemReadyS' =
            ( \fs sr -> case fs of
                SlaveSram -> sr
                _ -> True
            )
              <$> fetchSlaveS
              <*> sramFetchReadyS
          fetchStallS' =
            (\rdy -> case rdy of True -> False; False -> True) <$> imemReadyS'
         in
          (imemDataS', imemReadyS', fetchStallS')
      (False, True) ->
        let
          imemDataS' =
            ( \fs br dr -> case fs of
                SlaveSdram -> dr
                _ -> br
            )
              <$> fetchSlaveS
              <*> imemDataBramS
              <*> sdramFetchDataS
          imemReadyS' =
            ( \fs dr -> case fs of
                SlaveSdram -> dr
                _ -> True
            )
              <$> fetchSlaveS
              <*> sdramFetchReadyS
          fetchStallS' =
            (\rdy -> case rdy of True -> False; False -> True) <$> imemReadyS'
         in
          (imemDataS', imemReadyS', fetchStallS')
      (True, True) ->
        let
          imemDataS' =
            ( \fs br sr dr -> case fs of
                SlaveSram -> sr
                SlaveSdram -> dr
                _ -> br
            )
              <$> fetchSlaveS
              <*> imemDataBramS
              <*> sramFetchDataS
              <*> sdramFetchDataS
          imemReadyS' =
            ( \fs sr dr -> case fs of
                SlaveSram -> sr
                SlaveSdram -> dr
                _ -> True
            )
              <$> fetchSlaveS
              <*> sramFetchReadyS
              <*> sdramFetchReadyS
          fetchStallS' =
            (\rdy -> case rdy of True -> False; False -> True) <$> imemReadyS'
         in
          (imemDataS', imemReadyS', fetchStallS')

  -- Bus-level stall: any selected slave can deassert ready.
  --   * SRAM + SDRAM stall on read-latency.
  --   * UART stalls for the 1-cycle-registered @av_waitrequest@
  --     the Altera @altera_avalon_jtag_uart@ IP asserts on the
  --     first cycle of every Avalon-MM transaction.
  --   * BRAM (imem-bus-port) stalls for exactly one cycle per
  --     read so the sync-read blockRam output lines up with the
  --     M-stage capture (CM-3).
  --   * GPIO / LCD remain single-cycle.
  -- The master sees the adapter's @waitrequest@ behaviour, not
  -- the IP's directly. 'uartReadyAdapterS' is True only when the
  -- IP's FIFO has space AND the IP itself is ready — i.e. the
  -- master will only see @waitrequest@ deassert on cycles where
  -- a clean commit will actually land in the FIFO.
  uartReadyS = uartReadyAdapterS

  -- The UART tap is masked by 'uartAcceptedS' (the IP saw the
  -- transaction; we hold the master deasserted until X advances).
  -- While masked, the IP's @av_chipselect@ goes 0 and its
  -- @av_waitrequest@ output isn't meaningful — it can sit high
  -- by default. Gate the UART stall by the same accepted latch
  -- so the SoC ignores @!uartReadyS@ in that window. Without
  -- this, on silicon the IP holds waitrequest high after my
  -- accepted-gating engages and 'dataStallS' would stay True
  -- forever, freezing the pipeline (the iter-2 halt symptom
  -- pinpointed via altsource_probe on 2026-04-26).
  -- True iff the data port is actively asserting a memory access
  -- this cycle (any byte-enable bit set OR a read strobe). Used
  -- to gate @dataStallS@ to False when the data port is idle —
  -- without this, an idle data port whose @dAddrS@ happens to
  -- target a slave currently owned by the fetch port would see
  -- @dataStallS=True@ via the inner sticky arbiter's
  -- ownership-gated ready signal, which would freeze the
  -- pipeline-advance gate and prevent the FETCH path from
  -- making progress (task #143 silicon hang follow-up).
  dataAccessS :: Signal dom Bool
  dataAccessS =
    (\be re -> be /= 0 || re) <$> dBeS <*> dRenS

  dataStallS =
    ( \access s sramDataRdy sdramDataRdy uartRdy bramRdy uartAcc ->
        case (access, s) of
          (False, _) -> False
          (True, SlaveSram) -> not sramDataRdy
          (True, SlaveSdram) -> not sdramDataRdy
          (True, SlaveJtagUart) -> case (uartRdy, uartAcc) of
            (True, _) -> False
            (False, True) -> False
            (False, False) -> True
          (True, SlaveBram) -> not bramRdy
          _ -> False
    )
      <$> dataAccessS
      <*> (slaveOf <$> dAddrS)
      <*> sramDataReadyS
      <*> sdramDataReadyS
      <*> uartReadyS
      <*> bramReadyS
      <*> uartAcceptedS

  stallS :: Signal dom Bool
  stallS =
    ( \d f -> case (d, f) of
        (False, False) -> False
        _ -> True
    )
      <$> dataStallS
      <*> fetchStallS

  -- ----- Bus read mux ------------------------------------------
  dmemRdataS :: Signal dom (BitVector 32)
  dmemRdataS =
    ( \s bR uR lR gR cR pR sR dR ->
        case s of
          SlaveBram -> bR
          SlaveJtagUart -> uR
          SlaveLcd -> lR
          SlaveGpio -> gR
          SlaveClint -> cR
          SlavePlic -> pR
          SlaveSram -> sR
          SlaveSdram -> dR
          _ -> 0
    )
      <$> (slaveOf <$> dAddrS)
      <*> bramRdataS
      <*> uartRdataS
      <*> lcdRdataS
      <*> gpioRdataS
      <*> clintRdataS
      <*> plicRdataS
      <*> sramRdataS
      <*> sdramRdataS

  -- ----- Diagnostic flags --------------------------------------
  -- Pack the SoC's stall/ready signals into one 8-bit probe so a
  -- second altsource_probe can sample them via JTAG and tell us
  -- which signal is asserted at the moment of a silicon hang.
  -- See @soDbgFlags@ for the bit layout.
  dbgFlagsS :: Signal dom (BitVector 8)
  dbgFlagsS =
    ( \stall dataStall fetchStall uartAcc sramDataRdy uartRdy bramRdy ->
        let bit0 = if stall then 1 else 0 :: BitVector 8
            bit1 = if dataStall then 2 else 0
            bit2 = if fetchStall then 4 else 0
            bit3 = if uartAcc then 8 else 0
            bit4 = if sramDataRdy then 16 else 0
            bit5 = if uartRdy then 32 else 0
            bit6 = if bramRdy then 64 else 0
         in bit0 .|. bit1 .|. bit2 .|. bit3 .|. bit4 .|. bit5 .|. bit6
    )
      <$> stallS
      <*> dataStallS
      <*> fetchStallS
      <*> uartAcceptedS
      <*> sramDataReadyS
      <*> uartReadyS
      <*> bramReadyS

  -- ----- Freeze-on-trigger capture (SDRAM-exec multi-byte debug)
  -- A 4-cycle snapshot of @pcFetchS@ + the diagnostic flags
  -- starting at the cycle the master-side @uartAcceptedS@ latch
  -- __should__ engage (i.e. the IP is presenting waitrequest=0
  -- with the master's UART-write strobes asserted). The captured
  -- values hold until software pulses @siCaptureReset@ via the
  -- @CAPR@ altsource_probe.
  --
  -- Trigger expression mirrors the engaging arm of
  -- @uartAcceptedNextS@'s case statement so cycle 0 of the
  -- snapshot is the exact decision point. Cycles 1..3 capture
  -- the three subsequent cycles, which lets us see whether the
  -- latch engages on schedule (cycle 1 should show
  -- @uartAcceptedS=1@) or whether something is delaying it.
  --
  -- The buffer is exposed via two indexed altsource_probes:
  -- @FRZP@ returns @bufPc[index]@ and @FRZF@ returns
  -- @bufFlags[index]@, where @index@ is a 2-bit source from
  -- @OFFS@ that software writes via @write_source_data@.
  uartWantsS :: Signal dom Bool
  uartWantsS =
    (\sel be -> case (sel, be /= 0) of (True, True) -> True; _ -> False)
      <$> jtagSelS
      <*> dBeS

  captureTriggerS :: Signal dom Bool
  captureTriggerS =
    ( \stall wants urdy uacc -> case (stall, wants, urdy, uacc) of
        (True, True, True, False) -> True
        _ -> False
    )
      <$> stallS
      <*> uartWantsS
      <*> uartReadyS
      <*> uartAcceptedS

  captureResetS :: Signal dom Bool
  captureResetS = siCaptureReset <$> inS

  captureOffsetS :: Signal dom (Unsigned 2)
  captureOffsetS = siCaptureOffset <$> inS

  -- 5-state state machine:
  --   0: idle (armed, waiting for trigger). On the trigger cycle
  --      itself, slot 0 is captured with the cycle-K values, and
  --      the FSM advances to state 1 for the following cycle.
  --   1: capture slot 1 = cycle K+1.
  --   2: capture slot 2 = cycle K+2.
  --   3: capture slot 3 = cycle K+3.
  --   4: frozen — hold all 4 captures.
  -- Reset takes the SM back to 0.
  captureStateS :: Signal dom (Unsigned 3)
  captureStateS = register 0 captureStateNextS

  captureStateNextS :: Signal dom (Unsigned 3)
  captureStateNextS =
    ( \rst st trig -> case (rst, st, trig) of
        (True, _, _) -> 0
        (False, 0, True) -> 1
        (False, 0, False) -> 0
        (False, 4, _) -> 4
        (False, n, _) -> n + 1
    )
      <$> captureResetS
      <*> captureStateS
      <*> captureTriggerS

  capturedS :: Signal dom Bool
  capturedS = (== 4) <$> captureStateS

  -- Buffer of 4 (pcFetch, flags) snapshots. Slot 0 latches on the
  -- trigger cycle itself (state=0 with trigger asserted). Slots
  -- 1..3 latch on subsequent cycles via state=1..3.
  capturePcBufS :: Signal dom (Vec 4 (BitVector 32))
  capturePcBufS = register (CP.repeat 0) capturePcBufNextS

  capturePcBufNextS :: Signal dom (Vec 4 (BitVector 32))
  capturePcBufNextS =
    ( \buf st trig pc -> case (st, trig) of
        (0, True) -> replace (0 :: Index 4) pc buf
        (1, _) -> replace (1 :: Index 4) pc buf
        (2, _) -> replace (2 :: Index 4) pc buf
        (3, _) -> replace (3 :: Index 4) pc buf
        _ -> buf
    )
      <$> capturePcBufS
      <*> captureStateS
      <*> captureTriggerS
      <*> pcFetchS

  captureFlagsBufS :: Signal dom (Vec 4 (BitVector 8))
  captureFlagsBufS = register (CP.repeat 0) captureFlagsBufNextS

  captureFlagsBufNextS :: Signal dom (Vec 4 (BitVector 8))
  captureFlagsBufNextS =
    ( \buf st trig flags -> case (st, trig) of
        (0, True) -> replace (0 :: Index 4) flags buf
        (1, _) -> replace (1 :: Index 4) flags buf
        (2, _) -> replace (2 :: Index 4) flags buf
        (3, _) -> replace (3 :: Index 4) flags buf
        _ -> buf
    )
      <$> captureFlagsBufS
      <*> captureStateS
      <*> captureTriggerS
      <*> dbgFlagsS

  -- Concatenate all 4 captures into single wide outputs.
  -- The source-driven mux approach (selecting via an @OFFS@
  -- altsource_probe source) didn't propagate reliably on
  -- silicon; reading the full buffer in one read sidesteps
  -- the issue entirely.
  --
  -- Bit layout: slot 0 (trigger cycle) lives in the
  -- most-significant bits. Software splits the 128-bit /
  -- 32-bit reads into 4 chunks.
  frozenPcFetchAllS :: Signal dom (BitVector 128)
  frozenPcFetchAllS =
    ( \buf ->
        let s0 = buf CP.!! (0 :: Index 4)
            s1 = buf CP.!! (1 :: Index 4)
            s2 = buf CP.!! (2 :: Index 4)
            s3 = buf CP.!! (3 :: Index 4)
         in s0 ++# s1 ++# s2 ++# s3
    )
      <$> capturePcBufS

  dbgFrozenFlagsAllS :: Signal dom (BitVector 32)
  dbgFrozenFlagsAllS =
    ( \buf held ->
        let mask :: BitVector 8
            mask = if held then 0x80 else 0x00
            tag b = (b .&. 0x7F) .|. mask
            s0 = tag (buf CP.!! (0 :: Index 4))
            s1 = tag (buf CP.!! (1 :: Index 4))
            s2 = tag (buf CP.!! (2 :: Index 4))
            s3 = tag (buf CP.!! (3 :: Index 4))
         in s0 ++# s1 ++# s2 ++# s3
    )
      <$> captureFlagsBufS
      <*> capturedS

  -- captureOffsetS is read from inS but unused now. Keep it
  -- referenced so GHC doesn't complain about an unused field.
  _captureOffsetUnused :: Signal dom (Unsigned 2)
  _captureOffsetUnused = captureOffsetS

  -- L-3 JTAG-load busy signal: NOT the IP's @av_waitrequest@ (that
  -- only reflects the controller IP's instantaneous state, which is
  -- not-busy most of the time because the IP has its own internal
  -- pipeline). Instead, mirror our 32→16 SDRAM-adapter FSM's
  -- "ready" output back as busy = !ready.
  --
  -- Why: the JTAG-Avalon-Master IP holds @master_write@ only as long
  -- as @master_waitrequest@ is high. Our adapter FSM stays in non-
  -- terminal states (SWriteLoReq → SWriteHiReq → SIdle) for several
  -- cycles per 32-bit write because each 32-bit transaction is
  -- decomposed into two 16-bit IP requests. If we deassert
  -- waitrequest before the FSM has captured the request (which it
  -- does combinationally, not via latches), the master deasserts
  -- @master_write@ at T1 — but the FSM at T1 still needs the
  -- @addr@ / @wdata@ / @be@ inputs to pick the SWriteLoReq's
  -- @writeBus@ outputs, so the IP receives a write of zero to a
  -- garbage address. Tying waitrequest to !ready makes the master
  -- hold its outputs through every state of the FSM, exactly the
  -- shape the FSM was originally designed for (the core's data
  -- port also holds @selS@ until it sees @ready@).
  --
  -- Quartus_stp / altsource_probe is unaffected: that path drives
  -- @JLWE@ via FF-backed altsource_probe registers and observes
  -- @JLBS@ via altsink_probe — many JTAG cycles per probe access,
  -- so by the time the host samples the next state, the FSM has
  -- already cycled through SIdle and is ready again.
  -- Sticky-arbiter aware: even when the SDRAM FSM is idle the JTAG
  -- master must see waitrequest=1 unless it actually owns the bus
  -- (otherwise it would try to issue while the core is mid-flight
  -- and the request would be ignored on the next mux re-pick).
  -- Goes low only on the cycle the FSM completes a JTAG-owned
  -- transaction, exactly the Avalon-MM "transaction accepted" edge
  -- the bridge IP and the L-3 altsource_probe driver both expect.
  jtagLoadBusyS =
    (\rdy jo -> CP.not (rdy CP.&& jo == JmxJtag))
      <$> sdramRawReadyS
      <*> jtagMuxOwnerS

  -- ----- Bundle outputs ----------------------------------------
  outS =
    SocOut
      <$> (gpoLedR <$> gpOutS)
      <*> (gpoLedG <$> gpOutS)
      <*> lcdPinsS
      <*> lcdIrqS
      <*> sramPinsS
      <*> uartIpBusS
      <*> sdramBusS
      <*> pcFetchS
      <*> dmemRdataS
      <*> dbgFlagsS
      <*> frozenPcFetchAllS
      <*> dbgFrozenFlagsAllS
      <*> mtipS
      <*> sdramRdataS
      <*> jtagLoadBusyS
      <*> sdramRdataS
      <*> sdramDataReadyS

  -- ----- Reply going back to the core (Phase D-2 boundary) ----
  -- Bundles every signal the core consumes — imem fetch port,
  -- data-port read result, both stall flags, and the timer +
  -- external interrupt pulses. Caller wraps this with the
  -- bridge (multi-domain) or feeds it straight into 'coreWith'
  -- (single-domain via 'soc' below).
  coreReplyS :: Signal dom CoreBusReply
  coreReplyS =
    CoreBusReply
      <$> imemDataS
      <*> imemReadyS
      <*> dmemRdataS
      <*> stallS
      <*> dataStallS
      <*> mtipS
      <*> meipS

{- |
Single-domain SoC entry point. Backward-compatible wrapper around
'socWithExternalCore' that locally instantiates 'coreWith'. All
existing call sites — every test in @test/@, every silicon
non-multi-PLL bitstream — keep working unchanged.

Multi-domain callers (post-Phase-D-2 @app/Top.hs@) skip this and
call 'socWithExternalCore' directly, instantiating the core in
@DomCore@ and bridging to @DomBus@ via
'Riski5.CoreCdcBridge.coreCdcBridge'.
-}
soc ::
  forall dom p d.
  ( HiddenClockResetEnable dom
  , KnownNat p
  , 1 <= p
  , KnownNat d
  , 1 <= d
  ) =>
  Bool ->
  Bool ->
  Vec p (BitVector 32) ->
  Vec d (BitVector 32) ->
  Signal dom SocIn ->
  Signal dom SocOut
soc enableSramFetch enableSdramFetch progInit dataInit inS = outS
 where
  -- Local core. The mutual recursion between coreReqS (depends on
  -- coreReplyS) and coreReplyS (depends on coreReqS via the bus
  -- body) is broken by registers inside the core and inside each
  -- bus slave; Clash's lazy let resolves it.
  (pcFetchS, _pcExecS, dAddrS, dWdataS, dBeS, dRenS, _wbS, _rvfiS, flushS) =
    coreWith
      tiny32M
      (cbrImemData <$> coreReplyS)
      (cbrImemReady <$> coreReplyS)
      (cbrDmemRdata <$> coreReplyS)
      (cbrStall <$> coreReplyS)
      (cbrDataStall <$> coreReplyS)
      (cbrMtip <$> coreReplyS)
      (cbrMeip <$> coreReplyS)
  coreReqS =
    CoreBusReq <$> pcFetchS <*> dAddrS <*> dWdataS <*> dBeS <*> dRenS <*> flushS
  (outS, coreReplyS) =
    socWithExternalCore enableSramFetch enableSdramFetch progInit dataInit inS coreReqS

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
          , siUartIrq = sisUartIrq
          , siSdramReply = sdr
          , siCaptureReset = False
          , siCaptureOffset = 0
          , siJtagLoadMode = sisJtagLoadMode
          , siJtagLoadAddr = sisJtagLoadAddr
          , siJtagLoadWdata = sisJtagLoadWdata
          , siJtagLoadWe = sisJtagLoadWe
          , siJtagLoadRd = sisJtagLoadRd
          , siJtagLoadBe = sisJtagLoadBe
          }
    )
      <$> inSimS
      <*> uartRdataS
      <*> sdramReplyS
  -- Sim wrappers hardcode both fetch flags 'False'. All existing
  -- sim tests run BRAM-resident firmware, so exercising the
  -- fetch-side arbiters would be off-path; tests that need them
  -- (SramExecSpec / SdramExecSpec) call 'socSimFullWith' instead
  -- and thread the flags through explicitly.
  outS = soc False False progInit dataInit fullInS

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
socSimFull = socSimFullWith False False

{- |
'socSimFull' with explicit fetch-policy flags — lets a test
exercise the fetch-side SRAM and/or SDRAM routing in the same
closed-loop wrapper as 'socSimFull'. Passes both flags straight
into 'soc' so either bitstream variant's pipeline can be
reproduced in Verilator.

Argument order: @socSimFullWith enableSramFetch enableSdramFetch
progInit dataInit sramInit inFullS@.
-}
socSimFullWith ::
  forall dom p d n.
  ( HiddenClockResetEnable dom
  , KnownNat p
  , 1 <= p
  , KnownNat d
  , 1 <= d
  , KnownNat n
  , 1 <= n
  ) =>
  Bool ->
  Bool ->
  Vec p (BitVector 32) ->
  Vec d (BitVector 32) ->
  Vec n (BitVector 16) ->
  Signal dom SocInFull ->
  Signal dom SocOutSim
socSimFullWith enableSramFetch enableSdramFetch progInit dataInit sramInit inFullS = outSimS
 where
  fullInS =
    ( \SocInFull {..} dq ur urRdy sdr ->
        SocIn
          { siSwitches = sifSwitches
          , siKeys = sifKeys
          , siSramDqIn = dq
          , siUartRdata = ur
          , siUartReady = urRdy
          , siUartIrq = False
          , siSdramReply = sdr
          , siCaptureReset = False
          , siCaptureOffset = 0
          , siJtagLoadMode = False
          , siJtagLoadAddr = 0
          , siJtagLoadWdata = 0
          , siJtagLoadWe = False
          , siJtagLoadRd = False
          , siJtagLoadBe = 0
          }
    )
      <$> inFullS
      <*> sramDqInS
      <*> uartRdataS
      <*> uartReadyS
      <*> sdramReplyS
  outS = soc enableSramFetch enableSdramFetch progInit dataInit fullInS

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
          , siUartIrq = sisUartIrq
          , siSdramReply = sdr
          , siCaptureReset = False
          , siCaptureOffset = 0
          , siJtagLoadMode = sisJtagLoadMode
          , siJtagLoadAddr = sisJtagLoadAddr
          , siJtagLoadWdata = sisJtagLoadWdata
          , siJtagLoadWe = sisJtagLoadWe
          , siJtagLoadRd = sisJtagLoadRd
          , siJtagLoadBe = sisJtagLoadBe
          }
    )
      <$> inSimS
      <*> uartRdataS
      <*> uartReadyS
      <*> sdramReplyS
  -- See note on 'socSim' re: hardcoded fetch-policy.
  outS = soc False False progInit dataInit fullInS

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
