-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

{- |
Module      : Riski5.JtagAvalonMaster
Description : Clash replacement for Altera's @altera_avalon_packets_to_master@.

The Altera @altera_jtag_avalon_master@ IP composes:

  altera_jtag_dc_streaming  →  timing_adapter  →  altera_avalon_sc_fifo
    →  altera_avalon_st_bytes_to_packets  →  channel_adapter
    →  altera_avalon_packets_to_master   ← (this module replaces it)
    →  channel_adapter                   →  altera_avalon_st_packets_to_bytes
    →  altera_jtag_dc_streaming  (return path)

The middle state machine — @altera_avalon_packets_to_master@ — randomly
drops 50–75 % of master writes during high-rate JTAG bursts (silicon-
verified by the L-3b sentinel test, see
@firmware\/phase1\/LinuxBootMaster.hs@). The bug is intrinsic to that
component (@altera_avalon_packets_to_master.v@ in the IP source); the
surrounding glue is sound.

This module reimplements the same packet protocol with the same
wire-level interface, but with no internal FIFOs and clean Clash
semantics. It is named @riski5_jtag_avalon_master@ in Verilog and
plugged in via a thin shim file
(@altera-ip\/jtag-master-shim\/altera_avalon_packets_to_master.v@) that
re-exposes it under the original Altera module name with the same
parameter list — so the rest of the IP composition (pulled in by
@ip-generate altera_jtag_avalon_master@) can stay unchanged.

Wire-level packet protocol (decoded from the Altera Verilog source):

  byte 0:  command (only the low byte;  0x00 = write non-incr,
                                          0x04 = write incr,
                                          0x10 = read  non-incr,
                                          0x14 = read  incr;
                                          others — NOP, command echoed)
  byte 1:  reserved (ignored)
  byte 2-3:size MSB then LSB     (only meaningful for reads)
  byte 4-7:address [31:24] [23:16] [15:8] [7:0]
  byte 8…N: write data (writes only) — flows until end-of-packet

For writes: response packet is SOP, (0x80|cmd), 0x00, count[15:8],
count[7:0] EOP.
For reads:  response packet is SOP, data[0], …, data[N-1] EOP.

The state machine matches the Altera "slow path" (FAST_VER=0 branch of
@altera_avalon_packets_to_master.v@).
-}
module Riski5.JtagAvalonMaster (
  -- * Clash entity
  jtagAvalonMaster,

  -- * Top entity (Verilog module @riski5_jtag_avalon_master@)
  topEntity,

  -- * Domain (40 MHz, async-reset, active-low)
  Dom30Jam,

  -- * Re-exported helpers (mainly for tests)
  InS (..),
  OutS (..),
  S (..),
  initS,
  step,
) where

import Clash.Annotations.TH (makeTopEntityWithName)
import Clash.Prelude hiding (not, (&&), (||))

createDomain
  vSystem
    { vName = "Dom30Jam"
    , vPeriod = 25000
    , vResetKind = Asynchronous
    , vResetPolarity = ActiveLow
    }

-- * State + IO records ------------------------------------------------

data Phase
  = PReady
  | PGetExtra
  | PGetSize1
  | PGetSize2
  | PGetAddr1
  | PGetAddr2
  | PGetAddr3
  | PGetAddr4
  | PGetWriteData
  | PWriteWait
  | PReadAssert
  | PReadCmdWait
  | PReadDataWait
  | PReadSendIssue
  | PReadSendWait
  | PReturnPacket
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFDataX)

data S = S
  { sPhase :: Phase
  , sCommand :: BitVector 8
  , sCounter :: BitVector 16
  , sAddr :: BitVector 32
  , sCurByte :: BitVector 2
  , sFirstTrans :: Bool
  , sLastTrans :: Bool
  , sWriteData :: BitVector 32
  , sByteEnable :: BitVector 4
  , sReadBuf :: BitVector 24
  , sOutData :: BitVector 8
  , sOutValid :: Bool
  , sOutSop :: Bool
  , sOutEop :: Bool
  , sRead :: Bool
  , sWrite :: Bool
  , sInReady :: Bool
  , -- | Diagnostics for task #133. Bytes accepted from the
    -- Avalon-ST input (in_ready && in_valid handshake) — every byte
    -- the host pushed through the bytes_to_packets layer that the
    -- FSM saw. Drops UPSTREAM of the FSM never increment this.
    sBytesIn :: BitVector 32
  , -- | Master-write transactions accepted by the slave (write was
    -- high && waitrequest dropped). Drops at the FSM input would
    -- show as @sBytesIn == bytes_sent_by_host@ but
    -- @sWritesCommit \\\< (bytes_sent / 4)@.
    sWritesCommit :: BitVector 32
  , -- | Master-read transactions accepted by the slave.
    sReadsCommit :: BitVector 32
  }
  deriving stock (Generic)
  deriving anyclass (NFDataX)

initS :: S
initS =
  S
    { sPhase = PReady
    , sCommand = 0
    , sCounter = 0
    , sAddr = 0
    , sCurByte = 0
    , sFirstTrans = False
    , sLastTrans = False
    , sWriteData = 0
    , sByteEnable = 0
    , sReadBuf = 0
    , sOutData = 0
    , sOutValid = False
    , sOutSop = False
    , sOutEop = False
    , sRead = False
    , sWrite = False
    , sInReady = False
    , sBytesIn = 0
    , sWritesCommit = 0
    , sReadsCommit = 0
    }

data InS = InS
  { iInValid :: Bool
  , iInData :: BitVector 8
  , iInSop :: Bool
  , iInEop :: Bool
  , iOutReady :: Bool
  , iReaddata :: BitVector 32
  , iWaitreq :: Bool
  , iReaddataVld :: Bool
  }
  deriving stock (Generic)
  deriving anyclass (NFDataX)

data OutS = OutS
  { oInReady :: Bool
  , oAddress :: BitVector 32
  , oRead :: Bool
  , oWrite :: Bool
  , oByteEnable :: BitVector 4
  , oWriteData :: BitVector 32
  , oOutValid :: Bool
  , oOutData :: BitVector 8
  , oOutSop :: Bool
  , oOutEop :: Bool
  , oBytesIn :: BitVector 32
  , oWritesCommit :: BitVector 32
  , oReadsCommit :: BitVector 32
  }
  deriving stock (Generic)
  deriving anyclass (NFDataX)

-- * Transition function -----------------------------------------------

cmdWriteNonIncr, cmdWriteIncr, cmdReadNonIncr, cmdReadIncr :: BitVector 8
cmdWriteNonIncr = 0x00
cmdWriteIncr = 0x04
cmdReadNonIncr = 0x10
cmdReadIncr = 0x14

isWriteCmd :: BitVector 8 -> Bool
isWriteCmd c = c == cmdWriteNonIncr || c == cmdWriteIncr

isReadCmd :: BitVector 8 -> Bool
isReadCmd c = c == cmdReadNonIncr || c == cmdReadIncr

-- | command[2] toggles INCR vs NON_INCR.
isIncr :: BitVector 8 -> Bool
isIncr c = testBit c 2

-- | First-byte byte-enable for a multi-byte read, given remaining bytes.
unshiftedBe :: BitVector 16 -> BitVector 4
unshiftedBe c
  | c >= 4 = 0b1111
  | c == 3 = 0b0111
  | c == 2 = 0b0011
  | c == 1 = 0b0001
  | otherwise = 0

-- | Patch byte @cb@ of a 32-bit word.
setByte :: BitVector 32 -> BitVector 2 -> BitVector 8 -> BitVector 32
setByte w cb b = case cb of
  0 -> (w .&. 0xFFFF_FF00) .|. resize b
  1 -> (w .&. 0xFFFF_00FF) .|. (resize b `shiftL` 8)
  2 -> (w .&. 0xFF00_FFFF) .|. (resize b `shiftL` 16)
  _ -> (w .&. 0x00FF_FFFF) .|. (resize b `shiftL` 24)

setBe :: BitVector 4 -> BitVector 2 -> BitVector 4
setBe be cb = case cb of
  0 -> be .|. 0b0001
  1 -> be .|. 0b0010
  2 -> be .|. 0b0100
  _ -> be .|. 0b1000

-- | Top-of-cycle preamble.
preamble :: S -> Bool -> S
preamble s outReady =
  s
    { sAddr = sAddr s .&. 0xFFFF_FFFC
    , sOutValid = if outReady then False else sOutValid s
    , sOutSop = if outReady then False else sOutSop s
    , sOutEop = if outReady then False else sOutEop s
    , sInReady = False
    }

-- | Advance the FSM one clock — Clash mealy-style transition.
step :: S -> InS -> S
step sOld i = sWithCounters
 where
  enable = sInReady sOld && iInValid i
  sBase = preamble sOld (iOutReady i)
  sCase = caseStep sOld sBase i enable
  sFinal = sopOverride sOld sCase i enable
  -- | Diagnostic counters (task #133). Each is incremented on the
  -- clock the corresponding event is observed. @sBytesIn@ rises
  -- whenever a byte handshake completes at the Avalon-ST input;
  -- @sWritesCommit@ rises on the cycle the slave accepts a write
  -- (waitrequest drops while @sWrite@ is high); same for reads.
  acceptedWrite = sWrite sOld && not (iWaitreq i)
  acceptedRead = sRead sOld && (iReaddataVld i || not (iWaitreq i))
  sWithCounters =
    sFinal
      { sBytesIn = sBytesIn sOld + (if enable then 1 else 0)
      , sWritesCommit = sWritesCommit sOld + (if acceptedWrite then 1 else 0)
      , sReadsCommit = sReadsCommit sOld + (if acceptedRead then 1 else 0)
      }

-- | If a SOP arrives during ANY state, force the FSM to GetExtra.
sopOverride :: S -> S -> InS -> Bool -> S
sopOverride _ sNext i enable
  | enable && iInSop i =
      sNext
        { sPhase = PGetExtra
        , sCommand = iInData i
        , sInReady = True
        }
  | otherwise = sNext

-- | Per-state transition.
caseStep :: S -> S -> InS -> Bool -> S
caseStep sOld sBase i enable = case sPhase sOld of
  PReady ->
    sBase
      { sOutValid = False
      , sInReady = True
      }
  PGetExtra ->
    sBase
      { sInReady = True
      , sByteEnable = 0
      , sPhase = if enable then PGetSize1 else sPhase sOld
      }
  PGetSize1 ->
    sBase
      { sInReady = True
      , sCounter =
          if enable
            then
              (sCounter sBase .&. 0x00FF)
                .|. (resize (if testBit (sCommand sOld) 4 then iInData i else 0) `shiftL` 8)
            else sCounter sBase
      , sPhase = if enable then PGetSize2 else sPhase sOld
      }
  PGetSize2 ->
    sBase
      { sInReady = True
      , sCounter =
          if enable
            then
              (sCounter sBase .&. 0xFF00)
                .|. resize (if testBit (sCommand sOld) 4 then iInData i else 0)
            else sCounter sBase
      , sPhase = if enable then PGetAddr1 else sPhase sOld
      }
  PGetAddr1 ->
    sBase
      { sInReady = True
      , sFirstTrans = True
      , sLastTrans = False
      , sAddr = (sAddr sBase .&. 0x00FF_FFFF) .|. (resize (iInData i) `shiftL` 24)
      , sPhase = if enable then PGetAddr2 else sPhase sOld
      }
  PGetAddr2 ->
    sBase
      { sInReady = True
      , sAddr = (sAddr sBase .&. 0xFF00_FFFF) .|. (resize (iInData i) `shiftL` 16)
      , sPhase = if enable then PGetAddr3 else sPhase sOld
      }
  PGetAddr3 ->
    sBase
      { sInReady = True
      , sAddr = (sAddr sBase .&. 0xFFFF_00FF) .|. (resize (iInData i) `shiftL` 8)
      , sPhase = if enable then PGetAddr4 else sPhase sOld
      }
  PGetAddr4 ->
    let
      newAddr = (sAddr sBase .&. 0xFFFF_FF00) .|. (resize (iInData i .&. 0xFC))
      newCB = unpack (slice d1 d0 (iInData i)) :: BitVector 2
      cmd = sCommand sOld
     in
      if not enable
        then
          sBase
            { sInReady = True
            , sAddr = newAddr
            , sCurByte = newCB
            , sPhase = sPhase sOld
            }
        else
          if isWriteCmd cmd
            then
              sBase
                { sInReady = True
                , sAddr = newAddr
                , sCurByte = newCB
                , sPhase = PGetWriteData
                }
            else
              if isReadCmd cmd
                then
                  sBase
                    { sInReady = False
                    , sAddr = newAddr
                    , sCurByte = newCB
                    , sPhase = PReadAssert
                    }
                else
                  sBase -- NOP / unrecognized
                    { sInReady = False
                    , sAddr = newAddr
                    , sCurByte = 0
                    , sPhase = PReturnPacket
                    , sOutValid = True
                    , sOutSop = True
                    , sOutData = 0x80 .|. cmd
                    }
  PGetWriteData ->
    let
      cb = sCurByte sOld
      newWData =
        if enable
          then setByte (sWriteData sBase) cb (iInData i)
          else sWriteData sBase
      newBe =
        if enable
          then setBe (sByteEnable sBase) cb
          else sByteEnable sBase
      commit = enable && (iInEop i || cb == 3)
      newCB = if enable then cb + 1 else cb
      newCnt = if enable then sCounter sBase + 1 else sCounter sBase
     in
      sBase
        { sInReady = not commit
        , sWriteData = newWData
        , sByteEnable = newBe
        , sCurByte = newCB
        , sCounter = newCnt
        , sLastTrans = sLastTrans sOld || (enable && iInEop i)
        , sWrite = if commit then True else sWrite sBase
        , sPhase = if commit then PWriteWait else sPhase sOld
        }
  PWriteWait ->
    let
      accepted = not (iWaitreq i)
      cmd = sCommand sOld
      newAddr =
        if accepted && isIncr cmd
          then sAddr sBase + 4
          else sAddr sBase
     in
      if accepted
        then
          if sLastTrans sOld
            then
              sBase
                { sInReady = False
                , sWrite = False
                , sAddr = newAddr
                , sByteEnable = 0
                , sPhase = PReturnPacket
                , sOutValid = True
                , sOutSop = True
                , sOutData = 0x80 .|. cmd
                , sCurByte = 0
                }
            else
              sBase
                { sInReady = True
                , sWrite = False
                , sAddr = newAddr
                , sByteEnable = 0
                , sPhase = PGetWriteData
                }
        else
          sBase
            { sInReady = False
            , sWrite = True
            , sPhase = sPhase sOld
            }
  PReadAssert ->
    let
      cb = sCurByte sOld
      ube = unshiftedBe (sCounter sOld)
      be = case cb of
        0 -> ube
        1 -> ube `shiftL` 1
        2 -> ube `shiftL` 2
        _ -> ube `shiftL` 3
     in
      sBase
        { sByteEnable = be
        , sRead = True
        , sPhase = PReadCmdWait
        }
  PReadCmdWait ->
    let
      rd = iReaddata i
      rb = slice d31 d8 rd
      lo8 = slice d7 d0 rd
     in
      if iReaddataVld i
        then
          sBase
            { sReadBuf = rb
            , sOutData = lo8
            , sRead = False
            , sPhase = PReadSendIssue
            }
        else
          if not (iWaitreq i)
            then
              sBase
                { sReadBuf = rb
                , sOutData = lo8
                , sRead = False
                , sPhase = PReadDataWait
                }
            else
              sBase
                { sReadBuf = rb
                , sOutData = lo8
                , sRead = True
                , sPhase = sPhase sOld
                }
  PReadDataWait ->
    let
      rd = iReaddata i
      rb = slice d31 d8 rd
      lo8 = slice d7 d0 rd
     in
      if iReaddataVld i
        then
          sBase
            { sReadBuf = rb
            , sOutData = lo8
            , sPhase = PReadSendIssue
            }
        else
          sBase
            { sReadBuf = rb
            , sOutData = lo8
            , sPhase = sPhase sOld
            }
  PReadSendIssue ->
    let
      cnt = sCounter sOld
      cb = sCurByte sOld
      rb = sReadBuf sOld
      sendData = case cb of
        3 -> slice d23 d16 rb
        2 -> slice d15 d8 rb
        1 -> slice d7 d0 rb
        _ -> sOutData sBase
      sop = sFirstTrans sOld
      eop = cnt == 1
     in
      sBase
        { sOutValid = True
        , sOutSop = sop
        , sOutEop = eop
        , sOutData = sendData
        , sFirstTrans = if sop then False else sFirstTrans sOld
        , sPhase = PReadSendWait
        }
  PReadSendWait ->
    if iOutReady i
      then
        let
          newCnt = sCounter sBase - 1
          newCB = sCurByte sOld + 1
          done = sCounter sOld == 1
          wordEnd = sCurByte sOld == 3
          newAddr =
            if wordEnd && isIncr (sCommand sOld)
              then sAddr sBase + 4
              else sAddr sBase
         in
          sBase
            { sCounter = newCnt
            , sCurByte = newCB
            , sOutValid = False
            , sAddr = newAddr
            , sPhase =
                if done
                  then PReady
                  else
                    if wordEnd
                      then PReadAssert
                      else PReadSendIssue
            }
      else
        sBase
          { sOutValid = True
          , sPhase = sPhase sOld
          }
  PReturnPacket ->
    let cb = sCurByte sOld
     in if iOutReady i
          then case cb of
            0 ->
              sBase
                { sOutValid = True
                , sOutData = 0
                , sCurByte = cb + 1
                , sPhase = PReturnPacket
                }
            1 ->
              sBase
                { sOutValid = True
                , sOutData = slice d15 d8 (sCounter sOld)
                , sCurByte = cb + 1
                , sPhase = PReturnPacket
                }
            2 ->
              sBase
                { sOutValid = True
                , sOutEop = True
                , sOutData = slice d7 d0 (sCounter sOld)
                , sCurByte = cb + 1
                , sPhase = PReturnPacket
                }
            _ ->
              sBase
                { sOutValid = False
                , sCurByte = cb + 1
                , sPhase = PReady
                }
          else
            sBase
              { sOutValid = True
              , sPhase = sPhase sOld
              }

-- * Wiring -------------------------------------------------------------

outOf :: S -> OutS
outOf s =
  OutS
    { oInReady = sInReady s
    , oAddress = sAddr s
    , oRead = sRead s
    , oWrite = sWrite s
    , oByteEnable = sByteEnable s
    , oWriteData = sWriteData s
    , oOutValid = sOutValid s
    , oOutData = sOutData s
    , oOutSop = sOutSop s
    , oOutEop = sOutEop s
    , oBytesIn = sBytesIn s
    , oWritesCommit = sWritesCommit s
    , oReadsCommit = sReadsCommit s
    }

-- | Domain-polymorphic FSM. Outputs are registered (Moore-style).
jtagAvalonMaster ::
  forall dom.
  HiddenClockResetEnable dom =>
  Signal dom InS ->
  Signal dom OutS
jtagAvalonMaster = moore step outOf initS

-- * Top entity (Verilog module @riski5_jtag_avalon_master@) -----------

-- | Drop-in replacement for @altera_avalon_packets_to_master@. Exposed
-- under a unique name; a thin Verilog shim re-exports it under the
-- original Altera module name with the parameters the IP composition
-- needs to override (@FAST_VER@, @FIFO_DEPTHS@, …).
topEntity ::
  "clk" ::: Clock Dom30Jam ->
  "reset_n" ::: Reset Dom30Jam ->
  "in_valid" ::: Signal Dom30Jam Bool ->
  "in_data" ::: Signal Dom30Jam (BitVector 8) ->
  "in_startofpacket" ::: Signal Dom30Jam Bool ->
  "in_endofpacket" ::: Signal Dom30Jam Bool ->
  "out_ready" ::: Signal Dom30Jam Bool ->
  "readdata" ::: Signal Dom30Jam (BitVector 32) ->
  "waitrequest" ::: Signal Dom30Jam Bool ->
  "readdatavalid" ::: Signal Dom30Jam Bool ->
  ( "in_ready" ::: Signal Dom30Jam Bool
  , "out_valid" ::: Signal Dom30Jam Bool
  , "out_data" ::: Signal Dom30Jam (BitVector 8)
  , "out_startofpacket" ::: Signal Dom30Jam Bool
  , "out_endofpacket" ::: Signal Dom30Jam Bool
  , "address" ::: Signal Dom30Jam (BitVector 32)
  , "read" ::: Signal Dom30Jam Bool
  , "write" ::: Signal Dom30Jam Bool
  , "byteenable" ::: Signal Dom30Jam (BitVector 4)
  , "writedata" ::: Signal Dom30Jam (BitVector 32)
  , "bytes_in_cnt" ::: Signal Dom30Jam (BitVector 32)
  , "writes_commit_cnt" ::: Signal Dom30Jam (BitVector 32)
  , "reads_commit_cnt" ::: Signal Dom30Jam (BitVector 32)
  )
topEntity clk rstN inValidS inDataS inSopS inEopS outReadyS readdataS waitreqS readvldS =
  withClockResetEnable clk rstN enableGen $
    let
      inS =
        InS
          <$> inValidS
          <*> inDataS
          <*> inSopS
          <*> inEopS
          <*> outReadyS
          <*> readdataS
          <*> waitreqS
          <*> readvldS
      outS = jtagAvalonMaster inS
     in
      ( oInReady <$> outS
      , oOutValid <$> outS
      , oOutData <$> outS
      , oOutSop <$> outS
      , oOutEop <$> outS
      , oAddress <$> outS
      , oRead <$> outS
      , oWrite <$> outS
      , oByteEnable <$> outS
      , oWriteData <$> outS
      , oBytesIn <$> outS
      , oWritesCommit <$> outS
      , oReadsCommit <$> outS
      )

makeTopEntityWithName 'topEntity "riski5_jtag_avalon_master"
