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
Module      : Riski5.JtagUartAdapter
Description : "Polite" Avalon-MM proxy in front of the Altera JTAG-UART IP.

The Altera @altera_avalon_jtag_uart@ IP has a well-known correctness
bug: it commits a byte to its TX FIFO every cycle the master asserts
@chipselect=1 && write_n=0@ with the IP's @waitrequest=1@, regardless
of FIFO state. When the FIFO is full, the byte is __silently
dropped__ — the IP sets a @woverflow@ status flag in the CONTROL
register but doesn't refuse the transaction or backpressure the
master via @waitrequest@. Every Nios II reference design since
~2007 has worked around this in firmware by polling the @WSPACE@
field of the CONTROL register before each write. This adapter
moves that workaround into hardware so the firmware sees
__standard Avalon-MM backpressure semantics__: when the FIFO is
full, the master simply waits until the IP can accept.

== How it works

1. __Local FIFO occupancy tracking__. The adapter maintains a
   7-bit counter @freeBytesS@ (range 0..64, matching the IP's
   default @writeBufferDepth@). Initialised to 64 (FIFO empty);
   decremented on each successful master DATA write that the
   adapter forwards to the IP; refreshed from the IP's WSPACE
   field whenever a CTRL read returns.

2. __Standard Avalon-MM backpressure to the master__. The master
   sees a clean Avalon-MM slave: @waitrequest=1@ when the FIFO
   would overflow on this transaction, @waitrequest=0@ when it
   would commit cleanly. No @woverflow@-can-fire-silently
   surprises.

3. __Self-contained polling loop__. While the master is held
   (i.e. it's trying a DATA write but @freeBytes == 0@), the
   adapter issues its own CTRL-read transactions to the IP at
   the bus rate, snooping the WSPACE field on each response. As
   soon as WSPACE goes non-zero (drain happened), the adapter
   releases the master and the master's pending DATA write
   commits cleanly.

4. __CTRL accesses pass through transparently__. Master CTRL
   reads/writes (address bit @[2] = 1@) are forwarded to the IP
   directly. CTRL reads have their WSPACE field snooped to keep
   @freeBytesS@ in sync with the IP's actual state — the firmware
   gets a "free" refresh whenever it touches CTRL.

5. __Compatible with the existing @uartAcceptedS@ gating__ in
   "Riski5.Soc". That gating limits each master transaction to a
   single IP commit cycle (preventing multi-commit during the
   IP's quirky @waitrequest@-toggle protocol). The adapter sits
   __after__ the gating, so it sees the canonical 2-cycle master
   assertion per write and just adds the FIFO-full backpressure
   on top. Master's view stays clean Avalon-MM either way.

== Why not just patch the IP

The Altera IP is opaque generated Verilog with no Tcl knob to
turn this behaviour off. Modifying the generated source would
break the @ip-generate@ regeneration at every @nix build@. A
small adapter wrapper in our own code is the right surface for
the fix, and it's the same pattern CLAUDE.md endorses for the
"Altera IP black-boxing policy" exception case.
-}
module Riski5.JtagUartAdapter (
  jtagUartAdapter,
) where

import Clash.Prelude hiding (not, (&&), (||))
import Clash.Prelude qualified as CP
import Riski5.AvalonMm (AvalonMmBus (..))

-- * Constants ------------------------------------------------------

-- | Address of the JTAG-UART CONTROL register (DATA register +
-- 4 bytes). The adapter polls this when the FIFO is full to
-- learn when drain has happened.
ctrlAddr :: BitVector 32
ctrlAddr = 0x1000_0004

-- | The fixed CTRL-read transaction the adapter issues during
-- the polling phase. @ambBe = 0@ marks it as a read; @ambRe = 1@
-- asserts the read strobe (the SoC interprets nonzero @ambBe@ as
-- a write, zero as a read, and the wrapper's @av_read_n@ is
-- driven from @ambRe@).
pollBus :: AvalonMmBus
pollBus =
  AvalonMmBus
    { ambSel = True
    , ambAddr = ctrlAddr
    , ambWdata = 0
    , ambBe = 0
    , ambRe = True
    }

-- | A bus output that drives no transaction — chipselect=0,
-- everything else don't-care. Used in the brief "GAP" cycle
-- between the polling phase and resuming the master, to ensure
-- the IP sees a clean transition rather than back-to-back
-- transactions of different kinds.
idleBus :: AvalonMmBus
idleBus =
  AvalonMmBus
    { ambSel = False
    , ambAddr = 0
    , ambWdata = 0
    , ambBe = 0
    , ambRe = False
    }

-- * State machine -------------------------------------------------

{- |
Adapter state. Most cycles the adapter is in 'JaIdle', forwarding
the master's bus signals to the IP transparently. When the master
attempts a DATA write while @freeBytesS == 0@, the adapter
transitions to 'JaPoll' and starts issuing its own CTRL reads.
'JaGap' is a single-cycle bridge between 'JaPoll' and 'JaIdle'
that drives 'idleBus' to ensure the IP's transaction-state
machine sees a clean boundary between the adapter's poll and
the master's resumed transaction (otherwise back-to-back
transactions of different kinds can confuse the IP's @av_waitrequest@
toggle protocol).
-}
data JaState
  = JaIdle
  | JaPoll
  | JaGap
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

-- * Adapter --------------------------------------------------------

{- |
Polite Avalon-MM adapter for the Altera JTAG-UART IP. See module
header for the semantics. The interface is symmetric with the
existing 'Riski5.Soc.soc' bus tap: a single 'AvalonMmBus' record
in each direction, plus the rdata / ready scalars that don't fit
into the canonical record shape.
-}
jtagUartAdapter ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  -- | Master-side bus (canonical Avalon-MM master record from
  -- "Riski5.Soc"; already passed through 'uartAcceptedS' gating
  -- so it's a 2-cycle assertion per transaction).
  Signal dom AvalonMmBus ->
  -- | IP's @av_readdata@ (32 bits — DATA register read for byte,
  -- CONTROL register read for status/WSPACE).
  Signal dom (BitVector 32) ->
  -- | IP's ready signal (= @~av_waitrequest@). The IP toggles this
  -- between transactions per its non-standard "commit on
  -- waitrequest=1, ack on waitrequest=0" protocol — opaque to
  -- the master through this adapter.
  Signal dom Bool ->
  -- | @(masterRdata, masterReady, ipBus)@ — what the master sees
  -- back, plus the bus signals the adapter drives to the IP.
  ( Signal dom (BitVector 32)
  , Signal dom Bool
  , Signal dom AvalonMmBus
  )
jtagUartAdapter mBus ipRdata ipReady = (masterRdata, masterReady, ipBus)
 where
  -- ----- Master-request decoding -------------------------------
  -- CTRL register lives at base+4, DATA at base+0. Bit [2] of the
  -- master's address discriminates them (the SoC's bus decoder
  -- already routes UART-range addresses to 'soUartBus', so we
  -- only need to tell DATA from CTRL).
  mIsCtrlS = (\m -> ambSel m CP.&& testBit (ambAddr m) 2) <$> mBus
  mIsDataS = (\m -> ambSel m CP.&& CP.not (testBit (ambAddr m) 2)) <$> mBus
  mIsWriteS = (\m -> ambBe m /= 0) <$> mBus
  mIsDataWriteS = (CP.&&) <$> mIsDataS <*> mIsWriteS
  mIsCtrlReadS = (\c w -> c CP.&& CP.not w) <$> mIsCtrlS <*> mIsWriteS

  -- ----- FIFO occupancy counter --------------------------------
  freeBytesS :: Signal dom (Unsigned 7)
  freeBytesS = register 64 freeBytesNextS

  fifoFullS :: Signal dom Bool
  fifoFullS = (== 0) <$> freeBytesS

  -- WSPACE bits live in [22:16] of the CONTROL register's read
  -- value (range 0..64).
  wspaceFromIpS :: Signal dom (Unsigned 7)
  wspaceFromIpS = (\rd -> unpack (slice d22 d16 rd)) <$> ipRdata

  -- IP-side rising edge of @ipReady@. Used for the JaPoll → JaGap
  -- transition (CTRL-read response detection) and as the snoop
  -- trigger for master-issued CTRL reads in JaIdle.
  ipReadyPrevS :: Signal dom Bool
  ipReadyPrevS = register False ipReady

  ipAcceptS :: Signal dom Bool
  ipAcceptS = (\r p -> r CP.&& CP.not p) <$> ipReady <*> ipReadyPrevS

  -- Master-side falling edge of @mIsDataWriteS@. The SoC's
  -- @uartAcceptedS@ latch gates @ambSel@/@ambBe@ to 0 exactly one
  -- cycle after the master first asserts a UART data write — by
  -- construction (CMTC = 2.000/iter on silicon, confirmed via
  -- @altsource_probe@ on 2026-04-26), exactly one IP-side commit
  -- happens per master assertion. So the falling edge of
  -- @mIsDataWriteS@ marks the cycle one cycle after the IP committed
  -- a byte to its TX FIFO.
  --
  -- The reason we don't use the IP's @waitrequest@ toggle as the
  -- commit signal: @ipReady@ is a registered input on the SoC side
  -- and the IP's commit cycle (= waitrequest=1 with chipselect=1) is
  -- only visible in Verilog. By the time @ipReady@ falls in Clash,
  -- the SoC has already gated @mIsDataWriteS@ to False, breaking the
  -- @(JaIdle, ipAcceptS && dw)@ pattern that the original adapter
  -- used. Falling-edge detection of the master-side signal sidesteps
  -- that timing skew entirely.
  mIsDataWritePrevS :: Signal dom Bool
  mIsDataWritePrevS = register False mIsDataWriteS

  ipCommitS :: Signal dom Bool
  ipCommitS =
    (\dw dwp -> CP.not dw CP.&& dwp) <$> mIsDataWriteS <*> mIsDataWritePrevS

  -- ----- State machine -----------------------------------------
  stateS :: Signal dom JaState
  stateS = register JaIdle stateNextS

  -- Cycles spent in 'JaPoll'. Resets to 0 in any other state. Used
  -- to gate WSPACE sampling: at @JaPoll@ entry the IP hasn't yet
  -- driven its rdata in response to our @pollBus@ transaction, so we
  -- need at least one cycle of latency before trusting the read
  -- value. Saturates at 7 to keep the counter narrow (any cycle past
  -- the first is "rdata definitely valid").
  pollCntS :: Signal dom (Unsigned 3)
  pollCntS = register 0 pollCntNextS

  pollCntNextS :: Signal dom (Unsigned 3)
  pollCntNextS =
    ( \st cnt -> case st of
        JaPoll -> if cnt < 7 then cnt + 1 else cnt
        _ -> 0
    )
      <$> stateS
      <*> pollCntS

  -- WSPACE-from-rdata is valid for sampling when:
  --   (a) we've spent at least 1 cycle in @JaPoll@ (so the IP has had
  --       time to drive its rdata in response to the pollBus
  --       transaction; protects against carrying stale ipRdata from
  --       a prior master DATA write into the JaPoll decision), AND
  --   (b) ipReady=True (= waitrequest=0, the standard Avalon-MM
  --       "rdata valid" indicator).
  --
  -- This works for both protocol shapes:
  --   * The Altera-IP-faithful sim ('jtagUartAlteraSim') is
  --     combinational and asserts ipReady=True throughout reads, so
  --     this fires at JaPoll cycle 1.
  --   * Silicon's actual Altera IP goes through a brief
  --     waitrequest=1 latency before returning rdata; ipReady comes
  --     back to True when rdata is valid, by which time @cnt >= 1@.
  --
  -- Original adapter used @ipAcceptS@ (rising edge of ipReady) for
  -- this — that works on silicon's toggle protocol but not on the
  -- combinational sim, where ipReady never falls in the first place.
  pollWsValidS :: Signal dom Bool
  pollWsValidS = (\r cnt -> r CP.&& cnt >= 1) <$> ipReady <*> pollCntS

  stateNextS :: Signal dom JaState
  stateNextS =
    ( \st full dw wsValid ws -> case st of
        JaIdle -> if dw CP.&& full then JaPoll else JaIdle
        JaPoll ->
          if wsValid CP.&& ws > 0
            then JaGap
            else JaPoll
        JaGap -> JaIdle
    )
      <$> stateS
      <*> fifoFullS
      <*> mIsDataWriteS
      <*> pollWsValidS
      <*> wspaceFromIpS

  -- ----- Master held? ------------------------------------------
  -- Master sees waitrequest=1 (mReady=False) whenever:
  --   * we're in 'JaPoll' or 'JaGap' (busy with adapter-internal
  --     bus traffic), OR
  --   * we're in 'JaIdle' but the master's data write is about
  --     to drive 'JaPoll' next cycle (= dw CP.&& fifoFull).
  -- The 'JaIdle CP.&& dw CP.&& fifoFull' arm is what forces the
  -- master to stay asserted through the JaIdle→JaPoll edge.
  masterHeldS :: Signal dom Bool
  masterHeldS =
    ( \st dw full -> case st of
        JaIdle -> dw CP.&& full
        JaPoll -> True
        JaGap -> True
    )
      <$> stateS
      <*> mIsDataWriteS
      <*> fifoFullS

  -- ----- IP-side bus -------------------------------------------
  -- - JaIdle, !held → forward master directly.
  -- - JaIdle,  held → drive idle: this is the cycle where the
  --   adapter signals waitrequest=1 to the master because @fb == 0@,
  --   but the next cycle's state will be JaPoll. Without this gate,
  --   the master's bus signals would still flow through to the IP
  --   on this same cycle (because @ipBus@ is combinational off
  --   @stateS@), and the IP would commit one byte the adapter
  --   doesn't account for — producing a "phantom" extra commit
  --   right before the throttle engages.
  -- - JaPoll → drive CTRL-read transaction.
  -- - JaGap  → drive idle (1-cycle clean transition before
  --   resuming the master).
  ipBus :: Signal dom AvalonMmBus
  ipBus =
    ( \st held mb -> case (st, held) of
        (JaIdle, False) -> mb
        (JaIdle, True) -> idleBus
        (JaPoll, _) -> pollBus
        (JaGap, _) -> idleBus
    )
      <$> stateS
      <*> masterHeldS
      <*> mBus

  -- ----- Master-side reply -------------------------------------
  masterRdata :: Signal dom (BitVector 32)
  masterRdata = ipRdata

  masterReady :: Signal dom Bool
  masterReady =
    (\held r -> if held then False else r) <$> masterHeldS <*> ipReady

  -- ----- Counter update ----------------------------------------
  -- Possible events that mutate freeBytes:
  --   1. JaPoll, pollWsValid, ws>0 → refresh fb := ws (poll
  --                                  response — the WSPACE we're
  --                                  waiting for; matches the JaPoll
  --                                  → JaGap state transition).
  --   2. JaIdle, ipCommit          → decrement (a master DATA write
  --                                  just committed; the falling
  --                                  edge of @mIsDataWriteS@ marks
  --                                  one cycle after the IP commit).
  --   3. JaIdle, ipAccept && cr    → refresh fb := ws (master did
  --                                  its own CTRL read on silicon's
  --                                  toggle protocol; we snoop the
  --                                  WSPACE field for free. Doesn't
  --                                  fire on the combinational sim,
  --                                  but the JaPoll path is the
  --                                  primary refresh mechanism so
  --                                  the snoop is best-effort.)
  --   4. Otherwise                 → hold.
  freeBytesNextS :: Signal dom (Unsigned 7)
  freeBytesNextS =
    ( \st fb commit cr acc wsValid ws -> case st of
        JaPoll
          | wsValid CP.&& ws > 0 -> ws
          | otherwise -> fb
        JaIdle
          | commit -> if fb > 0 then fb - 1 else 0
          | acc CP.&& cr -> ws
          | otherwise -> fb
        JaGap -> fb
    )
      <$> stateS
      <*> freeBytesS
      <*> ipCommitS
      <*> mIsCtrlReadS
      <*> ipAcceptS
      <*> pollWsValidS
      <*> wspaceFromIpS
