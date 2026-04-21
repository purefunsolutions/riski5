-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : Riski5.Core
Description : 2-stage pipelined RV32I + RV32M core with M-mode CSRs + traps.

Two overlapping pipeline stages:

  * __F (fetch)__: the @pcFetch@ register presents the next
    instruction address to the imem input port. imem is expected
    to have synchronous-read semantics — the instruction for
    @pcFetch@ at cycle N arrives on @imemData@ at cycle N+1.

  * __X (execute)__: combinational decode + regfile read + ALU +
    branch-compare + CSR access + memory-access issue + writeback,
    all within one clock using @pcExec@ (= previous cycle's
    @pcFetch@) and the current @imemData@ which by then reflects
    that @pcExec@ address.

Back-to-back sequential instructions retire at 1/clock in steady
state. The only source of bubbles is a non-sequential PC change
(taken branch, JAL, JALR, MRET, trap) which squashes the
pre-fetched instruction on the next cycle.

== RV32M via multi-cycle functional unit

Phase 2B wires an iterative multiplier + divider FU alongside the
ALU (see "Riski5.Core.FU.MulDiv"). When an RV32M op enters X,
@mdActiveS@ goes high; the FU's combinational @mdBusy@ output is
OR'd with the external @stallS@ into @stallInternal@, which gates
every sequential register in the core. The op stays in X for
~34 clocks while the FU iterates; when the FU reaches @MdDone@,
@mdBusy@ drops, the writeback mux (@writeBackWithMd@) substitutes
the FU's 32-bit result for the handler's placeholder value, and
the op retires through the same RVFI path as any other integer
instruction. @tiny32@ (@extM = False@) and @tiny32M@ (@extM =
True@) share this kernel — the FU sits idle on programs that
never issue M ops.

== Pipeline control

  * __Stall__ (input): freezes every sequential register so
    multi-cycle memory slaves can back-pressure cleanly.

  * __Squash__: @squashNext@ register fires the cycle after this
    cycle's X takes a PC change. On the squash cycle, @imemData@
    is replaced with NOP in decode; regfile writeback, CSR write,
    and dmem byte-enable are all suppressed.

== Trap handling (M-mode only)

  * Illegal instruction: @mcause = 2@, @mtval = instruction bits@.
  * ECALL from M-mode: @mcause = 11@, @mtval = 0@.
  * EBREAK: @mcause = 3@, @mtval = 0@.
  * Load / store address misaligned: @mcause = 4@ / @6@,
    @mtval = faulting address@.

On any trap: @mepc = pcExec@, next fetch redirected to
@mtvec.base@, writeback suppressed. @MRET@ copies @mepc@ back
into @pcFetch@ via the non-sequential-PC path.
-}
module Riski5.Core (
  core,
) where

import Clash.Prelude hiding (And, Xor, not, (!!), (&&), (||))
import Riski5.ALU (AluOp (..), BranchOp (..), alu, branchTaken)
import Riski5.Core.FU.MulDiv (MdOp (..), isMdOp, mdOpOf, mulDivFU)
import Riski5.CSR (
  Csrs (..),
  applyTrap,
  causeBreakpoint,
  causeEcallFromM,
  causeIllegalInstr,
  causeInstrAddrMisaligned,
  causeLoadAddrMisaligned,
  causeStoreAddrMisaligned,
  initCsrs,
  readCsr,
  writeCsr,
 )
import Riski5.Decode (decode)
import Riski5.ISA
import Riski5.Regfile (regfile)
import Riski5.Rvfi (Rvfi (..), RvfiCsr (..))

{- |
Top-level core entity. Inputs are the instruction word at the
current PC and the data-memory read response; outputs are the
addresses, write data, and enable signals the memory subsystem
needs plus the observability write-back stream. CSR state is
internal and doesn't leak through the interface.
-}
core ::
  forall dom.
  (HiddenClockResetEnable dom) =>
  -- | instruction word at the current PC (assumed same-cycle read)
  Signal dom (BitVector 32) ->
  -- | data memory read response (assumed same-cycle read)
  Signal dom (BitVector 32) ->
  {- | back-pressure: when 'True', freeze all sequential state (PC,
  CSR, regfile write). Lets multi-cycle slaves (e.g. SRAM) stall
  the core until their data is valid.
  -}
  Signal dom Bool ->
  {- | @(pcFetch, pcExec, dmemAddr, dmemWdata, dmemByteEn,
  dmemReadEn, writeBack)@.

  Two PC-side outputs:

    * @pcFetch@ drives the imem address input — the address being
      *fetched* this cycle (= next instruction to execute).
    * @pcExec@ is the address of the instruction currently being
      *executed* in the X stage (one cycle behind @pcFetch@ in
      steady state). Tests that assert against the PC of a
      retiring instruction should use @pcExec@.

  @writeBack@ is @Just (rd, value)@ on cycles that commit a
  register-file write, @Nothing@ otherwise (and always @Nothing@ on
  a trap / stalled / squashed cycle).

  The final 'Rvfi' output bundles the observability signals the
  [YosysHQ\/riscv-formal](https://github.com/YosysHQ/riscv-formal)
  harness consumes. Callers that don't want RVFI (synthesis,
  Clash-only tests) just discard it; the cost of carrying it on
  the core output is a handful of unused signals.
  -}
  ( Signal dom (BitVector 32) -- pcFetch — drives imem address
  , Signal dom (BitVector 32) -- pcExec — PC of the retiring instruction
  , Signal dom (BitVector 32) -- dmem address
  , Signal dom (BitVector 32) -- dmem write data
  , Signal dom (BitVector 4) -- per-byte write-enable (0 = no write)
  , Signal dom Bool -- read enable
  , Signal dom (Maybe (BitVector 5, BitVector 32)) -- regfile write
  , Signal dom Rvfi -- RVFI observability bundle
  )
core imemData dmemRData stallS =
  ( pcFetch
  , pcExec
  , dmemAddr
  , dmemWdata
  , dmemBeGated
  , dmemRen
  , writeBackGated
  , rvfiS
  )
 where
  -- ----- Internal stall ---------------------------------------------
  -- External back-pressure from the bus (SRAM / Avalon-MM slaves)
  -- OR'd with the MulDiv FU's busy flag. Every sequential register
  -- in the core gates on this combined signal: the M op remains
  -- in X until the FU retires, exactly as SRAM reads do today.
  stallInternal :: Signal dom Bool
  stallInternal = (\s m -> s || m) <$> stallS <*> mdBusyS

  -- ----- F-stage: pcFetch drives imem --------------------------------
  pcFetch :: Signal dom (BitVector 32)
  pcFetch = register 0 (mux stallInternal pcFetch pcFetchNext)

  -- ----- X-stage PC: one cycle behind pcFetch ------------------------
  pcExec :: Signal dom (BitVector 32)
  pcExec = register 0 (mux stallInternal pcExec pcFetch)

  -- ----- Squash register ---------------------------------------------
  -- True on the cycle immediately after this cycle's X took a
  -- non-sequential PC change. While squashNext is True, the
  -- fetched-but-stale instruction in imemData is replaced with NOP
  -- in decode and all side effects (writeback, CSR, dmem-write)
  -- are suppressed. Frozen on stall.
  --
  -- Initial value 'True' also covers the very first cycle after
  -- reset: @blockRam@ (and the register-wrapped imem in test
  -- harnesses) has an undefined / init output on cycle 0 before
  -- the first real read has propagated. Squash-on-reset means
  -- that garbage never reaches decode.
  squashNext :: Signal dom Bool
  squashNext = register True (mux stallInternal squashNext pcChangedS)

  -- ----- CSR state (frozen on stall or squash) -----------------------
  csrs :: Signal dom Csrs
  csrs =
    register
      initCsrs
      ( (\stall sq next cur -> if stall || sq then cur else next)
          <$> stallInternal
          <*> squashNext
          <*> csrsNext
          <*> csrs
      )

  -- Stall from the previous cycle. Using this (not the current
  -- @stallInternal@) to gate the held-imem logic avoids a
  -- combinational cycle: if @effectiveImemS@ depended on the
  -- current cycle's @stallInternal@, decode output → @mdActiveS@
  -- → @mdBusyS@ → @stallInternal@ → @effectiveImemS@ would be
  -- a loop.
  stallPrev :: Signal dom Bool
  stallPrev = register False stallInternal

  -- F/X pipeline latch. The external imem (blockRam or the
  -- register-wrapped Vec lookup in tests) has a 1-cycle read delay,
  -- so @imemData_K@ reflects @pcFetch_{K-1}@. Under normal flow
  -- this is exactly right: @pcExec_K = pcFetch_{K-1}@. But when
  -- stall asserts, @pcFetch@ has already moved on (it only stops
  -- advancing once stall goes high, which is AFTER the clock edge
  -- that updated it), so @imemData@ on subsequent stalled cycles
  -- shows the wrong instruction for the frozen @pcExec@.
  --
  -- Capture @imemData@ into @heldImemS@ on cycles where the last
  -- cycle was NOT stalled (so the capture is the instruction that
  -- was in flight when stall started). On any cycle where the
  -- previous cycle was stalled, switch decode to the held value.
  -- This covers the whole stall window plus the first cycle after
  -- stall releases (when the core finally retires the held
  -- instruction).
  heldImemS :: Signal dom (BitVector 32)
  heldImemS = regEn 0x0000_0013 (not <$> stallPrev) imemData

  -- Effective instruction word for the X stage: NOP on squash so
  -- the stale pre-fetched-after-branch doesn't reach decode; held
  -- value on any cycle where last cycle was stalled; current
  -- imemData otherwise.
  effectiveImemS :: Signal dom (BitVector 32)
  effectiveImemS =
    ( \sq useHeld d held ->
        if sq
          then 0x0000_0013
          else if useHeld then held else d
    )
      <$> squashNext
      <*> stallPrev
      <*> imemData
      <*> heldImemS

  -- Suppress regfile writeback on stall or squash. The wrapped
  -- @writeBackWithMd@ — not the raw @writeBack@ — replaces the
  -- handler's placeholder value for RV32M ops with the FU's
  -- real 32-bit result on the retire cycle.
  writeBackGated =
    (\stall sq wb -> if stall || sq then Nothing else wb)
      <$> stallInternal
      <*> squashNext
      <*> writeBackWithMd

  -- Suppress memory-write byte-enable only on squash. A squashed
  -- fake-store must not commit. But we MUST NOT gate on stall
  -- too: an Avalon-MM-style slave (e.g. the Altera JTAG UART IP)
  -- drives @waitrequest@ combinationally as a function of the
  -- master's @chipselect@ + @write_n@ + (be != 0), and the master
  -- stalls as a function of @waitrequest@. Gating be=0 while
  -- stalled therefore introduces the oscillation
  --   stall=1 → be=0 → waitrequest=0 → stall=0 → be=be_native
  --          → waitrequest=1 → stall=1 → …
  -- — a combinational loop Verilator flags as UNOPTFLAT. The
  -- Avalon-MM protocol already guarantees single-commit per
  -- transaction: the slave latches @av_writedata@ once on the
  -- cycle its internal ready condition is met, regardless of how
  -- many cycles the master holds. SRAM writes don't stall at all
  -- (the SRAM controller returns ready=True for writes), and
  -- SRAM reads don't use @be@, so dropping the stall gating on
  -- @dmemBe@ is safe across all phase-1 slaves.
  dmemBeGated =
    (\sq be -> if sq then 0 else be)
      <$> squashNext
      <*> dmemBe

  -- ----- Decode + operand extraction ---------------------------------
  mInstr :: Signal dom (Maybe Instr)
  mInstr = decode <$> effectiveImemS

  rs1Addr, rs2Addr :: Signal dom (BitVector 5)
  rs1Addr = slice d19 d15 <$> effectiveImemS
  rs2Addr = slice d24 d20 <$> effectiveImemS

  (rs1V, rs2V) = regfile rs1Addr rs2Addr writeBackGated

  -- ----- RV32M functional unit --------------------------------------
  -- The MulDiv FU runs iteratively alongside decode + ALU. On the
  -- first cycle an RV32M op enters X, 'mdActiveS' goes high; the
  -- FU latches the operands and transitions Idle → Busy; its
  -- @busy@ output feeds @stallInternal@ above, freezing every
  -- sequential register in the core. When the FU reaches 'MdDone'
  -- the busy flag drops, the writeback mux ('writeBackWithMd')
  -- swaps in the 32-bit result, and the M op retires normally.
  mdActiveS :: Signal dom Bool
  mdActiveS =
    ( \mi -> case mi of
        Just i -> isMdOp i
        Nothing -> False
    )
      <$> mInstr

  mdOpS :: Signal dom MdOp
  mdOpS =
    ( \mi -> case mi of
        Just i -> mdOpOf i
        Nothing -> MdMul -- safe default — FU ignores inputs outside Idle → Busy
    )
      <$> mInstr

  mdBusyS :: Signal dom Bool
  mdResultS :: Signal dom (BitVector 32)
  (mdBusyS, mdResultS) = mulDivFU mdActiveS mdOpS rs1V rs2V

  -- Replace the handler's placeholder writeback value with the
  -- FU's real result on cycles when an M op is retiring. The rd
  -- field comes from the handler (latched from the instruction
  -- word); the value comes from the FU.
  writeBackWithMd :: Signal dom (Maybe (BitVector 5, BitVector 32))
  writeBackWithMd =
    ( \isMd mdR wb -> case (isMd, wb) of
        (True, Just (rd, _)) -> Just (rd, mdR)
        _ -> wb
    )
      <$> mdActiveS
      <*> mdResultS
      <*> writeBack

  -- ----- Combinational dispatch --------------------------------------
  bundledOut =
    handleInstr
      <$> pcExec
      <*> effectiveImemS
      <*> mInstr
      <*> rs1V
      <*> rs2V
      <*> dmemRData
      <*> csrs

  (pcNextRaw, csrsNext, dmemAddr, dmemWdata, dmemBe, dmemRen, writeBack, trapFiredS) =
    unbundle bundledOut

  -- pcFetchNext advances F one step ahead of X:
  --   * sequential (pcNextRaw == pcExec + 4): pcFetch + 4 so the
  --     next-next instruction is queued;
  --   * non-sequential (branch / JAL / JALR / MRET / trap):
  --     redirect F straight to the target.
  pcFetchNext =
    ( \pExec pcRaw pf ->
        if pcRaw == pExec + 4
          then pf + 4
          else pcRaw
    )
      <$> pcExec
      <*> pcNextRaw
      <*> pcFetch

  -- True when this cycle's X instruction caused a non-sequential
  -- PC change. Becomes the squashNext register value for cycle N+1.
  pcChangedS :: Signal dom Bool
  pcChangedS = (\pExec pcRaw -> pcRaw /= pExec + 4) <$> pcExec <*> pcNextRaw

  -- ----- RVFI observability (Riski5.Rvfi) ----------------------------
  -- See docs/verification.md §Layer 2 for the contract. These
  -- signals feed Riski5.FormalTop which emits the flat rvfi_*
  -- ports YosysHQ/riscv-formal's harness consumes.
  --
  -- rvfi_valid: an instruction retires iff we're neither stalled
  -- (multi-cycle slave hasn't released the bus yet) nor squashing
  -- (pre-fetched instruction past a branch). A trapping instruction
  -- also retires — rvfi_trap flags it separately.
  rvfiValidS :: Signal dom Bool
  rvfiValidS = (\st sq -> not st && not sq) <$> stallInternal <*> squashNext

  -- Monotonic retire counter. Latches once per retire cycle.
  rvfiOrderS :: Signal dom (BitVector 64)
  rvfiOrderS =
    register
      0
      ( (\v o -> if v then o + 1 else o)
          <$> rvfiValidS
          <*> rvfiOrderS
      )

  -- rfIntr: high on the first instruction executed in a trap
  -- handler, i.e. this retire's pc_rdata /= the previous retire's
  -- pc_wdata. Needs one cycle of history — register the previous
  -- retire's pc_wdata.
  prevPcWdataS :: Signal dom (BitVector 32)
  prevPcWdataS =
    register
      0
      ( (\v pw prev -> if v then pw else prev)
          <$> rvfiValidS
          <*> pcNextRaw
          <*> prevPcWdataS
      )

  rvfiIntrS :: Signal dom Bool
  rvfiIntrS =
    (\v pr prev -> v && pr /= prev)
      <$> rvfiValidS
      <*> pcExec
      <*> prevPcWdataS

  -- rfRd / rfRdWdata: masked so that rd_wdata is zero when rd_addr
  -- is zero. The RVFI spec requires this; the regfile already
  -- ignores writes to x0, so the architectural state is right,
  -- but the observability field must also reflect zero.
  rvfiRdAddrS, rvfiRdWdataS :: Signal dom (BitVector 32)
  rvfiRdAddrS = maybe 0 (resize . fst) <$> writeBackWithMd
  rvfiRdWdataS =
    ( \mwb -> case mwb of
        Just (rd, val) | rd /= 0 -> val
        _ -> 0
    )
      <$> writeBackWithMd

  -- Memory-read byte mask: bytes of rfMemRdata the instruction
  -- actually consumed. Derived from the instruction's opcode +
  -- funct3 + address-low-bits; zero when the instruction isn't a
  -- load. The shape mirrors 'byteEnable' (which is for stores).
  rvfiMemRmaskS :: Signal dom (BitVector 4)
  rvfiMemRmaskS =
    (\ren insn addr -> if ren then loadMask insn addr else 0)
      <$> dmemRen
      <*> effectiveImemS
      <*> dmemAddr

  -- rfMemAddr must be word-aligned per the RVFI spec under
  -- RISCV_FORMAL_ALIGNED_MEM — riscv-formal's insn_{lb,lh,lbu,lhu,sb,sh}
  -- checks all use `spec_mem_addr = addr & ~3`. Our core's internal
  -- @dmemAddr@ is the raw byte address for sub-word accesses, so
  -- we mask it here at the observability tap. LW / SW addresses
  -- are already aligned (or the core traps), so the mask is a
  -- no-op for them.
  rvfiMemAddrS :: Signal dom (BitVector 32)
  rvfiMemAddrS = (\addr -> addr .&. complement 3) <$> dmemAddr

  -- ----- CSR RVFI (Zicsr extension of the spec) -------------------
  -- For each CSR our core implements ('Riski5.CSR'), compute the
  -- per-retire @{r,w}mask@ + @{r,w}data@ block the riscv-formal
  -- @csrw_\*@ / @csrc_\*_any@ checks consume.
  --
  -- Read-mask = all-1s iff this retire is a CSR instruction
  -- (opcode SYSTEM 0b1110011 with @funct3 /= 0@, i.e. any of
  -- CSRRW/S/C/WI/SI/CI) targeting this particular CSR. We always
  -- return the CSR's architectural value in @rdata@, so
  -- over-reporting @rmask@ on retires that don't actually read
  -- the CSR is harmless — the check only asserts that the bits
  -- in @rmask@ match the architectural value, and they always
  -- do.
  --
  -- Write-mask = all-1s iff a CSR instruction targeting this CSR
  -- retires, /or/ a trap retires that writes this CSR
  -- (@mcause@ / @mepc@ / @mtval@ under 'applyTrap'). Same
  -- conservative-over-reporting rationale: the check asserts
  -- @wdata@ matches the post-state, which we always populate
  -- from @csrsNext@.
  --
  -- @rdata@ / @wdata@ come straight from the pre- and post-state
  -- 'Csrs' records, so the per-CSR masks are the only
  -- instruction-dependent logic.
  csrRetireAddrS :: Signal dom (Bool, BitVector 12)
  csrRetireAddrS =
    (\v insn -> (v && isCsrOp insn, slice d31 d20 insn))
      <$> rvfiValidS
      <*> effectiveImemS

  -- Per-CSR write-mask helper. Set on any CSR instruction
  -- targeting this CSR, or (for the trap-written CSRs) on any
  -- cycle where the core latched a trap.
  csrWmask ::
    -- | this CSR's 12-bit address
    BitVector 12 ->
    -- | is this CSR written on trap (mcause/mepc/mtval only)?
    Bool ->
    Signal dom (BitVector 32)
  csrWmask csrAddr writtenOnTrap =
    ( \(isCsrHere, tAddr) valid trapped ->
        if (isCsrHere && tAddr == csrAddr)
          || (writtenOnTrap && valid && trapped)
          then maxBound
          else 0
    )
      <$> csrRetireAddrS
      <*> rvfiValidS
      <*> trapFiredS

  csrRmask :: BitVector 12 -> Signal dom (BitVector 32)
  csrRmask csrAddr =
    ( \(isCsrHere, tAddr) ->
        if isCsrHere && tAddr == csrAddr then maxBound else 0
    )
      <$> csrRetireAddrS

  mkCsrBlock ::
    -- | CSR address
    BitVector 12 ->
    -- | is this CSR written on trap?
    Bool ->
    -- | pre-state getter
    (Csrs -> BitVector 32) ->
    -- | post-state getter (same signature)
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
      <$> csrRmask csrAddr
      <*> csrWmask csrAddr writtenOnTrap
      <*> (getR <$> csrs)
      <*> (getW <$> csrsNext)

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
    ( \valid order insn trapped intr pcR pcW rs1V' rs2V' rdA rdW
       mAddr mRm mWm mRd mWd
       csrSt csrTv csrEpc csrCs csrTval csrScr ->
          Rvfi
            { rfValid = if valid then 1 else 0
            , rfOrder = order
            , rfInsn = insn
            , rfTrap = if trapped && valid then 1 else 0
            , rfHalt = 0
            , rfIntr = if intr then 1 else 0
            , rfMode = 3
            , rfIxl = 1
            , rfRs1Addr = slice d19 d15 insn
            , rfRs2Addr = slice d24 d20 insn
            , rfRs1Rdata = rs1V'
            , rfRs2Rdata = rs2V'
            , rfRdAddr = resize rdA
            , rfRdWdata = rdW
            , rfMemAddr = mAddr
            , rfMemRmask = mRm
            , rfMemWmask = mWm
            , rfMemRdata = mRd
            , rfMemWdata = mWd
            , rfPcRdata = pcR
            , rfPcWdata = pcW
            , rfCsrMstatus = csrSt
            , rfCsrMtvec = csrTv
            , rfCsrMepc = csrEpc
            , rfCsrMcause = csrCs
            , rfCsrMtval = csrTval
            , rfCsrMscratch = csrScr
            }
    )
      <$> rvfiValidS
      <*> rvfiOrderS
      <*> effectiveImemS
      <*> trapFiredS
      <*> rvfiIntrS
      <*> pcExec
      <*> pcNextRaw
      <*> rs1V
      <*> rs2V
      <*> rvfiRdAddrS
      <*> rvfiRdWdataS
      <*> rvfiMemAddrS
      <*> rvfiMemRmaskS
      <*> dmemBeGated
      <*> dmemRData
      <*> dmemWdata
      <*> rvfiCsrMstatusS
      <*> rvfiCsrMtvecS
      <*> rvfiCsrMepcS
      <*> rvfiCsrMcauseS
      <*> rvfiCsrMtvalS
      <*> rvfiCsrMscratchS

-- * Combinational dispatch -----------------------------------------

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
  BitVector 32 -> -- raw instruction word (for mtval on illegal)
  Maybe Instr ->
  BitVector 32 ->
  BitVector 32 ->
  BitVector 32 ->
  Csrs ->
  Out
handleInstr pc rawInstr Nothing _ _ _ cs =
  -- Illegal instruction → trap.
  trap causeIllegalInstr pc rawInstr cs
handleInstr pc _ (Just instr) rs1V rs2V memRData cs = case instr of
  -- ----- U-type ---------------------------------------------------
  Lui rd imm ->
    let res = imm ++# (0 :: BitVector 12)
     in regWb cs rd res (pc + 4)
  Auipc rd imm ->
    let res = pc + (imm ++# (0 :: BitVector 12))
     in regWb cs rd res (pc + 4)
  -- ----- J-type (JAL) --------------------------------------------
  Jal rd off ->
    let target = pc + sxImm21 off
     in if slice d1 d0 target /= 0
          then trap causeInstrAddrMisaligned pc target cs
          else regWb cs rd (pc + 4) target
  -- ----- I-type: JALR --------------------------------------------
  Jalr rd _ off ->
    let target = (rs1V + sxImm12 off) .&. complement 1
     in if slice d1 d0 target /= 0
          then trap causeInstrAddrMisaligned pc target cs
          else regWb cs rd (pc + 4) target
  -- ----- I-type: loads -------------------------------------------
  Lb rd _ off -> doLoad cs rd off 1 True rs1V memRData pc
  Lh rd _ off -> doLoad cs rd off 2 True rs1V memRData pc
  Lw rd _ off -> doLoad cs rd off 4 False rs1V memRData pc
  Lbu rd _ off -> doLoad cs rd off 1 False rs1V memRData pc
  Lhu rd _ off -> doLoad cs rd off 2 False rs1V memRData pc
  -- ----- I-type: arithmetic / logical imms -----------------------
  Addi rd _ imm -> aluImm cs rd AluAdd rs1V imm pc
  Slti rd _ imm -> aluImm cs rd AluSlt rs1V imm pc
  Sltiu rd _ imm -> aluImm cs rd AluSltu rs1V imm pc
  Xori rd _ imm -> aluImm cs rd AluXor rs1V imm pc
  Ori rd _ imm -> aluImm cs rd AluOr rs1V imm pc
  Andi rd _ imm -> aluImm cs rd AluAnd rs1V imm pc
  Slli rd _ shamt -> aluShamt cs rd AluSll rs1V shamt pc
  Srli rd _ shamt -> aluShamt cs rd AluSrl rs1V shamt pc
  Srai rd _ shamt -> aluShamt cs rd AluSra rs1V shamt pc
  -- ----- S-type: stores ------------------------------------------
  Sb _ _ off -> doStore cs off rs1V rs2V 1 pc
  Sh _ _ off -> doStore cs off rs1V rs2V 2 pc
  Sw _ _ off -> doStore cs off rs1V rs2V 4 pc
  -- ----- B-type: branches ---------------------------------------
  Beq _ _ off -> doBranch cs BrEq rs1V rs2V off pc
  Bne _ _ off -> doBranch cs BrNe rs1V rs2V off pc
  Blt _ _ off -> doBranch cs BrLt rs1V rs2V off pc
  Bge _ _ off -> doBranch cs BrGe rs1V rs2V off pc
  Bltu _ _ off -> doBranch cs BrLtu rs1V rs2V off pc
  Bgeu _ _ off -> doBranch cs BrGeu rs1V rs2V off pc
  -- ----- R-type --------------------------------------------------
  Add rd _ _ -> aluReg cs rd AluAdd rs1V rs2V pc
  Sub rd _ _ -> aluReg cs rd AluSub rs1V rs2V pc
  Sll rd _ _ -> aluReg cs rd AluSll rs1V rs2V pc
  Slt rd _ _ -> aluReg cs rd AluSlt rs1V rs2V pc
  Sltu rd _ _ -> aluReg cs rd AluSltu rs1V rs2V pc
  Xor rd _ _ -> aluReg cs rd AluXor rs1V rs2V pc
  Srl rd _ _ -> aluReg cs rd AluSrl rs1V rs2V pc
  Sra rd _ _ -> aluReg cs rd AluSra rs1V rs2V pc
  Or rd _ _ -> aluReg cs rd AluOr rs1V rs2V pc
  And rd _ _ -> aluReg cs rd AluAnd rs1V rs2V pc
  -- ----- RV32M (iterative FU in 'Riski5.Core.FU.MulDiv') -------
  -- The handler returns a placeholder writeback @Just (rd, 0)@
  -- every cycle the M op is in X; the core's 'writeBackWithMd'
  -- mux swaps in the FU's real result on the retire cycle. pc
  -- advances by 4 sequentially — the stall path keeps X frozen
  -- until the FU is ready, so the "advance" only takes effect
  -- on the retire cycle.
  Mul rd _ _ -> regWb cs rd 0 (pc + 4)
  MulH rd _ _ -> regWb cs rd 0 (pc + 4)
  MulHsu rd _ _ -> regWb cs rd 0 (pc + 4)
  MulHu rd _ _ -> regWb cs rd 0 (pc + 4)
  Div rd _ _ -> regWb cs rd 0 (pc + 4)
  DivU rd _ _ -> regWb cs rd 0 (pc + 4)
  Rem rd _ _ -> regWb cs rd 0 (pc + 4)
  RemU rd _ _ -> regWb cs rd 0 (pc + 4)
  -- ----- MISC-MEM (FENCE as no-op until we have caches) ----------
  Fence _ _ -> nop cs pc
  FenceI -> nop cs pc
  -- ----- SYSTEM: environment / trap-return -----------------------
  Ecall -> trap causeEcallFromM pc 0 cs
  Ebreak -> trap causeBreakpoint pc 0 cs
  Mret ->
    -- Return to the saved pc (no xIE/xPIE dance yet — we don't have
    -- interrupt enables to juggle).
    (cMepc cs, cs, 0, 0, 0, False, Nothing, False)
  -- ----- SYSTEM: Zicsr — register-source forms -------------------
  Csrrw rd _ csr ->
    let addr = unCsr csr
        old = readCsr cs addr
        new = rs1V
        cs' = writeCsr addr new cs
     in regWb cs' rd old (pc + 4)
  Csrrs rd _ csr ->
    let addr = unCsr csr
        old = readCsr cs addr
        new = old .|. rs1V
        cs' = writeCsr addr new cs
     in regWb cs' rd old (pc + 4)
  Csrrc rd _ csr ->
    let addr = unCsr csr
        old = readCsr cs addr
        new = old .&. complement rs1V
        cs' = writeCsr addr new cs
     in regWb cs' rd old (pc + 4)
  -- ----- SYSTEM: Zicsr — immediate-source forms ------------------
  Csrrwi rd zimm csr ->
    let addr = unCsr csr
        old = readCsr cs addr
        new = zeroExtend zimm
        cs' = writeCsr addr new cs
     in regWb cs' rd old (pc + 4)
  Csrrsi rd zimm csr ->
    let addr = unCsr csr
        old = readCsr cs addr
        new = old .|. zeroExtend zimm
        cs' = writeCsr addr new cs
     in regWb cs' rd old (pc + 4)
  Csrrci rd zimm csr ->
    let addr = unCsr csr
        old = readCsr cs addr
        new = old .&. complement (zeroExtend zimm)
        cs' = writeCsr addr new cs
     in regWb cs' rd old (pc + 4)

-- * Pure helper outputs ---------------------------------------------

-- | PC advances by 4; no memory access, no regfile write, CSR unchanged.
nop :: Csrs -> BitVector 32 -> Out
nop cs p = (p + 4, cs, 0, 0, 0, False, Nothing, False)

-- | Register writeback (and optionally a non-sequential PC); CSR unchanged.
regWb :: Csrs -> Reg -> BitVector 32 -> BitVector 32 -> Out
regWb cs rd val nextPc =
  (nextPc, cs, 0, 0, 0, False, Just (unReg rd, val), False)

aluImm :: Csrs -> Reg -> AluOp -> BitVector 32 -> Signed 12 -> BitVector 32 -> Out
aluImm cs rd op rs1V imm p = regWb cs rd (alu op rs1V (sxImm12 imm)) (p + 4)

aluShamt :: Csrs -> Reg -> AluOp -> BitVector 32 -> BitVector 5 -> BitVector 32 -> Out
aluShamt cs rd op rs1V shamt p = regWb cs rd (alu op rs1V (zeroExtend shamt)) (p + 4)

aluReg :: Csrs -> Reg -> AluOp -> BitVector 32 -> BitVector 32 -> BitVector 32 -> Out
aluReg cs rd op a b p = regWb cs rd (alu op a b) (p + 4)

{- |
Load: traps on misaligned access (load-addr-misaligned, cause 4);
otherwise writes back the extracted + sign-extended load data.
-}
doLoad ::
  Csrs ->
  Reg ->
  Signed 12 ->
  Int ->
  Bool ->
  BitVector 32 ->
  BitVector 32 ->
  BitVector 32 ->
  Out
doLoad cs rd off width signed rs1 rdata p =
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
           in (p + 4, cs, addr, 0, 0, True, Just (unReg rd, loaded), False)

{- |
Store: traps on misaligned access; otherwise issues the write to
dmem with the byte-enable for the requested width / alignment.
-}
doStore ::
  Csrs ->
  Signed 12 ->
  BitVector 32 ->
  BitVector 32 ->
  Int ->
  BitVector 32 ->
  Out
doStore cs off base value width p =
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
           in (p + 4, cs, addr, wdata, be, False, Nothing, False)

-- | Branch: take it (PC ← PC + off) iff the comparator says so.
doBranch ::
  Csrs ->
  BranchOp ->
  BitVector 32 ->
  BitVector 32 ->
  Signed 13 ->
  BitVector 32 ->
  Out
doBranch cs op a b off p =
  let taken = branchTaken op a b
      target = p + sxImm13 off
      pcNext = if taken then target else p + 4
      -- RVFI spec (insn_{beq,bne,blt,bge,bltu,bgeu}): trap iff
      -- @next_pc[1:0] != 0@, regardless of whether the branch is
      -- taken. For a taken branch that's the target's alignment;
      -- for a fall-through, it's @p + 4@, which only ends up
      -- misaligned if @p@ is itself misaligned (the formal
      -- harness can place a misaligned @p@ at cycle 0, so we
      -- can't assume @pc@ is pre-aligned).
      misaligned = slice d1 d0 pcNext /= 0
   in if misaligned
        then trap causeInstrAddrMisaligned p pcNext cs
        else (pcNext, cs, 0, 0, 0, False, Nothing, False)

{- |
Latch a trap: record @mcause@ / @mepc@ / @mtval@ in the CSR file,
jump to @mtvec.base@ (bottom two bits cleared — direct mode).
No regfile writeback, no memory access. Sets the trap-fired bit
so the RVFI tap can flag this cycle's @rvfi_trap = 1@.
-}
trap :: BitVector 32 -> BitVector 32 -> BitVector 32 -> Csrs -> Out
trap cause epc tval cs =
  let cs' = applyTrap cause epc tval cs
      target = cMtvec cs .&. complement 3
   in (target, cs', 0, 0, 0, False, Nothing, True)

-- * Load / store byte-lane helpers ---------------------------------

{- |
Extract and sign-extend the loaded byte/half/word from the 32-bit
memory read response. Assumes the aligned-access check in 'doLoad'
has already rejected misaligned addresses.
-}
extendLoad :: Int -> Bool -> BitVector 32 -> BitVector 32 -> BitVector 32
extendLoad width signed addr rdata = case (width, signed) of
  (4, _) -> rdata
  (2, True) -> pack (signExtendTo32 half)
  (2, False) -> resize half
  (1, True) -> pack (signExtendTo32 loadByte)
  (1, False) -> resize loadByte
  _ -> 0
 where
  -- Named @loadByte@ rather than @byte@ so the signal Clash emits
  -- into the generated Verilog isn't a SystemVerilog reserved
  -- keyword (Verilator 5 rejects the default name).
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

-- | Sign-extend an n-bit value to 32 bits.
signExtendTo32 :: forall n. (KnownNat n) => BitVector n -> Signed 32
signExtendTo32 v = resize (unpack v :: Signed n)

{- | Is this instruction a CSR instruction (CSRRW/S/C/WI/SI/CI)?

Opcode 0b1110011 (SYSTEM) is shared with ECALL / EBREAK / MRET,
but those have @funct3 == 0@ whereas all Zicsr instructions
have @funct3 ∈ {1,2,3,5,6,7}@. The RVFI CSR tap uses this to
decide whether the current retire is targeting a CSR.

Called from the RVFI tap in 'core'; exported at module scope
so it synthesises to a single shared comparator net rather
than being inlined into every per-CSR mask computation.
-}
isCsrOp :: BitVector 32 -> Bool
isCsrOp insn =
  slice d6 d0 insn == 0b1110011 && slice d14 d12 insn /= 0

{- |
Compute the RVFI @rvfi_mem_rmask@ for a load instruction: which
bytes of 'dmemRData' the load actually consumed, based on the
instruction's @funct3@ and the address's low two bits.

Returns @0@ for any non-load opcode — the caller gates this on
@dmemRen@ so stores and ALU ops never see anything but zero.
-}
loadMask :: BitVector 32 -> BitVector 32 -> BitVector 4
loadMask instr addr
  | slice d6 d0 instr /= 0b0000011 = 0 -- not LOAD opcode
  | otherwise = case slice d14 d12 instr of
      0b000 -> byteMask -- LB
      0b100 -> byteMask -- LBU
      0b001 -> halfMask -- LH
      0b101 -> halfMask -- LHU
      0b010 -> 0b1111 -- LW
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

-- | Per-byte write-enable: 4 bits, one per byte lane.
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

{- | Shift a store's data into the correct byte lane(s) of the 32-bit
memory word.
-}
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

-- * Immediate helpers ----------------------------------------------

sxImm12 :: Signed 12 -> BitVector 32
sxImm12 = pack . (resize :: Signed 12 -> Signed 32)

sxImm13 :: Signed 13 -> BitVector 32
sxImm13 = pack . (resize :: Signed 13 -> Signed 32)

sxImm21 :: Signed 21 -> BitVector 32
sxImm21 = pack . (resize :: Signed 21 -> Signed 32)
