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
Module      : Riski5.Lcd
Description : Self-timed HD44780 (16×2 character LCD) controller.

The controller fully owns HD44780 timing. At reset it runs a
Vcc-settle window, the three 0x30 wake commands, function-set,
display-on, entry-mode, and clear — all sequenced internally with
the right per-command delays. Firmware only sees a \"busy\" flag
(high while any of that is happening *or* a user command is in
flight) and an IRQ line that fires on the busy-falling edge.

Phase-1 register layout (word offsets within the 32-byte MMIO
window from 'Riski5.MemMap'):

@
  offset 0x00 — DATA    (W): queues a character byte (RS=1).
  offset 0x04 — CMD     (W): queues a command byte  (RS=0).
  offset 0x08 — STATUS  (R): bit 0 = busy, bit 1 = irq_pending.
                       (W): write 1 to bit 1 to clear irq_pending.
  offset 0x0C — CTRL   (RW): bit 0 = irq_enable.
@

Why \"self-timed\":

  * HD44780 \"clear\" and \"return home\" need 1.52 ms post-write.
    All other commands need 37 µs. Data writes need 37 µs. The
    old controller used a uniform 2 000-cycle (40 µs) wait and
    forced firmware to hand-insert longer waits around clear /
    home. Here the controller knows per-command timings and keeps
    @busy@ high until the actual HD44780 chip is ready again.
  * HD44780 boot requires a documented wake sequence (>15 ms Vcc
    settle, three 0x30s with ≥4.1 ms / ≥100 µs gaps, then function-
    set / display-on / entry-mode / clear). The old controller
    left that whole dance to firmware — now it runs automatically
    from reset, so application firmware just waits on @busy@ (or
    the IRQ) and writes characters.
  * An IRQ output lets the CPU sleep instead of polling. Firmware
    sets CTRL[0]=1 once; every busy-falling edge sets STATUS[1]
    and asserts the IRQ until firmware writes-1-to-clear.

Timing constants at 50 MHz (20 ns / cycle):

  * Address setup (data / RS stable before E rises): 8 cycles / 160 ns.
  * @E@ high pulse: 16 cycles / 320 ns (spec ≥230 ns).
  * Post-command wait: 2 000 cycles (40 µs) for most commands,
    80 000 cycles (1.6 ms) for clear / return home.
  * Vcc-settle at reset: 1 500 000 cycles (30 ms).
  * Wake-1 post-wait: 250 000 cycles (5 ms; spec ≥4.1 ms).
  * Wake-2 / Wake-3 post-wait: 10 000 cycles (200 µs; spec ≥100 µs).

Real-hardware verification is the on-board test; LcdSpec's unit
tests pass a tiny startup count so they run in milliseconds.
-}
module Riski5.Lcd (
  lcd,
  lcdWith,
  LcdPins (..),
  LcdParams (..),
  defaultParams,
) where

import Clash.Prelude hiding (not, (&&), (||))
import Riski5.MemMap (lcdBase)

-- * Pins -----------------------------------------------------------

{- |
Bundle of LCD pins exposed by the controller. Wired straight to
the DE2 top-entity outputs by @Riski5.Soc@ / @app\/Top.hs@.
-}
data LcdPins = LcdPins
  { lcdData :: BitVector 8
  , lcdRs :: Bit
  , lcdRw :: Bit
  , lcdE :: Bit
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

-- * FSM types ------------------------------------------------------

{- | Sub-phase of a single HD44780 byte transaction.

One @Emit@ always walks through @Setup@ → @Pulse@ → @Wait@:

  * @Setup@: data / RS latched, @E@ still low — address-setup time.
  * @Pulse@: @E@ high, HD44780 sees the rising edge.
  * @Wait@ : @E@ low, enforcing the chip's internal busy period.
-}
data Phase = SetupPh | PulsePh | WaitPh
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- | Steps in the autonomous boot sequence.

Runs once at reset (after Vcc settle) and terminates into @Ready@.
Each step is emitted as a single @Emit@ transaction with its own
post-wait length.
-}
data BootStep
  = BootWake1
  | BootWake2
  | BootWake3
  | BootFuncSet
  | BootDispOn
  | BootEntry
  | BootClear
  deriving stock (Eq, Show, Generic, Enum, Bounded)
  deriving anyclass (NFDataX)

{- | Top-level FSM state.

  * @StartupSettle n@: waiting for Vcc to stabilise — @n@ cycles left.
  * @Emit rs byte phase count wait bootStep@: a single HD44780 byte
    in flight. @bootStep = Just s@ means this is part of the boot
    sequence and the controller advances to the step after @s@ when
    the @Wait@ completes; @bootStep = Nothing@ means it was a user
    write and the controller returns to @Ready@.
  * @Ready@: idle, accepting user writes.
-}
data LcdState
  = StartupSettle !(BitVector 32)
  | Emit
      !Bit
      !(BitVector 8)
      !Phase
      !(BitVector 32)
      !(BitVector 32)
      !(Maybe BootStep)
  | Ready
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

isBusy :: LcdState -> Bool
isBusy = \case
  Ready -> False
  _ -> True

-- * Parameters -----------------------------------------------------

{- | Tunable timing constants. In hardware the defaults from
@defaultParams@ apply; tests pass a minimised set so they finish
in milliseconds.
-}
data LcdParams = LcdParams
  { paramStartupCycles :: BitVector 32
  -- ^ Vcc-settle window at reset. Spec: ≥15 ms. Default: 30 ms.
  , paramSetupCycles :: BitVector 32
  -- ^ Data / RS stable before @E@ rises. Default: 8 cycles / 160 ns.
  , paramPulseCycles :: BitVector 32
  -- ^ @E@ high duration. Spec: ≥230 ns. Default: 16 cycles / 320 ns.
  , paramWake1Wait :: BitVector 32
  -- ^ Post-wait after first 0x30. Spec: ≥4.1 ms. Default: 5 ms.
  , paramWake23Wait :: BitVector 32
  -- ^ Post-wait after second & third 0x30. Spec: ≥100 µs. Default: 200 µs.
  , paramShortWait :: BitVector 32
  -- ^ Post-wait for \"most commands\" and data writes. Default: 40 µs.
  , paramLongWait :: BitVector 32
  -- ^ Post-wait for clear / return-home. Default: 1.6 ms.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

defaultParams :: LcdParams
defaultParams =
  LcdParams
    { paramStartupCycles = 1_500_000
    , paramSetupCycles = 8
    , paramPulseCycles = 16
    , paramWake1Wait = 250_000
    , paramWake23Wait = 10_000
    , paramShortWait = 2_000
    , paramLongWait = 80_000
    }

-- * Boot-step data ------------------------------------------------

bootByte :: BootStep -> BitVector 8
bootByte = \case
  BootWake1 -> 0x30
  BootWake2 -> 0x30
  BootWake3 -> 0x30
  BootFuncSet -> 0x38
  BootDispOn -> 0x0C
  BootEntry -> 0x06
  BootClear -> 0x01

bootWaitFor :: LcdParams -> BootStep -> BitVector 32
bootWaitFor LcdParams {..} = \case
  BootWake1 -> paramWake1Wait
  BootWake2 -> paramWake23Wait
  BootWake3 -> paramWake23Wait
  BootFuncSet -> paramShortWait
  BootDispOn -> paramShortWait
  BootEntry -> paramShortWait
  BootClear -> paramLongWait

nextBoot :: BootStep -> Maybe BootStep
nextBoot = \case
  BootWake1 -> Just BootWake2
  BootWake2 -> Just BootWake3
  BootWake3 -> Just BootFuncSet
  BootFuncSet -> Just BootDispOn
  BootDispOn -> Just BootEntry
  BootEntry -> Just BootClear
  BootClear -> Nothing

{- | Post-wait for a user-issued transaction.

The byte argument is named @dataByte@ rather than @byte@ because
Clash propagates pattern-variable names into the emitted Verilog
and @byte@ is a reserved keyword in SystemVerilog / Verilog-2005
onward (Verilator 5 rejects the signal).
-}
userWaitFor :: LcdParams -> Bit -> BitVector 8 -> BitVector 32
userWaitFor LcdParams {..} rs dataByte
  | rs == low && (dataByte == 0x01 || dataByte == 0x02) = paramLongWait
  | otherwise = paramShortWait

beginBoot :: LcdParams -> BootStep -> LcdState
beginBoot params step =
  Emit
    low
    (bootByte step)
    SetupPh
    (paramSetupCycles params - 1)
    (bootWaitFor params step)
    (Just step)

beginUser :: LcdParams -> Bit -> BitVector 8 -> LcdState
beginUser params rs dataByte =
  Emit
    rs
    dataByte
    SetupPh
    (paramSetupCycles params - 1)
    (userWaitFor params rs dataByte)
    Nothing

-- * MMIO offsets ---------------------------------------------------

offsetData, offsetCmd, offsetStatus, offsetCtrl :: BitVector 32
offsetData = lcdBase + 0
offsetCmd = lcdBase + 4
offsetStatus = lcdBase + 8
offsetCtrl = lcdBase + 12

-- * Controller -----------------------------------------------------

{- |
HD44780 controller with default timing (30 ms startup, real HD44780
per-command waits). See 'lcdWith' for a parameterised variant that
tests can drive with a tiny startup window.
-}
lcd ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  Signal dom Bool ->
  Signal dom (BitVector 32) ->
  Signal dom (BitVector 32) ->
  Signal dom (BitVector 4) ->
  Signal dom Bool ->
  ( Signal dom (BitVector 32)
  , Signal dom LcdPins
  , Signal dom Bool
  )
lcd = lcdWith defaultParams

{- |
Parameterised HD44780 controller. Same behaviour as 'lcd' but
every timing constant is taken from 'LcdParams', so tests can
shrink the startup window from 30 ms to a handful of cycles.
-}
lcdWith ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  LcdParams ->
  Signal dom Bool ->
  Signal dom (BitVector 32) ->
  Signal dom (BitVector 32) ->
  Signal dom (BitVector 4) ->
  Signal dom Bool ->
  ( Signal dom (BitVector 32)
  , Signal dom LcdPins
  , Signal dom Bool
  )
lcdWith params selS addrS wdataS beS _readEnS =
  (rdataS, pinsS, irqS)
 where
  -- ----- FSM ----------------------------------------------------
  stateS :: Signal dom LcdState
  stateS = register (StartupSettle (paramStartupCycles params - 1)) nextStateS

  -- User write request: only honoured in Ready.
  writeReqS =
    ( \sel addr be wdata st ->
        let writeOk = sel && be /= 0
            isData = writeOk && addr == offsetData
            isCmd = writeOk && addr == offsetCmd
            isReady = case st of Ready -> True; _ -> False
         in case (isReady, isData, isCmd) of
              (True, True, _) -> Just (high, slice d7 d0 wdata)
              (True, _, True) -> Just (low, slice d7 d0 wdata)
              _ -> Nothing
    )
      <$> selS
      <*> addrS
      <*> beS
      <*> wdataS
      <*> stateS

  nextStateS =
    ( \req st ->
        case st of
          StartupSettle 0 -> beginBoot params BootWake1
          StartupSettle c -> StartupSettle (c - 1)
          Emit rs dataByte SetupPh 0 w boot ->
            Emit rs dataByte PulsePh (paramPulseCycles params - 1) w boot
          Emit rs dataByte SetupPh c w boot ->
            Emit rs dataByte SetupPh (c - 1) w boot
          Emit rs dataByte PulsePh 0 w boot ->
            Emit rs dataByte WaitPh (w - 1) w boot
          Emit rs dataByte PulsePh c w boot ->
            Emit rs dataByte PulsePh (c - 1) w boot
          Emit _ _ WaitPh 0 _ (Just bs) ->
            case nextBoot bs of
              Just nb -> beginBoot params nb
              Nothing -> Ready
          Emit _ _ WaitPh 0 _ Nothing -> Ready
          Emit rs dataByte WaitPh c w boot ->
            Emit rs dataByte WaitPh (c - 1) w boot
          Ready -> case req of
            Just (rs, bits) -> beginUser params rs bits
            Nothing -> Ready
    )
      <$> writeReqS
      <*> stateS

  -- ----- Busy / IRQ --------------------------------------------
  busyS :: Signal dom Bool
  busyS = isBusy <$> stateS

  busyPrevS :: Signal dom Bool
  busyPrevS = register True busyS

  busyFallS :: Signal dom Bool
  busyFallS = (\prev now -> prev && not now) <$> busyPrevS <*> busyS

  -- STATUS W1C: write with bit 1 of wdata set clears irq_pending.
  irqClearS :: Signal dom Bool
  irqClearS =
    ( \sel addr be wdata ->
        sel
          && addr == offsetStatus
          && be /= 0
          && testBit (unpack wdata :: Unsigned 32) 1
    )
      <$> selS
      <*> addrS
      <*> beS
      <*> wdataS

  irqPendS :: Signal dom Bool
  irqPendS = register False nextIrqPendS

  nextIrqPendS =
    ( \fall clear pending ->
        if clear
          then False
          else fall || pending
    )
      <$> busyFallS
      <*> irqClearS
      <*> irqPendS

  -- CTRL[0] = irq_enable. Write sets it; reads return current value.
  irqEnS :: Signal dom Bool
  irqEnS = register False nextIrqEnS

  ctrlWriteS :: Signal dom (Maybe Bool)
  ctrlWriteS =
    ( \sel addr be wdata ->
        if sel && addr == offsetCtrl && be /= 0
          then Just (testBit (unpack wdata :: Unsigned 32) 0)
          else Nothing
    )
      <$> selS
      <*> addrS
      <*> beS
      <*> wdataS

  nextIrqEnS =
    (\req cur -> maybe cur id req) <$> ctrlWriteS <*> irqEnS

  irqS :: Signal dom Bool
  irqS = (&&) <$> irqEnS <*> irqPendS

  -- ----- Pin outputs -------------------------------------------
  pinsS =
    ( \st -> case st of
        Emit rs b PulsePh _ _ _ ->
          LcdPins {lcdData = b, lcdRs = rs, lcdRw = low, lcdE = high}
        Emit rs b _ _ _ _ ->
          LcdPins {lcdData = b, lcdRs = rs, lcdRw = low, lcdE = low}
        _ ->
          LcdPins {lcdData = 0, lcdRs = low, lcdRw = low, lcdE = low}
    )
      <$> stateS

  -- ----- Register reads -----------------------------------------
  rdataS =
    ( \sel addr busy pend en ->
        if not sel
          then 0
          else case addr of
            a
              | a == offsetStatus ->
                  (if busy then 1 else 0)
                    .|. (if pend then 2 else 0)
              | a == offsetCtrl ->
                  if en then 1 else 0
              | otherwise -> 0
    )
      <$> selS
      <*> addrS
      <*> busyS
      <*> irqPendS
      <*> irqEnS
