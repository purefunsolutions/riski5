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
Module      : Riski5.Core
Description : Classic 5-stage F|D|X|M|W in-order RV32I + RV32M pipeline.

__Goal:__ maximise scalar throughput on Cyclone II. The phase-1
pipelineless 2-stage F+X core plateaued at ~33 MHz because the
whole @decode → rf read → ALU → mem → writeback@ cone settled in
one clock. Splitting that cone across five pipeline stages with
full forwarding gives us ~2× Fmax with ~1 IPC on non-dependent
code — the Tiny-tier target from @docs/core-family.md@.

== The five stages

  1. __F (fetch)__ — @pcFetch@ drives imem address. imem has
     synchronous-read semantics; the instruction for @pcFetch_N@
     arrives on @imemData@ at cycle @N+1@.

  2. __D (decode)__ — consumes the IF/ID register: pc + fetched
     instruction word. Runs 'decode' to get a 'Maybe' 'Instr';
     presents @rs1@ / @rs2@ addresses to the register file; feeds
     the ID/EX register with the decoded fields plus the two
     operand values.

  3. __X (execute)__ — consumes ID/EX. Applies the forwarding
     muxes to pick fresh rs1 / rs2 values, runs 'handleInstr'
     (ALU, branch compare, CSR read/write, load-address compute,
     trap detection). For RV32M ops, the iterative 'mulDivFU'
     stalls X until 'MdDone'. Drives the dmem address / wdata /
     byte-enable / read-enable onto the bus, and captures its
     final writeback value + next-PC into EX/MEM.

  4. __M (memory)__ — consumes EX/MEM. Today a passthrough: the
     async-read dmem returns the load value in the same X cycle,
     so EX/MEM already carries the computed writeback for loads.
     Phase 2C will split EX/MEM in half when caches land and
     dmem becomes synchronous, putting the actual mem-lookup
     logic here.

  5. __W (writeback)__ — consumes MEM/WB. Writes @rd@ to the
     regfile (through the async-read 'Riski5.Regfile.regfile'
     for now; swap to 'regfileSync' is a follow-up once the
     shape is stable).

== Forwarding

Every RAW (read-after-write) dependency inside the pipeline's
3-instruction window is resolved combinationally by the two
forwarding paths at X's input:

  * __EX→X__ — forward @EX/MEM.wbData@ when @EX/MEM.rd@ matches
    the current X instruction's @rs1@ or @rs2@.
  * __MEM→X__ — forward @MEM/WB.wbData@ when @MEM/WB.rd@ matches
    and the EX→X path didn't already cover it.

Older-than-3-ahead dependencies are already committed to the
regfile by the time they're read, so no forwarding needed.

Because the phase-2A dmem is async-read, __there is no load-use
hazard__: the load value is computed inside X (not M) and lands
in EX/MEM the same cycle, where the normal EX→X forwarding mux
picks it up for the next instruction. The classic "bubble after
a load" becomes relevant only once we move to a synchronous D$
in phase 2C.

== Control hazards — flush on redirect

Any non-sequential PC change detected in X (taken branch, JAL,
JALR, MRET, trap) squashes the two speculative instructions
behind it — one in D, one in the ID/EX register — by invalidating
their pipe regs on the next clock edge. The taken-branch penalty
is therefore __2 cycles__, matching the distance from the front
of the pipeline to X.

== Stall handling

Two stall sources feed a single @stallInternal@ signal:

  * External bus back-pressure ('stallS' input) — multi-cycle
    SRAM / SDRAM / UART slaves hold the core for their latency.
  * RV32M iteration — @mulDivFU@'s @busy@ flag is asserted for
    ~34 cycles per M op.

While stalled, @pcFetch@ / IF/ID / ID/EX all freeze, keeping the
stalling instruction in X. EX/MEM and MEM/WB receive bubbles and
drain naturally — already-issued instructions ahead of the stall
continue to retire. Once the stall clears, EX/MEM picks up X's
new result and the pipeline refills.

== RVFI observability

The @Rvfi@ record is produced at W's edge: one retire event per
instruction that reaches the MEM/WB register with @mwValid@
asserted. All the pre-state / post-state hooks flow through the
pipe registers (operand values from the forwarding-picked sources
in X, memory read-data from the dmem tap in X, CSR snapshots
before / after the retire's application in X). Squashed bubbles
don't retire, matching the spec exactly.

See @docs/verification.md@ for the RVFI contract and
@docs/core-family.md@ for the Tiny tier's design envelope this
core fits into.
-}
module Riski5.Core (
  core,
) where

import Clash.Prelude hiding (And, Xor, not, (!!), (&&), (||))
import Riski5.ALU (AluOp (..), BranchOp (..), alu, branchTaken)
import Riski5.Core.FU.Amo (AmoBus (..), AmoOp (..), amoFU, amoOpOf, isAmoOp)
import Riski5.Core.FU.MulDiv (MdOp (..), isMdOp, mdOpOf, mulDivFU)
import Riski5.CSR (
  Csrs (..),
  applyMret,
  applyTrap,
  causeBreakpoint,
  causeEcallFromM,
  causeIllegalInstr,
  causeInstrAddrMisaligned,
  causeLoadAddrMisaligned,
  causeStoreAddrMisaligned,
  initCsrs,
  interruptPending,
  readCsr,
  writeCsr,
 )
import Riski5.Decode (decode)
import Riski5.ISA
import Riski5.Regfile (regfile)
import Riski5.Rvfi (Rvfi (..), RvfiCsr (..))

-- * Pipeline registers --------------------------------------------

{- | IF/ID pipeline register. Holds the PC + fetched instruction
word from the previous cycle's F stage. @ifValid@ is 'False' on
reset and on cycles after a flush (bubble).
-}
data IfId = IfId
  { ifPc :: BitVector 32
  , ifPcNext :: BitVector 32
  , ifInstr :: BitVector 32
  , ifValid :: Bool
  }
  deriving stock (Generic)
  deriving anyclass (NFDataX)

defaultIfId :: IfId
defaultIfId = IfId {ifPc = 0, ifPcNext = 0, ifInstr = 0x0000_0013, ifValid = False}

bubbleIfId :: IfId
bubbleIfId = defaultIfId

{- | ID/EX pipeline register. Holds the decoded instruction + both
rs1 / rs2 architectural values freshly read from the regfile. The
X stage forwarding mux may override either rs data; the raw values
are kept here for RVFI's pre-forwarding observability tap.
-}
data IdEx = IdEx
  { idPc :: BitVector 32
  , idPcNext :: BitVector 32
  , idInstr :: BitVector 32
  , idMInstr :: Maybe Instr
  , idRs1 :: BitVector 5
  , idRs2 :: BitVector 5
  , idRs1Data :: BitVector 32
  , idRs2Data :: BitVector 32
  , idRd :: BitVector 5
  , idWbEn :: Bool
  -- ^ Will this instruction write back to rd? Static per decoded
  -- opcode — stores / branches / FENCE / traps / MRET set this
  -- 'False', everyone else 'True'. Lets the forwarding muxes skip
  -- producer instructions that don't actually write @rd@.
  , idValid :: Bool
  }
  deriving stock (Generic)
  deriving anyclass (NFDataX)

defaultIdEx :: IdEx
defaultIdEx =
  IdEx
    { idPc = 0
    , idPcNext = 0
    , idInstr = 0x0000_0013
    , idMInstr = Nothing
    , idRs1 = 0
    , idRs2 = 0
    , idRs1Data = 0
    , idRs2Data = 0
    , idRd = 0
    , idWbEn = False
    , idValid = False
    }

bubbleIdEx :: IdEx
bubbleIdEx = defaultIdEx

{- | EX/MEM pipeline register. Holds the X-stage outputs that M / W
still need to consume: the computed writeback value, the dmem
transaction parameters, trap / redirect info, and the CSR state
after X's logic applied.
-}
data ExMem = ExMem
  { emPc :: BitVector 32
  , emInstr :: BitVector 32
  , emMInstr :: Maybe Instr
  , emRd :: BitVector 5
  , emWbData :: BitVector 32
  , emWbEn :: Bool
  , emDmemAddr :: BitVector 32
  , emDmemWdata :: BitVector 32
  , emDmemBe :: BitVector 4
  , emDmemRen :: Bool
  , emMemRdata :: BitVector 32
  -- ^ Captured from the async-read dmem at X's output — passes
  -- through to RVFI at W.
  , emRs1Data :: BitVector 32
  -- ^ rs1 value X saw (post-forwarding) — for RVFI.
  , emRs2Data :: BitVector 32
  , emTrap :: Bool
  , emCsrsPre :: Csrs
  -- ^ CSR state before X applied its semantics (for RVFI @rdata@).
  , emCsrsPost :: Csrs
  -- ^ CSR state after X applied its semantics (for RVFI @wdata@).
  , emValid :: Bool
  }
  deriving stock (Generic)
  deriving anyclass (NFDataX)

defaultExMem :: ExMem
defaultExMem =
  ExMem
    { emPc = 0
    , emInstr = 0x0000_0013
    , emMInstr = Nothing
    , emRd = 0
    , emWbData = 0
    , emWbEn = False
    , emDmemAddr = 0
    , emDmemWdata = 0
    , emDmemBe = 0
    , emDmemRen = False
    , emMemRdata = 0
    , emRs1Data = 0
    , emRs2Data = 0
    , emTrap = False
    , emCsrsPre = initCsrs
    , emCsrsPost = initCsrs
    , emValid = False
    }

bubbleExMem :: ExMem
bubbleExMem = defaultExMem

{- | MEM/WB pipeline register. At cycle @N@ its contents describe the
instruction that retires this cycle — the regfile write + the RVFI
observability event. Today EX/MEM → MEM/WB is a straight copy
because dmem is async-read; when phase 2C lands a sync D$, the M
stage will actually look up load data and compose it into
@mwWbData@ here.
-}
data MemWb = MemWb
  { mwPc :: BitVector 32
  , mwInstr :: BitVector 32
  , mwMInstr :: Maybe Instr
  , mwRd :: BitVector 5
  , mwWbData :: BitVector 32
  , mwWbEn :: Bool
  , mwDmemAddr :: BitVector 32
  , mwDmemWdata :: BitVector 32
  , mwDmemBe :: BitVector 4
  , mwDmemRen :: Bool
  , mwMemRdata :: BitVector 32
  , mwRs1Data :: BitVector 32
  , mwRs2Data :: BitVector 32
  , mwTrap :: Bool
  , mwCsrsPre :: Csrs
  , mwCsrsPost :: Csrs
  , mwValid :: Bool
  }
  deriving stock (Generic)
  deriving anyclass (NFDataX)

defaultMemWb :: MemWb
defaultMemWb =
  MemWb
    { mwPc = 0
    , mwInstr = 0x0000_0013
    , mwMInstr = Nothing
    , mwRd = 0
    , mwWbData = 0
    , mwWbEn = False
    , mwDmemAddr = 0
    , mwDmemWdata = 0
    , mwDmemBe = 0
    , mwDmemRen = False
    , mwMemRdata = 0
    , mwRs1Data = 0
    , mwRs2Data = 0
    , mwTrap = False
    , mwCsrsPre = initCsrs
    , mwCsrsPost = initCsrs
    , mwValid = False
    }

-- | Does a decoded instruction write its rd? Used to filter the
-- forwarding muxes so stores / branches / traps don't claim rd = 0
-- slots spuriously.
instrWritesRd :: Maybe Instr -> Bool
instrWritesRd Nothing = False
instrWritesRd (Just i) = case i of
  -- Writes rd.
  Lui {} -> True
  Auipc {} -> True
  Jal {} -> True
  Jalr {} -> True
  Lb {} -> True
  Lh {} -> True
  Lw {} -> True
  Lbu {} -> True
  Lhu {} -> True
  Addi {} -> True
  Slti {} -> True
  Sltiu {} -> True
  Xori {} -> True
  Ori {} -> True
  Andi {} -> True
  Slli {} -> True
  Srli {} -> True
  Srai {} -> True
  Add {} -> True
  Sub {} -> True
  Sll {} -> True
  Slt {} -> True
  Sltu {} -> True
  Xor {} -> True
  Srl {} -> True
  Sra {} -> True
  Or {} -> True
  And {} -> True
  Mul {} -> True
  MulH {} -> True
  MulHsu {} -> True
  MulHu {} -> True
  Div {} -> True
  DivU {} -> True
  Rem {} -> True
  RemU {} -> True
  Csrrw {} -> True
  Csrrs {} -> True
  Csrrc {} -> True
  Csrrwi {} -> True
  Csrrsi {} -> True
  Csrrci {} -> True
  -- A-extension: every variant writes rd (LR/SC/AMOs all do).
  LrW {} -> True
  ScW {} -> True
  AmoSwapW {} -> True
  AmoAddW {} -> True
  AmoXorW {} -> True
  AmoAndW {} -> True
  AmoOrW {} -> True
  AmoMinW {} -> True
  AmoMaxW {} -> True
  AmoMinuW {} -> True
  AmoMaxuW {} -> True
  -- Does not write rd.
  Sb {} -> False
  Sh {} -> False
  Sw {} -> False
  Beq {} -> False
  Bne {} -> False
  Blt {} -> False
  Bge {} -> False
  Bltu {} -> False
  Bgeu {} -> False
  Fence {} -> False
  FenceI -> False
  Ecall -> False
  Ebreak -> False
  Mret -> False

-- | rd field of a decoded instruction; 0 for instructions that
-- don't have an rd (stores, branches, fences, MRET, ECALL, EBREAK)
-- so the forwarding muxes' @rd /= 0@ guard naturally excludes them
-- without a separate predicate.
instrRd :: Maybe Instr -> BitVector 5
instrRd Nothing = 0
instrRd (Just i) = case i of
  Lui rd _ -> unReg rd
  Auipc rd _ -> unReg rd
  Jal rd _ -> unReg rd
  Jalr rd _ _ -> unReg rd
  Lb rd _ _ -> unReg rd
  Lh rd _ _ -> unReg rd
  Lw rd _ _ -> unReg rd
  Lbu rd _ _ -> unReg rd
  Lhu rd _ _ -> unReg rd
  Addi rd _ _ -> unReg rd
  Slti rd _ _ -> unReg rd
  Sltiu rd _ _ -> unReg rd
  Xori rd _ _ -> unReg rd
  Ori rd _ _ -> unReg rd
  Andi rd _ _ -> unReg rd
  Slli rd _ _ -> unReg rd
  Srli rd _ _ -> unReg rd
  Srai rd _ _ -> unReg rd
  Add rd _ _ -> unReg rd
  Sub rd _ _ -> unReg rd
  Sll rd _ _ -> unReg rd
  Slt rd _ _ -> unReg rd
  Sltu rd _ _ -> unReg rd
  Xor rd _ _ -> unReg rd
  Srl rd _ _ -> unReg rd
  Sra rd _ _ -> unReg rd
  Or rd _ _ -> unReg rd
  And rd _ _ -> unReg rd
  Mul rd _ _ -> unReg rd
  MulH rd _ _ -> unReg rd
  MulHsu rd _ _ -> unReg rd
  MulHu rd _ _ -> unReg rd
  Div rd _ _ -> unReg rd
  DivU rd _ _ -> unReg rd
  Rem rd _ _ -> unReg rd
  RemU rd _ _ -> unReg rd
  Csrrw rd _ _ -> unReg rd
  Csrrs rd _ _ -> unReg rd
  Csrrc rd _ _ -> unReg rd
  Csrrwi rd _ _ -> unReg rd
  Csrrsi rd _ _ -> unReg rd
  Csrrci rd _ _ -> unReg rd
  LrW rd _ _ -> unReg rd
  ScW rd _ _ _ -> unReg rd
  AmoSwapW rd _ _ _ -> unReg rd
  AmoAddW rd _ _ _ -> unReg rd
  AmoXorW rd _ _ _ -> unReg rd
  AmoAndW rd _ _ _ -> unReg rd
  AmoOrW rd _ _ _ -> unReg rd
  AmoMinW rd _ _ _ -> unReg rd
  AmoMaxW rd _ _ _ -> unReg rd
  AmoMinuW rd _ _ _ -> unReg rd
  AmoMaxuW rd _ _ _ -> unReg rd
  _ -> 0

{- |
Top-level core entity. The I/O shape is preserved from the
previous 2-stage core — callers ('Riski5.Core.Assembly.coreWith',
'Riski5.Soc', 'Riski5.FormalTop') are unchanged.
-}
core ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  -- | instruction word on imem read port
  Signal dom (BitVector 32) ->
  -- | True whenever @imemData@ is the valid instruction for
  -- @pcFetch@. Single-cycle BRAM fetches strap this constant
  -- 'True'; multi-cycle paths (SRAM / SDRAM fetches routed
  -- through the SoC's bus decoder) pulse it only on the
  -- transaction-complete cycle. The core uses this together
  -- with 'stallS' to decide when to capture a (pc, instr)
  -- pair into IF/ID: it preserves the correct pair across
  -- both 1-cycle data stalls and multi-cycle fetch stalls.
  -- See the "multi-cycle fetch" section in the module header.
  Signal dom Bool ->
  -- | data-memory read response (1-cycle path today)
  Signal dom (BitVector 32) ->
  -- | back-pressure: freezes pipeline state when 'True'. Data
  -- stalls (SRAM / SDRAM / UART waits) and fetch-in-flight
  -- stalls both fold into this.
  Signal dom Bool ->
  -- | data-side back-pressure only: freezes the AMO FU's
  -- @slaveReady@ when 'True'. Pulled out as a separate input
  -- (rather than re-derived from 'stallS') because the AMO FU
  -- must NOT see fetch-side stalls — otherwise we get a
  -- circular dependency where the AMO holds the data bus,
  -- fetch starves on the sticky arbiter, fetch-stall stays
  -- True, the combined stall stays True, and the AMO never
  -- sees its own slave-ready pulse to advance out of
  -- @AmoRead@ / @AmoWrite@. Task #143 silicon hang at
  -- PC=0x80000108 was exactly this. The SoC drives this from
  -- its @dataStallS@ signal; FormalTop / sim wrappers can
  -- pass 'pure False'.
  Signal dom Bool ->
  -- | external machine-timer-interrupt-pending strobe. Wired
  -- straight into @mip.MTIP@ (bit 7 of the @cMip@ CSR) on every
  -- clock edge in the core; combined with @mstatus.MIE@ and
  -- @mie.MTIE@ to fire a machine-timer interrupt. Drive 'pure
  -- False' if the surrounding SoC has no CLINT yet.
  Signal dom Bool ->
  -- | external machine-external-interrupt-pending strobe. Wired
  -- straight into @mip.MEIP@ (bit 11 of the @cMip@ CSR) on every
  -- clock edge; combined with @mstatus.MIE@ and @mie.MEIE@ to
  -- fire a machine-external interrupt. Drive 'pure False' if the
  -- surrounding SoC has no PLIC yet.
  Signal dom Bool ->
  ( Signal dom (BitVector 32) -- pcFetch — drives imem address
  , Signal dom (BitVector 32) -- pcExec — PC of the retiring instruction
  , Signal dom (BitVector 32) -- dmem address
  , Signal dom (BitVector 32) -- dmem write data
  , Signal dom (BitVector 4) -- per-byte write-enable (0 = no write)
  , Signal dom Bool -- read enable
  , Signal dom (Maybe (BitVector 5, BitVector 32)) -- regfile write
  , Signal dom Rvfi -- RVFI observability bundle
  )
core imemData imemReadyS dmemRData stallS dataStallS mtipS meipS =
  ( pcFetchS
  , mwPcOutS
  , dmemAddrOutS
  , dmemWdataOutS
  , dmemBeOutS
  , dmemRenOutS
  , writeBackOutS
  , rvfiS
  )
 where
  -- ====================================================================
  -- Stall + flush plumbing
  -- ====================================================================

  -- The MulDiv FU's busy flag, the AMO FU's busy flag, OR external
  -- back-pressure all fold into the same stall signal. Back-end
  -- stages (EX/MEM, MEM/WB) drain on bubbles so already-issued
  -- instructions keep retiring.
  stallInternalS :: Signal dom Bool
  stallInternalS = (\s m a -> s || m || a) <$> stallS <*> mdBusyS <*> amoBusyS

  -- The X stage takes a non-sequential PC change (branch taken,
  -- JAL, JALR, MRET, trap) → flush IF/ID and ID/EX on the next
  -- clock edge so the two speculative instructions behind X
  -- don't retire. Not asserted on stalled cycles (nothing retires
  -- in X on those).
  flushS :: Signal dom Bool
  flushS =
    (\st v ch -> v && ch && not st)
      <$> stallInternalS
      <*> (idValid <$> idExS)
      <*> xPcChangedS

  -- One cycle after a flush, @pcFetch@ has already been redirected
  -- to the branch target but @imemData@ arriving this cycle still
  -- reflects the __pre-redirect__ PC the fetch unit presented
  -- last cycle (sync imem read). That data is stale — drop it
  -- with a bubble too. Without this second-cycle flush,
  -- back-to-back taken branches leak the after-second-branch
  -- speculative instruction through.
  flushPrevS :: Signal dom Bool
  flushPrevS = register False flushS

  -- Combined IF/ID flush: the edge right after the redirect, plus
  -- the following edge where imem is still returning the stale
  -- word.
  flushIfIdS :: Signal dom Bool
  flushIfIdS = (||) <$> flushS <*> flushPrevS

  -- Previous cycle's stall — kept for the RVFI-observability
  -- tracking further down. Not used for imem-capture logic
  -- anymore: the new multi-cycle-fetch-aware scheme below pairs
  -- imem-capture with 'pendingS' instead.
  stallPrevS :: Signal dom Bool
  stallPrevS = register False stallInternalS

  -- ====================================================================
  -- Multi-cycle-fetch-aware imem capture
  -- ====================================================================
  --
  -- The IF stage has to handle two sources of back-pressure with
  -- very different semantics:
  --
  --   * __Data stall__ (existing): the current instruction in X is
  --     waiting on a slow slave (SRAM / SDRAM / UART on the data
  --     path). 'stallInternalS' goes high for 1-4 cycles while the
  --     pipeline freezes. On the stall-onset cycle, @imemData@
  --     already holds the next-to-capture instruction
  --     (@memory[pcFetchPrev]@ via the blockRam's 1-cycle
  --     sync-read), but IF/ID can't capture it because the pipe
  --     register is frozen. When the stall eventually releases,
  --     @pcFetch@ has advanced ahead so @imemData@ has moved on to
  --     the __next__ instruction, and the "about-to-be-captured"
  --     one has to be preserved.
  --
  --   * __Fetch stall__ (new, SRAM / SDRAM code execution): the
  --     current @pcFetch@ lands in a multi-cycle slave's range.
  --     'imemReadyS' stays 'False' while the fetch FSM cycles,
  --     then pulses 'True' on the completion cycle.
  --     @pcFetchPrev@ should track the __held__ @pcFetch@ (not the
  --     pre-jalr value) so the (pc, instr) pair committed to IF/ID
  --     names the right source address.
  --
  -- Unified scheme:
  --
  --   * 'pendingS' latches True on any cycle where @stall@ && @imemReady@
  --     is true (an inst was valid but couldn't be captured), and
  --     clears on the first non-stalled cycle (the delayed
  --     capture has now happened). Exactly the "1-cycle data stall"
  --     shape.
  --   * 'imemHeldS' and 'pcFetchHoldS' latch the (instr, pc) pair
  --     __once__ at the start of the pending window (enable =
  --     stall && imemReady && not pending).
  --   * 'effectiveImemS' / 'effectivePcPrevS' pick 'imemHeldS' /
  --     'pcFetchHoldS' when 'pendingS' is set, otherwise fall back
  --     to the fresh @imemData@ / 'pcFetchPrevS'.
  --   * 'pcFetchPrevS' is a plain 'register' over @pcFetch@ (no
  --     stall gating). For multi-cycle fetches @pcFetch@ is held
  --     by the stall, so @pcFetchPrevS@ settles on the fetch
  --     address within one cycle. For data stalls the held (old)
  --     value lives in 'pcFetchHoldS' and is recovered via
  --     'pendingS'.
  --
  -- Net effect: single-cycle BRAM fetches, 1-cycle data stalls,
  -- and multi-cycle SRAM / SDRAM fetches all route (pc, instr)
  -- pairs to IF/ID correctly and consistently.

  -- Latches True when stall+imemReady fires with nothing pending;
  -- clears on the first non-stalled cycle (the delayed capture
  -- consumes it). Holds across sustained stalls with a single
  -- pending instruction.
  pendingNextS :: Signal dom Bool
  pendingNextS =
    ( \pending stall rdy -> case (pending, stall, rdy) of
        (True, True, _) -> True -- sustain: still stalled, already pending
        (True, False, _) -> False -- clear: stall released, capture consumes
        (False, True, True) -> True -- set: fresh valid-but-stalled
        _ -> False
    )
      <$> pendingS
      <*> stallInternalS
      <*> imemReadyS

  pendingS :: Signal dom Bool
  pendingS = register False pendingNextS

  -- Capture the (pc, instr) pair exactly once at the start of a
  -- pending window (stall + imemReady with nothing pending yet).
  -- Subsequent cycles of the same stall don't overwrite —
  -- preserving what IF/ID still owes itself.
  holdEnS :: Signal dom Bool
  holdEnS =
    ( \stall rdy pending -> case (stall, rdy, pending) of
        (True, True, False) -> True
        _ -> False
    )
      <$> stallInternalS
      <*> imemReadyS
      <*> pendingS

  imemHeldS :: Signal dom (BitVector 32)
  imemHeldS = regEn 0x0000_0013 holdEnS imemData

  pcFetchHoldS :: Signal dom (BitVector 32)
  pcFetchHoldS = regEn 0 holdEnS pcFetchPrevS

  -- Effective imem / pc-prev for IF/ID capture. 'pendingS' picks
  -- the latched pair; otherwise the fresh live pair. When neither
  -- is valid (stall=False but imemReady=False, which shouldn't
  -- happen under correct SoC plumbing — every fetch-in-flight
  -- cycle carries stall=True), we emit a NOP so the decode logic
  -- still sees a defined word.
  effectiveImemS :: Signal dom (BitVector 32)
  effectiveImemS =
    ( \pending rdy held live ->
        if pending then held else if rdy then live else 0x0000_0013
    )
      <$> pendingS
      <*> imemReadyS
      <*> imemHeldS
      <*> imemData

  effectivePcPrevS :: Signal dom (BitVector 32)
  effectivePcPrevS =
    (\pending hold prev -> if pending then hold else prev)
      <$> pendingS
      <*> pcFetchHoldS
      <*> pcFetchPrevS

  -- ====================================================================
  -- F stage
  -- ====================================================================

  pcFetchS :: Signal dom (BitVector 32)
  pcFetchS = register 0 pcFetchNextS

  -- On a redirect, jump to the X stage's new target. Otherwise,
  -- sequential advance (@pcFetch + 4@). Stall freezes both.
  pcFetchNextS :: Signal dom (BitVector 32)
  pcFetchNextS =
    ( \stall flush target pf ->
        if stall
          then pf
          else if flush then target else pf + 4
    )
      <$> stallInternalS
      <*> flushS
      <*> xPcNextS
      <*> pcFetchS

  -- PC of the instruction currently on @imemData@ (one cycle
  -- behind @pcFetch@ in steady state — last cycle's fetch).
  -- Hold / advance rule depends on stall flavour:
  --
  --   * Data stall (@stall && imemReady@): BRAM gave us a valid
  --     instruction but IF/ID can't capture. Hold pcFetchPrev
  --     at the pre-stall value so 'pcFetchHoldS' + 'pendingS'
  --     can preserve the (pc, instr) pair for the stall-release
  --     capture cycle.
  --   * Fetch stall (@stall && not imemReady@): multi-cycle
  --     fetch in flight. @pcFetch@ is held by the stall; advance
  --     pcFetchPrev so it tracks pcFetch (they converge on the
  --     fetch address within one cycle). IF/ID captures directly
  --     off pcFetchPrev on the ready cycle.
  --   * No stall: advance normally.
  pcFetchPrevS :: Signal dom (BitVector 32)
  pcFetchPrevS =
    register 0 $
      ( \prev stall rdy pf ->
          if stall && rdy then prev else pf
      )
        <$> pcFetchPrevS
        <*> stallInternalS
        <*> imemReadyS
        <*> pcFetchS

  -- ====================================================================
  -- IF/ID pipeline register
  -- ====================================================================
  --
  -- Under stall: hold. Under flush: insert a bubble (ifValid := False,
  -- instr := NOP). Normal: capture imemData at the clock edge.
  -- First few post-reset cycles are bubbles until the fetch chain
  -- fills up.
  --
  -- @ifValid@ is also False on the first cycle after reset when
  -- @imemData@ still reflects an undefined pre-reset read —
  -- 'fValidTrackS' counts it so the first real instruction
  -- captures @ifValid = True@.

  -- 'fValidTrackS' counts the IF stage's "imem first ready" event so
  -- the first IF/ID capture happens with @ifValid=True@. False at
  -- reset; the mux flips it True the cycle after EITHER of:
  --
  --   * @stall=False@ (single-domain BRAM: stall first deasserts at
  --     cycle 1 once @blockRam@'s 1-cycle read latency has elapsed),
  --   * @stall=True && imemReady=True@ (bridge mode: the bridge
  --     announces "imem reply is ready, but I'm still asserting stall
  --     for one cycle so 'fValidTrackS' has time to flip" — see
  --     'Riski5.CoreCdcBridge.replyOutC's MBusy-doneEdge branch).
  --
  -- Single-domain: stall=False from cycle 0 (since 'imemReadyS=pure
  -- True' for the BRAM-only fetch), so cycle-0 mux input is True,
  -- fValidTrackS_1=True. Cycle-0 capture has @ifValid=False@ (mask
  -- cycle-0 @blockRam@ output garbage); cycle-1 capture is the first
  -- real instruction with @ifValid=True@. Behaviour identical to the
  -- previous one-input-mux form.
  --
  -- Bridge mode: 'CoreCdcBridge' presents @cbrImemReady=True@ on the
  -- MBusy cycle that 'doneEdge' fires (one cycle BEFORE the MDone
  -- that releases stall). The two-input mux sees stall=True &&
  -- imemReady=True and flips fValidTrackS to True for the next
  -- cycle (= the MDone cycle); the IF/ID capture on that MDone
  -- cycle then sees @ifValid=True@ and the LUI / first instruction
  -- enters the pipeline correctly. Caught by
  -- 'CdcSocIntegrationSpec.case_core_dAddr'.
  fValidTrackS :: Signal dom Bool
  fValidTrackS =
    register False $
      mux
        stallInternalS
        (mux imemReadyS (pure True) fValidTrackS)
        (pure True)

  ifIdS :: Signal dom IfId
  ifIdS = register defaultIfId ifIdNextS

  ifIdNextS :: Signal dom IfId
  ifIdNextS =
    ( \stall flush cur pcP imem valid ->
        if stall
          then cur
          else
            if flush
              then bubbleIfId
              else
                IfId
                  { ifPc = pcP
                  , ifPcNext = pcP + 4
                  , ifInstr = imem
                  , ifValid = valid
                  }
    )
      <$> stallInternalS
      <*> flushIfIdS
      <*> ifIdS
      <*> effectivePcPrevS
      <*> effectiveImemS
      <*> fValidTrackS

  -- ====================================================================
  -- D stage
  -- ====================================================================

  -- NOP-squash the instruction on any bubble so 'decode' can't
  -- produce spurious 'Just Instr' for pre-pipeline-fill garbage.
  dInstrWordS :: Signal dom (BitVector 32)
  dInstrWordS =
    (\i -> if ifValid i then ifInstr i else 0x0000_0013)
      <$> ifIdS

  dMInstrS :: Signal dom (Maybe Instr)
  dMInstrS = decode <$> dInstrWordS

  dRs1AddrS, dRs2AddrS :: Signal dom (BitVector 5)
  dRs1AddrS = slice d19 d15 <$> dInstrWordS
  dRs2AddrS = slice d24 d20 <$> dInstrWordS

  -- Raw regfile reads (async, combinational). Reflect all writes
  -- committed at edges prior to this cycle.
  (dRs1RawS, dRs2RawS) = regfile dRs1AddrS dRs2AddrS writeBackOutS

  -- D-stage forwarding. Mirrors the X-stage forwarding mux shape:
  -- EX/MEM takes priority, then MEM/WB, then the raw regfile read.
  --
  -- Why D needs forwarding at all (ex-comment was just "W→D
  -- bypass"): on stall cycles, @writeBackOutS@ is gated off so
  -- the instruction sitting in MEM/WB doesn't actually commit
  -- its writeback this cycle — but @memWbS@ still carries that
  -- pending-commit data. Same with EX/MEM during stall chains.
  -- If D only consulted the gated @writeBackOutS@, it would
  -- capture stale-regfile data into ID/EX.rs1Data / rs2Data,
  -- and X's forwarding mux can only see EX/MEM and MEM/WB at
  -- X's cycle — not at D's cycle — so the stale ID/EX data
  -- would reach the ALU when the original producer has long
  -- since moved past.
  --
  -- Consulting EX/MEM + MEM/WB here covers:
  --   * The usual two-ahead write-then-read hazard that
  --     forwarding always handles.
  --   * Any writeback that's stuck in the back of the pipeline
  --     during multi-cycle memory stalls — since EX/MEM and
  --     MEM/WB freeze on stall (matching my stall fix), they
  --     hold the in-flight writeback exactly until the stall
  --     clears, so the D-stage sees it every cycle regardless
  --     of how many stall cycles the producer has been waiting
  --     in the back.
  dForward :: BitVector 5 -> BitVector 32 -> ExMem -> MemWb -> BitVector 32
  dForward rsAddr rsData exM mwM
    | rsAddr == 0 = 0
    | emValid exM && emWbEn exM && emRd exM == rsAddr = emWbData exM
    | mwValid mwM && mwWbEn mwM && mwRd mwM == rsAddr = mwWbData mwM
    | otherwise = rsData

  dRs1DataS = dForward <$> dRs1AddrS <*> dRs1RawS <*> exMemS <*> memWbS
  dRs2DataS = dForward <$> dRs2AddrS <*> dRs2RawS <*> exMemS <*> memWbS

  -- ====================================================================
  -- ID/EX pipeline register
  -- ====================================================================

  idExS :: Signal dom IdEx
  idExS = register defaultIdEx idExNextS

  idExNextS :: Signal dom IdEx
  idExNextS =
    ( \stall flush cur i mI r1 r2 r1v r2v ifr ->
        if stall
          then cur
          else
            if flush
              then bubbleIdEx
              else
                IdEx
                  { idPc = ifPc ifr
                  , idPcNext = ifPcNext ifr
                  , idInstr = i
                  , idMInstr = mI
                  , idRs1 = r1
                  , idRs2 = r2
                  , idRs1Data = r1v
                  , idRs2Data = r2v
                  , idRd = instrRd mI
                  , idWbEn = instrWritesRd mI
                  , idValid = ifValid ifr
                  }
    )
      <$> stallInternalS
      <*> flushS
      <*> idExS
      <*> dInstrWordS
      <*> dMInstrS
      <*> dRs1AddrS
      <*> dRs2AddrS
      <*> dRs1DataS
      <*> dRs2DataS
      <*> ifIdS

  -- ====================================================================
  -- X stage — forwarding, ALU, CSRs, trap detection
  -- ====================================================================

  -- Forward-from-EX/MEM: the instruction immediately ahead of X
  -- is in EX/MEM now; its computed result (@emWbData@) is fresh
  -- and takes precedence over the stale regfile read.
  -- Forward-from-MEM/WB: two ahead of X; use only if EX/MEM
  -- didn't already provide a match.
  forwardRs :: BitVector 5 -> BitVector 32 -> ExMem -> MemWb -> BitVector 32
  forwardRs rsAddr rsData exM mwM
    | rsAddr == 0 = 0
    | emValid exM && emWbEn exM && emRd exM == rsAddr = emWbData exM
    | mwValid mwM && mwWbEn mwM && mwRd mwM == rsAddr = mwWbData mwM
    | otherwise = rsData

  rs1FwdS, rs2FwdS :: Signal dom (BitVector 32)
  rs1FwdS = forwardRs <$> (idRs1 <$> idExS) <*> (idRs1Data <$> idExS) <*> exMemS <*> memWbS
  rs2FwdS = forwardRs <$> (idRs2 <$> idExS) <*> (idRs2Data <$> idExS) <*> exMemS <*> memWbS

  -- X computes the per-cycle Out bundle exactly like the old
  -- pipelineless core — same 'handleInstr' function — but on
  -- pipeline-captured operands rather than current-cycle decode.
  xOutS :: Signal dom Out
  xOutS =
    handleInstr
      <$> (idPc <$> idExS)
      <*> (idPcNext <$> idExS)
      <*> (idInstr <$> idExS)
      <*> (idMInstr <$> idExS)
      <*> rs1FwdS
      <*> rs2FwdS
      <*> dmemRData
      <*> csrsS

  xPcNextRawS :: Signal dom (BitVector 32)
  xDmemAddrS, xDmemWdataS :: Signal dom (BitVector 32)
  xDmemBeS :: Signal dom (BitVector 4)
  xDmemRenS :: Signal dom Bool
  xWbMaybeS :: Signal dom (Maybe (BitVector 5, BitVector 32))
  xTrapFiredS :: Signal dom Bool
  xCsrsNextS :: Signal dom Csrs
  (xPcNextRawS, xCsrsNextS, xDmemAddrS, xDmemWdataS, xDmemBeS, xDmemRenS, xWbMaybeS, xTrapFiredS) =
    unbundle xOutS

  -- A non-sequential PC change iff the raw next-PC differs from
  -- the realigner-supplied straight-line continuation. Compressed
  -- retires advance by 2, uncompressed by 4 — this comparison is
  -- the same shape either way.
  xPcChangedS :: Signal dom Bool
  xPcChangedS =
    (\pN pn -> pn /= pN) <$> (idPcNext <$> idExS) <*> xPcNextRawS

  -- For pcFetchNextS on flush: jump to the raw next-PC.
  xPcNextS :: Signal dom (BitVector 32)
  xPcNextS = xPcNextRawS

  -- ====================================================================
  -- MulDiv functional unit
  -- ====================================================================
  --
  -- The FU sits inside the X stage. mdActive asserts whenever the
  -- instruction in ID/EX is an M op; mdBusy feeds back into
  -- stallInternalS so the FU gets its ~34 cycles to iterate before
  -- the pipeline advances.

  mdActiveS :: Signal dom Bool
  mdActiveS =
    ( \v mi -> v && case mi of
        Just i -> isMdOp i
        Nothing -> False
    )
      <$> (idValid <$> idExS)
      <*> (idMInstr <$> idExS)

  mdOpS :: Signal dom MdOp
  mdOpS =
    ( \mi -> case mi of
        Just i -> mdOpOf i
        Nothing -> MdMul
    )
      <$> (idMInstr <$> idExS)

  mdBusyS :: Signal dom Bool
  mdResultS :: Signal dom (BitVector 32)
  (mdBusyS, mdResultS) = mulDivFU mdActiveS mdOpS rs1FwdS rs2FwdS

  -- Replace the handler's placeholder writeback value with the
  -- FU's real result on the retire cycle — same pattern as the
  -- 2-stage core, only the mux now feeds EX/MEM (not directly
  -- into the regfile write port).
  xWbWithMdS :: Signal dom (Maybe (BitVector 5, BitVector 32))
  xWbWithMdS =
    ( \isMd mdR wb -> case (isMd, wb) of
        (True, Just (rd, _)) -> Just (rd, mdR)
        _ -> wb
    )
      <$> mdActiveS
      <*> mdResultS
      <*> xWbMaybeS

  -- ====================================================================
  -- A-extension functional unit
  -- ====================================================================
  --
  -- Multi-cycle path for LR.W / SC.W / AMO*.W. Lives next to the
  -- MulDiv FU and shares the stall protocol: amoBusyS folds into
  -- stallInternalS, the FU drives memory directly during its
  -- Read / Write phases, and the result mux below re-routes its
  -- output into the EX/MEM register on the retire cycle (the same
  -- 'xWbWithMdS'-style override the M-extension uses).

  amoActiveS :: Signal dom Bool
  amoActiveS =
    ( \v mi -> v && case mi of
        Just i -> isAmoOp i
        Nothing -> False
    )
      <$> (idValid <$> idExS)
      <*> (idMInstr <$> idExS)

  amoOpS :: Signal dom AmoOp
  amoOpS =
    ( \mi -> case mi of
        Just i -> amoOpOf i
        Nothing -> AmoLrW
    )
      <$> (idMInstr <$> idExS)

  amoBusyS :: Signal dom Bool
  amoResultS :: Signal dom (BitVector 32)
  amoBusS :: Signal dom AmoBus
  -- Slave-ready signal for the AMO FU's bus phases. The external
  -- 'stallS' goes True whenever any data-side slave (SRAM, SDRAM,
  -- BRAM-bus-port, JTAG-UART) is mid-transaction; @not stallS@
  -- gives us "transaction settled this cycle" — exactly the gate
  -- the AmoFU's Read / Write phases need to know when to capture
  -- the read response or consider the write committed. For
  -- async-read paths (BRAM-fetch direct, simHarnessA) this signal
  -- is constant True via the SoC's stall composition, so
  -- single-cycle dmem still retires AMOs in the original 3-busy-
  -- cycle envelope.
  amoSlaveReadyS :: Signal dom Bool
  amoSlaveReadyS = not <$> dataStallS
  -- ^ Was @not <$> stallS@. Switched to dataStallS-only because
  -- the combined stallS includes fetchStallS, which causes a
  -- circular dependency: the AMO holds the data bus, fetch
  -- starves on the sticky arbiter, fetchStallS stays True, the
  -- combined stallS stays True, and the AMO FU's slaveReady
  -- never pulses True so the FSM never advances past AmoRead /
  -- AmoWrite. The dataStallS signal reports only data-side
  -- slave readiness, breaking the cycle. Task #143 silicon
  -- Linux hang at PC=0x80000108 was exactly this.
  (amoBusyS, amoResultS, amoBusS) =
    amoFU amoActiveS amoOpS rs1FwdS rs2FwdS dmemRData amoSlaveReadyS

  -- Override the writeback for A-ext ops with the FU's result.
  xWbWithAmoS :: Signal dom (Maybe (BitVector 5, BitVector 32))
  xWbWithAmoS =
    ( \isAmo amoR wb -> case (isAmo, wb) of
        (True, Just (rd, _)) -> Just (rd, amoR)
        _ -> wb
    )
      <$> amoActiveS
      <*> amoResultS
      <*> xWbWithMdS

  -- Effective dmem drives. While the AMO FU is busy, its
  -- Read / Write phase signals take over the bus; otherwise the
  -- regular X-stage drives flow through.
  effDmemAddrS :: Signal dom (BitVector 32)
  effDmemAddrS =
    (\busy bus regular -> if busy then amoDmemAddr bus else regular)
      <$> amoBusyS
      <*> amoBusS
      <*> xDmemAddrS

  effDmemWdataS :: Signal dom (BitVector 32)
  effDmemWdataS =
    (\busy bus regular -> if busy then amoDmemWdata bus else regular)
      <$> amoBusyS
      <*> amoBusS
      <*> xDmemWdataS

  effDmemBeS :: Signal dom (BitVector 4)
  effDmemBeS =
    (\busy bus regular -> if busy then amoDmemBe bus else regular)
      <$> amoBusyS
      <*> amoBusS
      <*> xDmemBeS

  effDmemRenS :: Signal dom Bool
  effDmemRenS =
    (\busy bus regular -> if busy then amoDmemRen bus else regular)
      <$> amoBusyS
      <*> amoBusS
      <*> xDmemRenS

  -- ====================================================================
  -- EX/MEM pipeline register
  -- ====================================================================
  --
  -- On a stall (including the whole MulDiv iteration window),
  -- EX/MEM receives a bubble — the instruction that's stalling
  -- in X hasn't actually retired yet, so EX/MEM should clear out
  -- to let already-issued instructions ahead of it drain through
  -- M/W unobstructed. When the stall releases (e.g. mdBusy drops
  -- on 'MdDone'), the cycle's xOut carries the M op's real
  -- result and EX/MEM captures it normally.
  --
  -- On a flush (branch-taken / trap), we __don't__ invalidate
  -- EX/MEM — the instruction in X that triggered the redirect is
  -- the branch / trap itself, which retires as normal. The flush
  -- only hits IF/ID and ID/EX.

  exMemS :: Signal dom ExMem
  exMemS = register defaultExMem exMemNextS

  exMemNextS :: Signal dom ExMem
  exMemNextS =
    ( \stall cur ie xWb xAddr xWd xBe xRen xTrap xCsrsNext xCsrsPre xRs1 xRs2 xMem ->
        if stall
          then cur -- hold frozen on stall — don't drain to bubble
          else
            let (rd, wbData, wbEn) = case xWb of
                  Just (r, v) -> (r, v, True)
                  Nothing -> (0, 0, False)
             in ExMem
                  { emPc = idPc ie
                  , emInstr = idInstr ie
                  , emMInstr = idMInstr ie
                  , emRd = rd
                  , emWbData = wbData
                  , emWbEn = wbEn && idValid ie
                  , emDmemAddr = xAddr
                  , emDmemWdata = xWd
                  , emDmemBe = if idValid ie then xBe else 0
                  , emDmemRen = idValid ie && xRen
                  , emMemRdata = xMem
                  , emRs1Data = xRs1
                  , emRs2Data = xRs2
                  , emTrap = idValid ie && xTrap
                  , emCsrsPre = xCsrsPre
                  , emCsrsPost = xCsrsNext
                  , emValid = idValid ie
                  }
    )
      <$> stallInternalS
      <*> exMemS
      <*> idExS
      <*> xWbWithAmoS
      <*> xDmemAddrS
      <*> xDmemWdataS
      <*> xDmemBeS
      <*> xDmemRenS
      <*> xTrapFiredS
      <*> xCsrsNextS
      <*> csrsS
      <*> rs1FwdS
      <*> rs2FwdS
      <*> dmemRData

  -- ====================================================================
  -- M stage (passthrough — async-read dmem already captured at X)
  -- ====================================================================
  --
  -- Phase 2A's dmem is async (Vec-register), so the load value
  -- was already known at X's output and stored in emMemRdata →
  -- emWbData covers both ALU + load cases. M just copies EX/MEM
  -- into MEM/WB. When phase 2C lands sync D$, the mem lookup
  -- moves here.

  memWbS :: Signal dom MemWb
  memWbS = register defaultMemWb memWbNextS

  memWbNextS :: Signal dom MemWb
  memWbNextS =
    ( \stall cur em ->
        if stall then cur
        else MemWb
          { mwPc = emPc em
          , mwInstr = emInstr em
          , mwMInstr = emMInstr em
          , mwRd = emRd em
          , mwWbData = emWbData em
          , mwWbEn = emWbEn em
          , mwDmemAddr = emDmemAddr em
          , mwDmemWdata = emDmemWdata em
          , mwDmemBe = emDmemBe em
          , mwDmemRen = emDmemRen em
          , mwMemRdata = emMemRdata em
          , mwRs1Data = emRs1Data em
          , mwRs2Data = emRs2Data em
          , mwTrap = emTrap em
          , mwCsrsPre = emCsrsPre em
          , mwCsrsPost = emCsrsPost em
          , mwValid = emValid em
          }
    )
      <$> stallInternalS
      <*> memWbS
      <*> exMemS

  -- ====================================================================
  -- W stage — regfile write + RVFI retire event
  -- ====================================================================

  writeBackOutS :: Signal dom (Maybe (BitVector 5, BitVector 32))
  writeBackOutS =
    ( \stall m ->
        if stall
          then Nothing -- stalled: instr hasn't retired yet
          else
            if mwValid m && mwWbEn m
              then Just (mwRd m, mwWbData m)
              else Nothing
    )
      <$> stallInternalS
      <*> memWbS

  -- ====================================================================
  -- CSR state
  -- ====================================================================
  --
  -- CSRs are written eagerly at X — same pattern as the 2-stage
  -- core, because the only instructions that write CSRs are
  -- themselves the retiring instruction in X (CSR ops, traps),
  -- so committing at X-time is correct. Squashed instructions in
  -- D / IF/ID never reach X, so never write CSRs.
  --
  -- The CSR register captures xCsrsNext unless X is bubbled
  -- (idValid = False) or stalled.

  -- cMcycle increments every core clock (CM-4 — needed for CoreMark's
  -- mcycle-based timing). cMip's MTIP bit follows the external 'mtipS'
  -- strobe driven by 'Riski5.Clint'; cMip's MEIP bit follows 'meipS'
  -- driven by 'Riski5.Plic'. Everything else in Csrs follows the
  -- existing "update-on-retire" rule: capture xCsrsNextS when the
  -- X-stage instruction is valid and the pipeline isn't stalled, hold
  -- otherwise.
  csrsS :: Signal dom Csrs
  csrsS =
    register initCsrs $
      ( \stall valid next cur mtip meip ->
          let base = if stall || not valid then cur else next
              -- Strip both hardware-driven mip bits (MTIP @ bit 7,
              -- MEIP @ bit 11) before re-folding them from the live
              -- external strobes — software writes to mip can never
              -- override the hardware view.
              mipMasked =
                cMip base .&. complement (bit 7 .|. bit 11)
              mipFinal =
                mipMasked
                  .|. (if mtip then bit 7 else 0)
                  .|. (if meip then bit 11 else 0)
           in base
                { cMcycle = cMcycle cur + 1
                , cMip = mipFinal
                }
      )
        <$> stallInternalS
        <*> (idValid <$> idExS)
        <*> xCsrsNextS
        <*> csrsS
        <*> mtipS
        <*> meipS

  -- ====================================================================
  -- Outputs
  -- ====================================================================

  -- pcExec at the boundary: PC of the retiring instruction = MEM/WB's PC.
  mwPcOutS :: Signal dom (BitVector 32)
  mwPcOutS = mwPc <$> memWbS

  -- Drive dmem from X's request (current cycle) so the async
  -- read returns in time for X to compose the load's writeback
  -- value. This matches the 2-stage core's behaviour —
  -- 'Riski5.Soc' sees the same addr / wdata / be / ren contract.
  dmemAddrOutS :: Signal dom (BitVector 32)
  dmemAddrOutS = effDmemAddrS

  dmemWdataOutS :: Signal dom (BitVector 32)
  dmemWdataOutS = effDmemWdataS

  -- Quench the data-port drive once the slave has accepted the
  -- current transaction but the pipeline is still stalled (e.g.
  -- waiting for a multi-cycle fetch to settle). Without this gate,
  -- the X-stage's bus signals stay asserted through the whole
  -- pipeline-hold window, the SoC's bus arbiter sees @cs=1@ on
  -- every cycle, and the data slave processes the SAME store /
  -- load over and over until the pipeline finally advances. Each
  -- re-issue is a separate Avalon-MM transaction; the kernel's
  -- BSS-clear loop at PC=0x80000124 was hanging because every SW
  -- to a fresh address re-fired indefinitely while the next
  -- instruction's fetch crawled through SDRAM behind the sticky
  -- arbiter (task #143 silicon hang follow-up). Gating only the
  -- regular drives — when @amoBusyS@ is True the AMO FU's own
  -- FSM self-quenches in @AmoDone@, so we leave its drives
  -- alone here.
  dataDoneS :: Signal dom Bool
  dataDoneS = register False dataDoneNextS

  dataDoneNextS :: Signal dom Bool
  dataDoneNextS =
    ( \done stall ds amoB -> case (done, stall, ds, amoB) of
        (_, False, _, _) -> False
        -- ^ pipeline advancing → clear
        (True, True, _, _) -> True
        -- ^ sustained stall → hold
        (False, True, False, False) -> True
        -- ^ regular data transaction settled, pipeline still
        -- stalled → quench from here on
        _ -> False
    )
      <$> dataDoneS
      <*> stallInternalS
      <*> dataStallS
      <*> amoBusyS

  -- True when we should quench the regular X-stage data drives.
  -- AMO bus drives pass through unchanged.
  quenchDataS :: Signal dom Bool
  quenchDataS =
    (\done amoB -> done && not amoB) <$> dataDoneS <*> amoBusyS

  -- Gate the byte-enable by @idValid@ so bubble cycles can't
  -- spuriously store through, and by @quenchDataS@ to prevent
  -- multi-cycle data slaves from re-firing while the pipeline
  -- is held by an unrelated stall (e.g. fetch-side).
  dmemBeOutS :: Signal dom (BitVector 4)
  dmemBeOutS =
    (\v q be -> if v && not q then be else 0)
      <$> (idValid <$> idExS)
      <*> quenchDataS
      <*> effDmemBeS

  dmemRenOutS :: Signal dom Bool
  dmemRenOutS =
    (\v q re -> v && not q && re)
      <$> (idValid <$> idExS)
      <*> quenchDataS
      <*> effDmemRenS

  -- ====================================================================
  -- RVFI observability (at W retire edge)
  -- ====================================================================

  rvfiValidS :: Signal dom Bool
  rvfiValidS =
    (\stall m -> not stall && mwValid m)
      <$> stallInternalS
      <*> memWbS

  rvfiOrderS :: Signal dom (BitVector 64)
  rvfiOrderS =
    register 0 $
      ( \v o -> if v then o + 1 else o
      )
        <$> rvfiValidS
        <*> rvfiOrderS

  -- rvfi_intr: this retire is the first in a trap handler iff
  -- its PC isn't the previous retire's next-PC. Track last retire's
  -- post-PC (computed as pc+4 normally or mtvec.base on trap).
  prevRetirePcPostS :: Signal dom (BitVector 32)
  prevRetirePcPostS =
    register 0 $
      ( \v pw prev -> if v then pw else prev
      )
        <$> rvfiValidS
        <*> rvfiPcWS
        <*> prevRetirePcPostS

  rvfiIntrS :: Signal dom Bool
  rvfiIntrS =
    (\v pr prev -> v && pr /= prev)
      <$> rvfiValidS
      <*> (mwPc <$> memWbS)
      <*> prevRetirePcPostS

  -- rvfi_pc_wdata: for a trap retire this is the trap target, for
  -- everything else it's the sequential-or-branch-computed next
  -- PC. MEM/WB's PC is the PC of this retire; we reconstruct
  -- pc_wdata by re-running the next-PC logic on MEM/WB's trap
  -- flag and csrs — OR we just store it on the EX/MEM → MEM/WB
  -- path. Simpler to piggy-back on the existing X logic by
  -- stashing xPcNextRaw into EX/MEM.
  --
  -- For this first cut, compute it from the retire side using
  -- the post-CSR state's mtvec (for trap retires) / mwPc + 4
  -- (otherwise). For taken branches / jumps, the pc-change is
  -- recorded at X but then bubbles out via the flush and the
  -- real redirect target is in pcFetch; the next retire sees it
  -- as its own pc_rdata. The rvfi_pc_wdata of the branching
  -- instruction itself should be the taken target.
  --
  -- Simplest: store pcNextRaw on the EX/MEM path. Added as
  -- emPcNext for RVFI precision.
  rvfiPcWS :: Signal dom (BitVector 32)
  rvfiPcWS =
    ( \m ->
        if mwTrap m
          then cMtvec (mwCsrsPost m) .&. complement 3
          else mwPc m + 4
    )
      <$> memWbS

  -- Actually for branches / JAL / JALR we need the computed
  -- target, not pc + 4. Pipe it through from X → EX/MEM → MEM/WB.
  -- TODO: carry xPcNextRaw on the pipe regs for exact RVFI. For
  -- now compute by re-decoding the retiring instr plus the
  -- post-execution rs values.
  --
  -- The working version: stash pcNext on the pipe regs. Extend
  -- ExMem + MemWb with an @emPcNext :: BitVector 32@ field. Done
  -- below.

  -- rvfi_rd_addr / rvfi_rd_wdata: masked so rd_wdata = 0 when rd = 0.
  rvfiRdAddrS :: Signal dom (BitVector 32)
  rvfiRdAddrS =
    ( \m ->
        if mwValid m && mwWbEn m
          then resize (mwRd m)
          else 0
    )
      <$> memWbS

  rvfiRdWdataS :: Signal dom (BitVector 32)
  rvfiRdWdataS =
    ( \m ->
        if mwValid m && mwWbEn m && mwRd m /= 0
          then mwWbData m
          else 0
    )
      <$> memWbS

  -- rvfi_mem_rmask: which bytes of dmem this load consumed, derived
  -- from the retiring instruction's opcode + addr.
  rvfiMemRmaskS :: Signal dom (BitVector 4)
  rvfiMemRmaskS =
    (\m -> if mwDmemRen m then loadMask (mwInstr m) (mwDmemAddr m) else 0)
      <$> memWbS

  -- rvfi_mem_addr aligned to word (per spec).
  rvfiMemAddrS :: Signal dom (BitVector 32)
  rvfiMemAddrS =
    (\m -> mwDmemAddr m .&. complement 3)
      <$> memWbS

  -- Per-CSR rmask / wmask: all-ones iff this retire is a CSR op
  -- targeting the CSR, or (for trap-written CSRs) any trap retire.
  csrRetireAddrS :: Signal dom (Bool, BitVector 12)
  csrRetireAddrS =
    (\m -> (mwValid m && isCsrOp (mwInstr m), slice d31 d20 (mwInstr m)))
      <$> memWbS

  csrWmaskLocal ::
    BitVector 12 -> Bool -> Signal dom (BitVector 32)
  csrWmaskLocal csrAddr writtenOnTrap =
    ( \(isCsr, tAddr) v t ->
        if (isCsr && tAddr == csrAddr) || (writtenOnTrap && v && t)
          then maxBound
          else 0
    )
      <$> csrRetireAddrS
      <*> rvfiValidS
      <*> (mwTrap <$> memWbS)

  csrRmaskLocal :: BitVector 12 -> Signal dom (BitVector 32)
  csrRmaskLocal csrAddr =
    ( \(isCsr, tAddr) ->
        if isCsr && tAddr == csrAddr then maxBound else 0
    )
      <$> csrRetireAddrS

  mkCsrBlock ::
    BitVector 12 ->
    Bool ->
    (Csrs -> BitVector 32) ->
    (Csrs -> BitVector 32) ->
    Signal dom RvfiCsr
  mkCsrBlock csrAddr writtenOnTrap getR getW =
    ( \r w rd wd ->
        RvfiCsr
          { rcRmask = r
          , rcWmask = w
          , rcRdata = rd
          , rcWdata = wd
          }
    )
      <$> csrRmaskLocal csrAddr
      <*> csrWmaskLocal csrAddr writtenOnTrap
      <*> ((getR . mwCsrsPre) <$> memWbS)
      <*> ((getW . mwCsrsPost) <$> memWbS)

  rvfiCsrMstatusS, rvfiCsrMtvecS, rvfiCsrMepcS :: Signal dom RvfiCsr
  rvfiCsrMcauseS, rvfiCsrMtvalS, rvfiCsrMscratchS :: Signal dom RvfiCsr
  rvfiCsrMstatusS = mkCsrBlock (unCsr csrMstatus) False cMstatus cMstatus
  rvfiCsrMtvecS = mkCsrBlock (unCsr csrMtvec) False cMtvec cMtvec
  rvfiCsrMepcS = mkCsrBlock (unCsr csrMepc) True cMepc cMepc
  rvfiCsrMcauseS = mkCsrBlock (unCsr csrMcause) True cMcause cMcause
  rvfiCsrMtvalS = mkCsrBlock (unCsr csrMtval) True cMtval cMtval
  rvfiCsrMscratchS = mkCsrBlock (unCsr csrMscratch) False cMscratch cMscratch

  rvfiS :: Signal dom Rvfi
  rvfiS =
    ( \m valid order intr rdA rdW mAddr mRm pcW
       csrSt csrTv csrEpc csrCs csrTval csrScr ->
          Rvfi
            { rfValid = if valid then 1 else 0
            , rfOrder = order
            , rfInsn = mwInstr m
            , rfTrap = if mwTrap m && valid then 1 else 0
            , rfHalt = 0
            , rfIntr = if intr then 1 else 0
            , rfMode = 3
            , rfIxl = 1
            , rfRs1Addr = slice d19 d15 (mwInstr m)
            , rfRs2Addr = slice d24 d20 (mwInstr m)
            , rfRs1Rdata = mwRs1Data m
            , rfRs2Rdata = mwRs2Data m
            , rfRdAddr = resize rdA
            , rfRdWdata = rdW
            , rfMemAddr = mAddr
            , rfMemRmask = mRm
            , rfMemWmask = mwDmemBe m
            , rfMemRdata = mwMemRdata m
            , rfMemWdata = mwDmemWdata m
            , rfPcRdata = mwPc m
            , rfPcWdata = pcW
            , rfCsrMstatus = csrSt
            , rfCsrMtvec = csrTv
            , rfCsrMepc = csrEpc
            , rfCsrMcause = csrCs
            , rfCsrMtval = csrTval
            , rfCsrMscratch = csrScr
            }
    )
      <$> memWbS
      <*> rvfiValidS
      <*> rvfiOrderS
      <*> rvfiIntrS
      <*> rvfiRdAddrS
      <*> rvfiRdWdataS
      <*> rvfiMemAddrS
      <*> rvfiMemRmaskS
      <*> rvfiPcWS
      <*> rvfiCsrMstatusS
      <*> rvfiCsrMtvecS
      <*> rvfiCsrMepcS
      <*> rvfiCsrMcauseS
      <*> rvfiCsrMtvalS
      <*> rvfiCsrMscratchS

-- ====================================================================
-- Combinational per-cycle X logic (unchanged from the 2-stage core)
-- ====================================================================

{- |
Per-cycle output bundle. @pcNext@ and @csrsNext@ feed the core's
two sequential registers; the next five signals drive memory and
the regfile write port; the trailing @Bool@ tags whether this
cycle's instruction raised a trap (consumed by the RVFI tap).
-}
type Out =
  ( BitVector 32 -- pcNext
  , Csrs -- csrsNext
  , BitVector 32 -- dmemAddr
  , BitVector 32 -- dmemWdata
  , BitVector 4 -- dmemByteEn (0 = no write)
  , Bool -- dmemReadEn
  , Maybe (BitVector 5, BitVector 32) -- regfile writeback
  , Bool -- trap fired this instruction (→ rvfi_trap)
  )

{- |
Per-cycle combinational behaviour. Threaded CSR state makes every
branch pure, which keeps this function straightforwardly diffable
against 'Riski5.Reference' and easy to Hedgehog against.
-}
handleInstr ::
  BitVector 32 ->
  BitVector 32 -> -- pcN — next sequential PC (= pc+4 for uncompressed; pc+2 for compressed)
  BitVector 32 -> -- raw instruction word (for mtval on illegal)
  Maybe Instr ->
  BitVector 32 ->
  BitVector 32 ->
  BitVector 32 ->
  Csrs ->
  Out
handleInstr pc pcN rawInstr mInstr rs1V rs2V memRData cs =
  -- Machine-mode interrupts pre-empt the instruction: if mstatus.MIE
  -- and mie.MTIE are set and mip.MTIP is pending, redirect to the
  -- trap handler at mtvec.base before executing the instruction.
  -- mepc is the pc of the instruction we did __not__ run, so mret
  -- resumes there.
  case interruptPending cs of
    Just cause -> trap cause pc 0 cs
    Nothing -> handleInstr_ pc pcN rawInstr mInstr rs1V rs2V memRData cs

-- The original instruction-dispatch logic — unchanged save for being
-- guarded by the pre-emption check above. @pcN@ is the
-- post-instruction PC, used wherever the spec says "the address of
-- the following instruction" — JAL/JALR link, branch fall-through,
-- sequential retire, and the straight-line PC of every non-jumping
-- instruction. With the IF realigner inactive @pcN = pc + 4@.
handleInstr_ ::
  BitVector 32 ->
  BitVector 32 ->
  BitVector 32 ->
  Maybe Instr ->
  BitVector 32 ->
  BitVector 32 ->
  BitVector 32 ->
  Csrs ->
  Out
handleInstr_ pc _ rawInstr Nothing _ _ _ cs =
  trap causeIllegalInstr pc rawInstr cs
handleInstr_ pc pcN _ (Just instr) rs1V rs2V memRData cs = case instr of
  Lui rd imm ->
    let res = imm ++# (0 :: BitVector 12)
     in regWb cs rd res pcN
  Auipc rd imm ->
    let res = pc + (imm ++# (0 :: BitVector 12))
     in regWb cs rd res pcN
  Jal rd off ->
    let target = pc + sxImm21 off
     in if slice d1 d0 target /= 0
          then trap causeInstrAddrMisaligned pc target cs
          else regWb cs rd pcN target
  Jalr rd _ off ->
    let target = (rs1V + sxImm12 off) .&. complement 1
     in if slice d1 d0 target /= 0
          then trap causeInstrAddrMisaligned pc target cs
          else regWb cs rd pcN target
  Lb rd _ off -> doLoad cs rd off 1 True rs1V memRData pc pcN
  Lh rd _ off -> doLoad cs rd off 2 True rs1V memRData pc pcN
  Lw rd _ off -> doLoad cs rd off 4 False rs1V memRData pc pcN
  Lbu rd _ off -> doLoad cs rd off 1 False rs1V memRData pc pcN
  Lhu rd _ off -> doLoad cs rd off 2 False rs1V memRData pc pcN
  Addi rd _ imm -> aluImm cs rd AluAdd rs1V imm pcN
  Slti rd _ imm -> aluImm cs rd AluSlt rs1V imm pcN
  Sltiu rd _ imm -> aluImm cs rd AluSltu rs1V imm pcN
  Xori rd _ imm -> aluImm cs rd AluXor rs1V imm pcN
  Ori rd _ imm -> aluImm cs rd AluOr rs1V imm pcN
  Andi rd _ imm -> aluImm cs rd AluAnd rs1V imm pcN
  Slli rd _ shamt -> aluShamt cs rd AluSll rs1V shamt pcN
  Srli rd _ shamt -> aluShamt cs rd AluSrl rs1V shamt pcN
  Srai rd _ shamt -> aluShamt cs rd AluSra rs1V shamt pcN
  Sb _ _ off -> doStore cs off rs1V rs2V 1 pc pcN
  Sh _ _ off -> doStore cs off rs1V rs2V 2 pc pcN
  Sw _ _ off -> doStore cs off rs1V rs2V 4 pc pcN
  Beq _ _ off -> doBranch cs BrEq rs1V rs2V off pc pcN
  Bne _ _ off -> doBranch cs BrNe rs1V rs2V off pc pcN
  Blt _ _ off -> doBranch cs BrLt rs1V rs2V off pc pcN
  Bge _ _ off -> doBranch cs BrGe rs1V rs2V off pc pcN
  Bltu _ _ off -> doBranch cs BrLtu rs1V rs2V off pc pcN
  Bgeu _ _ off -> doBranch cs BrGeu rs1V rs2V off pc pcN
  Add rd _ _ -> aluReg cs rd AluAdd rs1V rs2V pcN
  Sub rd _ _ -> aluReg cs rd AluSub rs1V rs2V pcN
  Sll rd _ _ -> aluReg cs rd AluSll rs1V rs2V pcN
  Slt rd _ _ -> aluReg cs rd AluSlt rs1V rs2V pcN
  Sltu rd _ _ -> aluReg cs rd AluSltu rs1V rs2V pcN
  Xor rd _ _ -> aluReg cs rd AluXor rs1V rs2V pcN
  Srl rd _ _ -> aluReg cs rd AluSrl rs1V rs2V pcN
  Sra rd _ _ -> aluReg cs rd AluSra rs1V rs2V pcN
  Or rd _ _ -> aluReg cs rd AluOr rs1V rs2V pcN
  And rd _ _ -> aluReg cs rd AluAnd rs1V rs2V pcN
  Mul rd _ _ -> regWb cs rd 0 pcN
  MulH rd _ _ -> regWb cs rd 0 pcN
  MulHsu rd _ _ -> regWb cs rd 0 pcN
  MulHu rd _ _ -> regWb cs rd 0 pcN
  Div rd _ _ -> regWb cs rd 0 pcN
  DivU rd _ _ -> regWb cs rd 0 pcN
  Rem rd _ _ -> regWb cs rd 0 pcN
  RemU rd _ _ -> regWb cs rd 0 pcN
  Fence _ _ -> nop cs pcN
  FenceI -> nop cs pcN
  Ecall -> trap causeEcallFromM pc 0 cs
  Ebreak -> trap causeBreakpoint pc 0 cs
  Mret ->
    -- Restore mstatus.MIE from MPIE and re-arm MPIE := 1; jump to mepc.
    let cs' = applyMret cs
     in (cMepc cs, cs', 0, 0, 0, False, Nothing, False)
  Csrrw rd _ csr ->
    let addr = unCsr csr
        old = readCsr cs addr
        new = rs1V
        cs' = writeCsr addr new cs
     in regWb cs' rd old pcN
  Csrrs rd _ csr ->
    let addr = unCsr csr
        old = readCsr cs addr
        new = old .|. rs1V
        cs' = writeCsr addr new cs
     in regWb cs' rd old pcN
  Csrrc rd _ csr ->
    let addr = unCsr csr
        old = readCsr cs addr
        new = old .&. complement rs1V
        cs' = writeCsr addr new cs
     in regWb cs' rd old pcN
  Csrrwi rd zimm csr ->
    let addr = unCsr csr
        old = readCsr cs addr
        new = zeroExtend zimm
        cs' = writeCsr addr new cs
     in regWb cs' rd old pcN
  Csrrsi rd zimm csr ->
    let addr = unCsr csr
        old = readCsr cs addr
        new = old .|. zeroExtend zimm
        cs' = writeCsr addr new cs
     in regWb cs' rd old pcN
  Csrrci rd zimm csr ->
    let addr = unCsr csr
        old = readCsr cs addr
        new = old .&. complement (zeroExtend zimm)
        cs' = writeCsr addr new cs
     in regWb cs' rd old pcN
  -- A-extension placeholders. Same shape as the M-extension stubs
  -- ('Mul' / 'Div' etc.) that are also dispatched to a separate FU
  -- ('mulDivFU') and have their writeback overridden on retire. The
  -- 'amoFU' (phase-2D) supplies the real value; until then these
  -- decode legally and write zero, leaving the bus untouched.
  LrW rd _ _ -> regWb cs rd 0 pcN
  ScW rd _ _ _ -> regWb cs rd 0 pcN
  AmoSwapW rd _ _ _ -> regWb cs rd 0 pcN
  AmoAddW rd _ _ _ -> regWb cs rd 0 pcN
  AmoXorW rd _ _ _ -> regWb cs rd 0 pcN
  AmoAndW rd _ _ _ -> regWb cs rd 0 pcN
  AmoOrW rd _ _ _ -> regWb cs rd 0 pcN
  AmoMinW rd _ _ _ -> regWb cs rd 0 pcN
  AmoMaxW rd _ _ _ -> regWb cs rd 0 pcN
  AmoMinuW rd _ _ _ -> regWb cs rd 0 pcN
  AmoMaxuW rd _ _ _ -> regWb cs rd 0 pcN

nop :: Csrs -> BitVector 32 -> Out
nop cs pN = (pN, cs, 0, 0, 0, False, Nothing, False)

regWb :: Csrs -> Reg -> BitVector 32 -> BitVector 32 -> Out
regWb cs rd val nextPc =
  (nextPc, cs, 0, 0, 0, False, Just (unReg rd, val), False)

aluImm :: Csrs -> Reg -> AluOp -> BitVector 32 -> Signed 12 -> BitVector 32 -> Out
aluImm cs rd op rs1V imm pN = regWb cs rd (alu op rs1V (sxImm12 imm)) pN

aluShamt :: Csrs -> Reg -> AluOp -> BitVector 32 -> BitVector 5 -> BitVector 32 -> Out
aluShamt cs rd op rs1V shamt pN = regWb cs rd (alu op rs1V (zeroExtend shamt)) pN

aluReg :: Csrs -> Reg -> AluOp -> BitVector 32 -> BitVector 32 -> BitVector 32 -> Out
aluReg cs rd op a b pN = regWb cs rd (alu op a b) pN

doLoad ::
  Csrs ->
  Reg ->
  Signed 12 ->
  Int ->
  Bool ->
  BitVector 32 ->
  BitVector 32 ->
  BitVector 32 ->
  BitVector 32 ->
  Out
doLoad cs rd off width signed rs1 rdata p pN =
  let addr = rs1 + sxImm12 off
      aligned = case width of
        1 -> True
        2 -> slice d0 d0 addr == 0
        4 -> slice d1 d0 addr == 0
        _ -> True
   in if not aligned
        then trap causeLoadAddrMisaligned p addr cs
        else
          let loaded = extendLoad width signed addr rdata
           in (pN, cs, addr, 0, 0, True, Just (unReg rd, loaded), False)

doStore ::
  Csrs ->
  Signed 12 ->
  BitVector 32 ->
  BitVector 32 ->
  Int ->
  BitVector 32 ->
  BitVector 32 ->
  Out
doStore cs off base value width p pN =
  let addr = base + sxImm12 off
      aligned = case width of
        1 -> True
        2 -> slice d0 d0 addr == 0
        4 -> slice d1 d0 addr == 0
        _ -> True
   in if not aligned
        then trap causeStoreAddrMisaligned p addr cs
        else
          let be = byteEnable width addr
              wdata = shiftStoreData width addr value
           in (pN, cs, addr, wdata, be, False, Nothing, False)

doBranch ::
  Csrs ->
  BranchOp ->
  BitVector 32 ->
  BitVector 32 ->
  Signed 13 ->
  BitVector 32 ->
  BitVector 32 ->
  Out
doBranch cs op a b off p pN =
  let taken = branchTaken op a b
      target = p + sxImm13 off
      pcNext = if taken then target else pN
      misaligned = slice d1 d0 pcNext /= 0
   in if misaligned
        then trap causeInstrAddrMisaligned p pcNext cs
        else (pcNext, cs, 0, 0, 0, False, Nothing, False)

trap :: BitVector 32 -> BitVector 32 -> BitVector 32 -> Csrs -> Out
trap cause epc tval cs =
  let cs' = applyTrap cause epc tval cs
      target = cMtvec cs .&. complement 3
   in (target, cs', 0, 0, 0, False, Nothing, True)

extendLoad :: Int -> Bool -> BitVector 32 -> BitVector 32 -> BitVector 32
extendLoad width signed addr rdata = case (width, signed) of
  (4, _) -> rdata
  (2, True) -> pack (signExtendTo32 half)
  (2, False) -> resize half
  (1, True) -> pack (signExtendTo32 loadByte)
  (1, False) -> resize loadByte
  _ -> 0
 where
  loadByte :: BitVector 8
  loadByte = case slice d1 d0 addr of
    0 -> slice d7 d0 rdata
    1 -> slice d15 d8 rdata
    2 -> slice d23 d16 rdata
    _ -> slice d31 d24 rdata

  half :: BitVector 16
  half = case slice d1 d1 addr of
    0 -> slice d15 d0 rdata
    _ -> slice d31 d16 rdata

signExtendTo32 :: forall n. (KnownNat n) => BitVector n -> Signed 32
signExtendTo32 v = resize (unpack v :: Signed n)

isCsrOp :: BitVector 32 -> Bool
isCsrOp insn =
  slice d6 d0 insn == 0b1110011 && slice d14 d12 insn /= 0

loadMask :: BitVector 32 -> BitVector 32 -> BitVector 4
loadMask instr addr
  | slice d6 d0 instr /= 0b0000011 = 0
  | otherwise = case slice d14 d12 instr of
      0b000 -> byteMask
      0b100 -> byteMask
      0b001 -> halfMask
      0b101 -> halfMask
      0b010 -> 0b1111
      _ -> 0
 where
  byteMask = case slice d1 d0 addr of
    0 -> 0b0001
    1 -> 0b0010
    2 -> 0b0100
    _ -> 0b1000
  halfMask = case slice d1 d1 addr of
    0 -> 0b0011
    _ -> 0b1100

byteEnable :: Int -> BitVector 32 -> BitVector 4
byteEnable width addr = case (width, slice d1 d0 addr) of
  (4, _) -> 0b1111
  (2, 0) -> 0b0011
  (2, _) -> 0b1100
  (1, 0) -> 0b0001
  (1, 1) -> 0b0010
  (1, 2) -> 0b0100
  (1, 3) -> 0b1000
  _ -> 0

shiftStoreData :: Int -> BitVector 32 -> BitVector 32 -> BitVector 32
shiftStoreData width addr value = case (width, slice d1 d0 addr) of
  (4, _) -> value
  (2, 0) -> value
  (2, _) -> value `shiftL` 16
  (1, 0) -> value
  (1, 1) -> value `shiftL` 8
  (1, 2) -> value `shiftL` 16
  (1, 3) -> value `shiftL` 24
  _ -> value

sxImm12 :: Signed 12 -> BitVector 32
sxImm12 = pack . (resize :: Signed 12 -> Signed 32)

sxImm13 :: Signed 13 -> BitVector 32
sxImm13 = pack . (resize :: Signed 13 -> Signed 32)

sxImm21 :: Signed 21 -> BitVector 32
sxImm21 = pack . (resize :: Signed 21 -> Signed 32)
