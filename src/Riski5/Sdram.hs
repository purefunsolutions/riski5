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
Module      : Riski5.Sdram
Description : 32 ↔ 16-bit adapter for the Altera SDRAM Controller IP on the DE2.

The Altera @altera_avalon_new_sdram_controller@ IP exposes an
__Avalon-MM slave__ at the native width of the SDRAM chip. Our DE2
has a single 16-bit SDR SDRAM (ISSI IS42S16400, 4 M × 16 = 8 MB), so
the IP is generated with @dataWidth=16@ and the Avalon-MM slave is
16-bit-wide; the SoC master bus is 32-bit. This module owns the
width-adaptation FSM that splits every 32-bit core-side access into
two back-to-back 16-bit Avalon transactions (lo then hi).

== Why not generate the IP at @dataWidth=32@?

@dataWidth@ describes the /chip-side/ DQ width, not just the master
bus. Setting it to 32 makes the IP emit a @zs_dq[31:0]@ / @zs_dqm[3:0]@
SDRAM-chip interface — i.e. two 16-bit chips in parallel — which the
DE2 doesn't have. The single-chip configuration forces
@dataWidth=16@ and pushes the 32 ↔ 16 split into our logic. This
module is that logic.

== Similarity to 'Riski5.Sram'

The state layout mirrors 'Riski5.Sram' — each 32-bit store fans out
to two half-word bus transactions and each read promotes to a
uniform 32-bit word fetch. The difference is the /handshake shape/:

  * 'Riski5.Sram' drives raw async-SRAM pins with a pulse + recovery
    cycle pair; every transaction takes a fixed number of cycles.
  * 'Riski5.Sdram' holds each Avalon-MM request until the IP
    deasserts @az_waitrequest@ (FIFO slot available), then waits for
    the returning @za_valid@ pulse on reads. Write latency is just
    "until the FIFO accepts"; read latency adds the IP's round-trip
    (ACTIVATE + CAS + precharge scheduling) before @za_valid@.

The core stalls through the non-terminal cycles via @readyS=False@,
same as the SRAM path.

== Outputs

The @sdram@ adapter returns two bundles:

  * An 'SdramIpBus' signal carrying the master-side Avalon-MM
    request signals (@az_*@); the SoC routes this to @soSdramBus@
    and from there, in the Verilog wrapper, to the IP's slave ports.
    In simulation, 'sdramIpSim' plugs in at the same boundary.
  * @(rdata, ready)@ back to the bus decoder inside the SoC.

The chip-side @zs_*@ pins never pass through the SoC — the IP drives
them directly, and the Verilog wrapper threads them to the board's
@DRAM_*@ pads (with bidirectional @DRAM_DQ@ resolution).
-}
module Riski5.Sdram (
  -- * Master-side bus record (bridged to the IP in Verilog)
  SdramIpBus (..),
  SdramIpReply (..),

  -- * Adapter
  sdram,

  -- * Behavioural simulation model of the IP + chip
  sdramIpSim,
) where

import Clash.Prelude hiding (not, (&&), (||))
import Clash.Prelude qualified as CP
import Data.Proxy (Proxy (..))
import Riski5.MemMap (sdramBase)

-- * Record shapes ---------------------------------------------------

{- | Master-side Avalon-MM request signals exposed by 'sdram'. Field
names match the Altera IP's port names (@az_*@) so the Verilog
wrapper's correspondence is one-line-per-field. Active-low strobes
are stored active-high in this record and negated at the boundary.
-}
data SdramIpBus = SdramIpBus
  { sibCs :: Bool
  -- ^ @az_cs@: chipselect (active high)
  , sibAddr :: BitVector 22
  {- ^ @az_addr@: 22-bit 16-bit-word address (indexes 4 M half-words
  = 8 MB of SDRAM).
  -}
  , sibWdata :: BitVector 16
  -- ^ @az_data@: write-data half-word
  , sibBe :: BitVector 2
  {- ^ Byte-enable (active high). Wrapper negates this into
  @az_be_n[1:0]@ at the IP boundary.
  -}
  , sibRd :: Bool
  {- ^ Read-strobe (active high). Wrapper produces @az_rd_n =
  ~(sibCs && sibRd)@.
  -}
  , sibWr :: Bool
  -- ^ Write-strobe (active high). Wrapper produces @az_wr_n@ similarly.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- | Slave-to-master reply from the IP. @zaData@ / @zaValid@ arrive
together on the cycle the IP completes a read; @zaWaitrequest@ is
high while the IP's input FIFO is full.
-}
data SdramIpReply = SdramIpReply
  { sirRdata :: BitVector 16
  , sirValid :: Bool
  , sirWaitrequest :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

-- * Adapter FSM -----------------------------------------------------

{- | Controller state. See module header for the cycle-level layout.

'SIdle' doubles as "no transaction" (when @selS@ is false) and
"first cycle of a new op" (when @selS@ is true). The first-cycle
pin-drive is read combinationally from @stateS@ + the incoming bus
signals — the same Mealy-ish trick 'Riski5.Sram' uses — so a new op
starts on the same cycle the core issues it, and only spends extra
cycles when the IP actually pushes back via @waitrequest@ or delays
@za_valid@.
-}
data SdramState
  = -- | Either no transaction or the first cycle of a new op.
    SIdle
  | -- | Holding @az_*@ for the lo half-word write; waiting for
    -- @!waitrequest@.
    SWriteLoReq
  | -- | Holding @az_*@ for the hi half-word write; waiting for
    -- @!waitrequest@.
    SWriteHiReq
  | -- | Holding @az_*@ for the lo half-word read; waiting for
    -- @!waitrequest@.
    SReadLoReq
  | -- | Request accepted; waiting for @za_valid@ with the lo half-word.
    SReadLoWait
  | -- | Holding @az_*@ for the hi half-word read; waiting for
    -- @!waitrequest@.
    SReadHiReq
  | -- | Request accepted; waiting for @za_valid@ with the hi half-word.
    SReadHiWait
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFDataX)

{- |
Width-adaptation FSM in front of the Altera SDRAM Controller IP.

See module header for the design notes. Interface mirrors
'Riski5.Sram.sram' on the core-facing leg so the same stall-based
bus decoder in 'Riski5.Soc' treats SRAM and SDRAM identically. The
IP-facing leg uses 'SdramIpBus' / 'SdramIpReply' rather than the
canonical 'Riski5.AvalonMm.AvalonMmBus' because the Avalon slave
here is 16-bit-data, not 32-bit; reusing 'AvalonMmBus' would
zero-pad the unused half and invite sign-off mistakes at the
wrapper boundary.
-}
sdram ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  -- | slave-select from the bus decoder
  Signal dom Bool ->
  -- | CPU byte address
  Signal dom (BitVector 32) ->
  -- | 32-bit write data
  Signal dom (BitVector 32) ->
  -- | byte-enable (nonzero on stores; zero on loads)
  Signal dom (BitVector 4) ->
  -- | read-enable (unused — "read" is inferred from @be == 0@)
  Signal dom Bool ->
  -- | slave → master reply from the IP (or 'sdramIpSim' in sim)
  Signal dom SdramIpReply ->
  -- | @(rdata, bus, ready)@
  ( Signal dom (BitVector 32)
  , Signal dom SdramIpBus
  , Signal dom Bool
  )
sdram selS addrS wdataS beS _renS replyS =
  (rdataS, busS, readyS)
 where
  waitS = sirWaitrequest <$> replyS
  validS = sirValid <$> replyS
  ipRdataS = sirRdata <$> replyS

  -- Decoded op shape — combinational from bus signals.
  isWriteS = (\be -> be /= 0) <$> beS
  loActiveS = (\be -> slice d1 d0 be /= 0) <$> beS
  hiActiveS = (\be -> slice d3 d2 be /= 0) <$> beS

  -- Word-aligned chip addresses (16-bit-word indices). @halfIdx@ is
  -- the 22-bit half-word index of the CPU's addressed 16-bit word;
  -- word_lo = half-word 2·N, word_hi = half-word 2·N + 1 of the
  -- surrounding 32-bit word N.
  halfIdxS = (\a -> slice d22 d1 (a - sdramBase)) <$> addrS
  wordLoAddrS = (\h -> h .&. complement 1) <$> halfIdxS
  wordHiAddrS = (\h -> h .|. 1) <$> halfIdxS

  -- FSM state register.
  stateS = register SIdle nextStateS
  nextStateS =
    nextState
      <$> stateS
      <*> selS
      <*> isWriteS
      <*> loActiveS
      <*> hiActiveS
      <*> waitS
      <*> validS

  -- Captured lo half-word. Latched on the cycle we leave
  -- 'SReadLoWait' with @valid=1@.
  loCaptureS = register 0 loCaptureNextS
  loCaptureNextS =
    ( \st valid dq old -> case st of
        SReadLoWait | valid -> dq
        _ -> old
    )
      <$> stateS
      <*> validS
      <*> ipRdataS
      <*> loCaptureS

  -- ready (Mealy).
  readyS =
    ready
      <$> stateS
      <*> selS
      <*> isWriteS
      <*> loActiveS
      <*> hiActiveS
      <*> waitS
      <*> validS

  -- Master-side Avalon-MM signals driven to the IP.
  busS =
    busFor
      <$> stateS
      <*> selS
      <*> isWriteS
      <*> loActiveS
      <*> hiActiveS
      <*> wordLoAddrS
      <*> wordHiAddrS
      <*> wdataS
      <*> beS

  -- Read data presented to the core. Only valid on the cycle
  -- readyS=True after a read; on all other cycles returns 0
  -- (readyS=False so the core ignores the value anyway).
  rdataS =
    rdata
      <$> stateS
      <*> validS
      <*> ipRdataS
      <*> loCaptureS

-- * FSM helpers ----------------------------------------------------

{- | Next-state transition. The @waitrequest@ / @valid@ inputs mean
request-cycle states (@SWriteLoReq@, @SReadHiReq@, …) advance only
when the IP acknowledges, and wait-cycle states
(@SReadLoWait@, @SReadHiWait@) advance only when @za_valid@ pulses
with the data.
-}
nextState ::
  SramOp
nextState SIdle False _ _ _ _ _ = SIdle
-- New op starting: pick the first sub-transaction. For writes,
-- skip the lo-half request entirely when @!loActive@ (SH / SB
-- targeting bytes 2-3). For reads we always fetch both halves —
-- matches 'Riski5.Sram' so LH / LB fall out of the core's load-mask.
nextState SIdle True True True _ _ _ = SWriteLoReq
nextState SIdle True True False True _ _ = SWriteHiReq
nextState SIdle True True False False _ _ = SIdle -- be = 0 with isWrite shouldn't happen
nextState SIdle True False _ _ _ _ = SReadLoReq
-- Lo-write request: advance when the IP accepts the transaction.
-- If we were also asked to write the hi half, chase it next;
-- otherwise the whole op is done.
nextState SWriteLoReq _ _ _ _ True _ = SWriteLoReq
nextState SWriteLoReq _ _ _ True False _ = SWriteHiReq
nextState SWriteLoReq _ _ _ False False _ = SIdle
-- Hi-write request: advance to idle once accepted.
nextState SWriteHiReq _ _ _ _ True _ = SWriteHiReq
nextState SWriteHiReq _ _ _ _ False _ = SIdle
-- Lo-read request accepted → wait for valid; otherwise stay.
nextState SReadLoReq _ _ _ _ True _ = SReadLoReq
nextState SReadLoReq _ _ _ _ False _ = SReadLoWait
-- Lo-read reply arrives → issue the hi-read request next.
nextState SReadLoWait _ _ _ _ _ False = SReadLoWait
nextState SReadLoWait _ _ _ _ _ True = SReadHiReq
-- Hi-read request accepted → wait for valid; otherwise stay.
nextState SReadHiReq _ _ _ _ True _ = SReadHiReq
nextState SReadHiReq _ _ _ _ False _ = SReadHiWait
-- Hi-read reply arrives → op done, fall back to idle.
nextState SReadHiWait _ _ _ _ _ False = SReadHiWait
nextState SReadHiWait _ _ _ _ _ True = SIdle

{- | @SramOp@ is a synonym for the @nextState@ signature — seven
arguments is long enough that a named type makes the pattern
matches above grep-able.
-}
type SramOp =
  SdramState ->
  -- | selS
  Bool ->
  -- | isWriteS
  Bool ->
  -- | loActiveS
  Bool ->
  -- | hiActiveS
  Bool ->
  -- | waitrequest
  Bool ->
  -- | valid
  Bool ->
  SdramState

{- | @readyS@ value for each state. True only on the last cycle of
an op (so the core unstalls on the correct edge).
-}
ready ::
  SdramState ->
  -- | selS
  Bool ->
  -- | isWriteS
  Bool ->
  -- | loActiveS
  Bool ->
  -- | hiActiveS
  Bool ->
  -- | waitrequest
  Bool ->
  -- | valid
  Bool ->
  Bool
ready SIdle sel _ _ _ _ _ = not sel
ready SWriteLoReq _ _ _ False False _ = True -- lo-write, no hi-half, just accepted
ready SWriteLoReq _ _ _ _ _ _ = False
ready SWriteHiReq _ _ _ _ False _ = True -- hi-write accepted
ready SWriteHiReq _ _ _ _ _ _ = False
ready SReadLoReq _ _ _ _ _ _ = False
ready SReadLoWait _ _ _ _ _ _ = False
ready SReadHiReq _ _ _ _ _ _ = False
ready SReadHiWait _ _ _ _ _ valid = valid -- final read reply

{- | Master-side bus this cycle. When idle-but-selected the FSM
drives the first sub-transaction's signals; otherwise the current
state picks the drive exactly.
-}
busFor ::
  SdramState ->
  -- | selS
  Bool ->
  -- | isWriteS
  Bool ->
  -- | loActiveS
  Bool ->
  -- | hiActiveS
  Bool ->
  -- | wordLoAddr
  BitVector 22 ->
  -- | wordHiAddr
  BitVector 22 ->
  -- | wdata
  BitVector 32 ->
  -- | be
  BitVector 4 ->
  SdramIpBus
busFor st _sel _isWrite _loActive _hiActive wLo wHi wdata be = case st of
  -- SIdle never drives a request: if we did, then on the next cycle
  -- we'd transition unconditionally to S*Req and re-drive the same
  -- signals, which — combined with the IP's single-shot input FIFO
  -- capture on @!waitrequest@ — would latch the same transaction
  -- twice. One extra cycle of latency per op avoids the hazard.
  -- The 'Riski5.Sram' FSM gets away with SIdle-drive because its
  -- async-SRAM interface has no FIFO and no backpressure path.
  SIdle -> idleBus
  SWriteLoReq -> writeBus wLo (slice d15 d0 wdata) (slice d1 d0 be)
  SWriteHiReq -> writeBus wHi (slice d31 d16 wdata) (slice d3 d2 be)
  SReadLoReq -> readBus wLo
  SReadLoWait -> idleBus
  SReadHiReq -> readBus wHi
  SReadHiWait -> idleBus

idleBus :: SdramIpBus
idleBus =
  SdramIpBus
    { sibCs = False
    , sibAddr = 0
    , sibWdata = 0
    , sibBe = 0
    , sibRd = False
    , sibWr = False
    }

writeBus :: BitVector 22 -> BitVector 16 -> BitVector 2 -> SdramIpBus
writeBus a d be =
  SdramIpBus
    { sibCs = True
    , sibAddr = a
    , sibWdata = d
    , sibBe = be
    , sibRd = False
    , sibWr = True
    }

readBus :: BitVector 22 -> SdramIpBus
readBus a =
  SdramIpBus
    { sibCs = True
    , sibAddr = a
    , sibWdata = 0
    , sibBe = 0b11 -- read both byte lanes; core masks later
    , sibRd = True
    , sibWr = False
    }

-- | Read data presented to the core. Combined from the captured lo
-- half plus the hi half arriving on @ipRdata@ this cycle.
rdata ::
  SdramState ->
  -- | valid
  Bool ->
  -- | ipRdata (this cycle)
  BitVector 16 ->
  -- | loCapture (previously latched lo half)
  BitVector 16 ->
  BitVector 32
rdata SReadHiWait True hi lo =
  (resize hi `shiftL` 16) .|. resize lo
rdata _ _ _ _ = 0

-- * Behavioural IP + chip model ------------------------------------

{- |
Simulation-only model of 'riski5_sdram' plus the physical chip
behind it. Absorbs Avalon-MM transactions and echoes reads back
with a fixed one-cycle latency. Skips the real IP's init delay,
refresh, and per-transaction scheduling — we're testing our
adapter FSM, not the controller itself.

Parameterised on the memory size in 16-bit words (@m@) so tests
can use a small store (16 Ki words = 32 KB) without materialising
the full 4 M × 16-bit physical address space in sim. The model
wraps around on @addr >= 2^ceilLog2(m)@ so out-of-bounds addresses
(unlikely in practice, but possible in randomised tests) don't
trip the simulator.
-}
sdramIpSim ::
  forall dom m.
  ( HiddenClockResetEnable dom
  , KnownNat m
  , 1 <= m
  ) =>
  -- | initial memory contents
  Vec m (BitVector 16) ->
  -- | master-side request from 'sdram'
  Signal dom SdramIpBus ->
  -- | slave-side reply
  Signal dom SdramIpReply
sdramIpSim initMem busS = replyS
 where
  -- Extract the fields from the incoming bus.
  csS = sibCs <$> busS
  addrS = sibAddr <$> busS
  wdataS = sibWdata <$> busS
  beS = sibBe <$> busS
  rdS = sibRd <$> busS
  wrS = sibWr <$> busS

  -- Accept the transaction this cycle (no waitrequest in sim).
  acceptWriteS = (&&) <$> csS <*> wrS
  acceptReadS = (&&) <$> csS <*> rdS

  idxS :: Signal dom (Index m)
  idxS = (\a -> fromInteger (fromIntegral a `mod` natVal (Proxy :: Proxy m))) <$> addrS

  -- Vec-backed memory with __async__ read. Matches 'Riski5.Bram''s
  -- pattern: the whole Vec lives in a register; reads mux into it
  -- combinationally; writes update the register on the next edge.
  -- The earlier version used 'Clash.Prelude.blockRam', whose
  -- one-cycle read latency meant the @readDataRawS@ fed into the
  -- byte-enable merge logic reflected @memory[idxS_{N-1}]@, not
  -- @memory[idxS_N]@. That's correct for the reply path (it
  -- matches the real IP's pipelined @za_valid@ delay), but wrong
  -- for the merge — a partial-byte SB at address A, landing on
  -- the cycle after a bus idle at address 0, would merge with
  -- @memory[0]@'s bytes instead of @memory[A]@'s. Cross-word
  -- contamination. Async-read makes the merge see the correct
  -- old value; the reply path adds its own register back for the
  -- 1-cycle valid latency.
  --
  -- The Vec register costs a lot of flip-flops in hardware but
  -- this is sim-only code. The real IP has internal DRAM arrays,
  -- not a Vec.
  memS :: Signal dom (Vec m (BitVector 16))
  memS = register initMem memNextS

  memNextS =
    ( \mem idx doWrite be new ->
        if doWrite && be /= 0
          then
            let old = mem CP.!! idx
                newLo =
                  if testBit be 0 then slice d7 d0 new else slice d7 d0 old
                newHi =
                  if testBit be 1 then slice d15 d8 new else slice d15 d8 old
                merged = newHi ++# newLo
             in replace idx merged mem
          else mem
    )
      <$> memS
      <*> idxS
      <*> acceptWriteS
      <*> beS
      <*> wdataS

  -- Current-cycle combinational read, then registered once to
  -- model the IP's pipelined response (za_valid arrives one cycle
  -- after the read request was accepted).
  currentReadS = (\mem idx -> mem CP.!! idx) <$> memS <*> idxS
  readDataS = register 0 currentReadS
  validS = register False acceptReadS
  replyS =
    ( \rd v ->
        SdramIpReply
          { sirRdata = rd
          , sirValid = v
          , sirWaitrequest = False
          }
    )
      <$> readDataS
      <*> validS
