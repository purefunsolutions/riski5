-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause

{- |
Module      : Riski5.Core.Presets
Description : Preset 'CoreConfig' values for each tier / edition.

Each preset is a single 'CoreConfig' value. Customs are
per-field overrides on top of a preset — e.g.

> tinyImc = tiny32
>   { ccExt = (ccExt tiny32) { extM = True, extC = True } }

'Riski5.Core.Assembly.coreWith' consumes one of these to select
the core shape. Phase 2A only wires 'tiny32' all the way
through; the higher-tier presets below are there to document
the design space (per "docs/core-family.md" §4) and give later
phases a concrete starting point to walk forward from.
-}
module Riski5.Core.Presets (
  -- * Tiny — in-order pipelined (phase 2)
  tiny32,
  tiny32M,
  tiny64,

  -- * Little — entry-level OoO (phase 3B, 5B)
  little32,
  little64,

  -- * Mid — Pentium II / Core-2-class OoO (phase 3C, 5C)
  mid32,
  mid64,

  -- * Big — Performance minus one notch (phase 4A, 5D)
  big32,
  big64,

  -- * Performance — widest (phase 4B, 5E; 128 speculative)
  performance32,
  performance64,
  performance128,
) where

import Riski5.Core.Config

-- * Tiny ----------------------------------------------------------

{- | @tiny32@ — phase-2 starting point, matches today's 2-stage
F+X pipelineless-style core exactly.

__Today's shape encoded:__

  * @PipeInOrder 2@ — F (fetch, one M4K read cycle) + X (decode,
    regfile read, ALU, branch compare, memory access issue,
    writeback all combinational within the execute cycle).
  * 1 ALU, 1 LSU, no separate branch unit (shared with ALU),
    no mul\/div, no FPU.
  * No rename, no ROB, no IQ, no LSQ — in-order in the strict
    sense.
  * @BpuStatic@ — static backward-taken\/forward-not-taken.
    The one-cycle squash after a taken branch matches the F+X
    depth.
  * No caches, no prefetcher — the phase-1 SoC uses BRAM
    direct at @0x0@ + SRAM\/SDRAM through a flat bus. Caches
    land in phase 2C.
  * @NoFusion@, @UopNone@ — no fusion or internal uop ISA.
  * @noExtensions@ — RV32I baseline. M\/A\/C opt-in via custom.
  * @mModeOnly@ — Zicsr + Zifencei + M-mode; no S\/U\/H.
  * @ccRVFI = True@ — the RVFI bundle drives both verilambda
    SoC sim and YosysHQ\/riscv-formal model checking.
  * @ccDeviceClass = CycloneII@ — designed for DE2 silicon.

Phase 2B extends the pipeline to 3–5 stages (F\/D\/X\/M\/W) with
forwarding + hazard detection; the preset's @ccPipeline@ and
@ccPipelineDepth@ update then, but the tier stays @tiny@.
-}
tiny32 :: CoreConfig
tiny32 =
  CoreConfig
    { ccXLEN = 32
    , ccPipeline = PipeInOrder 2
    , ccIssueWidth = 1
    , ccRetireWidth = 1
    , ccPipelineDepth = 2
    , ccNumALU = 1
    , ccNumLSU = 1
    , ccNumBranch = 0
    , ccMulDiv = MdNone
    , ccFPU = FpuNone
    , ccRename = RenameNone
    , ccROB = RobNone
    , ccIssueQueue = IqNone
    , ccLSQ = LsqNone
    , ccBPU = BpuStatic
    , ccICache = CacheNone
    , ccDCache = CacheNone
    , ccL2 = Nothing
    , ccPrefetch = PrefetchNone
    , ccFusion = NoFusion
    , ccUopISA = UopNone
    , ccExt = noExtensions
    , ccPriv = mModeOnly
    , ccRVFI = True
    , ccDeviceClass = CycloneII
    }

{- | @tiny32M@ — @tiny32@ plus the RV32M integer-multiply /
divide extension (phase 2B). Layered as a single-field override
over 'tiny32': the 'ExtConfig' record gets @extM = True@ and
'ccMulDiv' switches from 'MdNone' to 'MdIterative' with the
32-iter multiplier and 33-iter divider cycle counts today's
'Riski5.Core.FU.MulDiv' ships.

The shipping FU is an iterative shift-and-add multiplier + a
restoring divider — no DSP inference, so the 35 embedded 18×18
multipliers on the EP2C35 stay reserved for future FPU work
('big32'\/'performance32' flip @mdDspBacked = True@ on
'MdPipelined' presets to claim them). LE cost over 'tiny32'
is ~400 LEs for the FU itself plus a handful of muxes in the
core's writeback / stall paths — well inside the DE2 budget
(pre-M LE utilisation was ~27 %).

Latency: MUL*\/DIV*\/REM* retire in 34 cycles. Divide-by-zero
short-circuits to 2 cycles via the 'launchDiv' early-out.
Everything else in the core — @PipeInOrder 2@ shape, BpuStatic
branch prediction, no caches, no fusion, M-mode only — stays
identical to 'tiny32'.
-}
tiny32M :: CoreConfig
tiny32M =
  tiny32
    { ccMulDiv = MdIterative {mdCyclesMul = 32, mdCyclesDiv = 33}
    , ccExt = (ccExt tiny32) {extM = True}
    }

{- | @tiny64@ — planned RV64 sibling of 'tiny32'. Phase 5A lands
it: regfile widened to 64 bits, @.W@ instructions, @LD@\/@SD@
paths in the LSU. The largest in-order-pipelined core that
still plausibly fits DE2 (tight M4K budget from the wider
regfile).
-}
tiny64 :: CoreConfig
tiny64 = tiny32 {ccXLEN = 64}

-- * Little --------------------------------------------------------

{- | @little32@ — entry-level OoO (phase 3B). Single-issue,
8-entry ROB, simple rename (32→48 physical), 1-bit BHT + BTB-8
+ RAS-4 branch prediction, 2 KB direct-mapped caches.
@DE2-115@ comfortable; a @little32Minimal@ custom might fit
@DE2@ (Cyclone II) per "docs/core-family.md" §7. The preset
value here is a documentation anchor — blocks that realise it
land in phase 3A\/3B.
-}
little32 :: CoreConfig
little32 =
  tiny32
    { ccPipeline = PipeOoO 4
    , ccPipelineDepth = 4
    , ccIssueWidth = 1
    , ccRetireWidth = 1
    , ccNumBranch = 1
    , ccMulDiv = MdIterative {mdCyclesMul = 32, mdCyclesDiv = 33}
    , ccRename = RenameMap {rsNPhys = 48, rsRatRd = 2, rsRatWr = 1}
    , ccROB = Rob {robEntries = 8, robRetireW = 1}
    , ccIssueQueue = IqUnified {iqEntries = 8, iqWakeupPorts = 1}
    , ccLSQ =
        Lsq
          { lsqLdEntries = 4
          , lsqStEntries = 4
          , lsqStoreFwd = True
          , lsqSpecLoads = False
          }
    , ccBPU =
        BpuBimodal
          { bpBhtEntries = 32
          , bpBtbEntries = 8
          , bpRasDepth = 4
          }
    , ccICache = CacheDirect {cSize = 2 * 1024, cLine = 32}
    , ccDCache = CacheDirect {cSize = 2 * 1024, cLine = 32}
    , ccFusion = InSitu noFusion {fsLuiAddi = True, fsAuipcAddi = True}
    , ccUopISA = UopImplicit
    , ccExt = noExtensions {extM = True, extC = True}
    , ccDeviceClass = CycloneIV
    }

-- | @little64@ — RV64 sibling of 'little32'. DE2 fit uncertain.
little64 :: CoreConfig
little64 = little32 {ccXLEN = 64}

-- * Mid -----------------------------------------------------------

{- | @mid32@ — Pentium II / Core-2 shape (phase 3C). 3-wide OoO,
40-entry ROB, explicit uop ISA, first Linux-capable tier via
optional S-mode + Sv32 + Sstc. Comfortable on Cyclone V GT.
-}
mid32 :: CoreConfig
mid32 =
  little32
    { ccPipeline = PipeOoO 6
    , ccPipelineDepth = 6
    , ccIssueWidth = 3
    , ccRetireWidth = 3
    , ccNumALU = 2
    , ccNumLSU = 1
    , ccNumBranch = 1
    , ccMulDiv =
        MdPipelined
          { mdStagesMul = 4
          , mdStagesDiv = 32
          , mdDspBacked = True
          }
    , ccRename = RenameMap {rsNPhys = 64, rsRatRd = 6, rsRatWr = 3}
    , ccROB = Rob {robEntries = 40, robRetireW = 3}
    , ccIssueQueue = IqUnified {iqEntries = 16, iqWakeupPorts = 3}
    , ccLSQ =
        Lsq
          { lsqLdEntries = 16
          , lsqStEntries = 16
          , lsqStoreFwd = True
          , lsqSpecLoads = False
          }
    , ccBPU =
        BpuGShare
          { bpHistBits = 8
          , bpBtbEntries = 128
          , bpRasDepth = 8
          , bpIndirect = True
          }
    , ccICache = CacheAssoc {cSize = 8 * 1024, cLine = 32, cWays = 2, cWriteBack = False, cMshrs = 2}
    , ccDCache = CacheAssoc {cSize = 8 * 1024, cLine = 32, cWays = 2, cWriteBack = True, cMshrs = 2}
    , ccL2 = Nothing -- optional 32 KB on bigger devices
    , ccFusion =
        Explicit
          noFusion
            { fsLuiAddi = True
            , fsAuipcAddi = True
            , fsAddiAdd = True
            , fsIndexedLd = True
            , fsIndexedSt = True
            , fsCmpBranch = True
            }
    , ccUopISA = UopExplicit
    , ccExt =
        noExtensions
          { extM = True
          , extA = AFull
          , extC = True
          , extZba = True
          , extZbb = True
          , extZihpm = True
          }
    , ccDeviceClass = CycloneV
    }

-- | @mid64@ — RV64 sibling of 'mid32'. First Linux-capable RV64
-- tier; pairs with Sv39 by default for 64-bit page tables.
mid64 :: CoreConfig
mid64 =
  mid32
    { ccXLEN = 64
    , ccPriv =
        (ccPriv mid32)
          { privModes = PrivMSU
          , privMMU = MMUSv39
          , privSstc = True
          }
    }

-- * Big -----------------------------------------------------------

-- | @big32@ — subset of Performance (phase 4A). 3-wide OoO,
-- 64-entry ROB, clustered IQs, L2 cache, single-precision FPU,
-- full bit-manip. Arria 10 comfortable; over budget for DE2.
big32 :: CoreConfig
big32 =
  mid32
    { ccPipeline = PipeOoO 8
    , ccPipelineDepth = 8
    , ccIssueWidth = 3
    , ccRetireWidth = 3
    , ccNumALU = 3
    , ccNumLSU = 2
    , ccNumBranch = 1
    , ccMulDiv =
        MdPipelined
          { mdStagesMul = 3
          , mdStagesDiv = 24
          , mdDspBacked = True
          }
    , ccFPU = FpuSingle {fpuPipelined = True}
    , ccRename = RenameMap {rsNPhys = 96, rsRatRd = 6, rsRatWr = 3}
    , ccROB = Rob {robEntries = 64, robRetireW = 3}
    , ccIssueQueue = IqClustered {iqClusters = 3, iqEntriesEach = 16}
    , ccLSQ =
        Lsq
          { lsqLdEntries = 24
          , lsqStEntries = 24
          , lsqStoreFwd = True
          , lsqSpecLoads = False
          }
    , ccBPU =
        BpuTournament
          { bpLocalBht = 256
          , bpGlobalHist = 12
          , bpChooser = 256
          , bpBtbEntries = 256
          , bpRasDepth = 16
          , bpIndirect = True
          , bpLoop = False
          }
    , ccICache = CacheAssoc {cSize = 16 * 1024, cLine = 32, cWays = 2, cWriteBack = False, cMshrs = 4}
    , ccDCache = CacheAssoc {cSize = 16 * 1024, cLine = 32, cWays = 2, cWriteBack = True, cMshrs = 4}
    , ccL2 = Just (CacheAssoc {cSize = 128 * 1024, cLine = 64, cWays = 4, cWriteBack = True, cMshrs = 8})
    , ccExt =
        noExtensions
          { extM = True
          , extA = AFull
          , extF = True
          , extC = True
          , extZba = True
          , extZbb = True
          , extZbs = True
          , extZicbom = True
          , extZihpm = True
          }
    , ccPriv =
        (ccPriv mid32)
          { privModes = PrivMSU
          , privMMU = MMUSv32
          , privAIA = AIASmaiaSsaia
          , privSstc = True
          , privPMP = PMP16
          }
    , ccDeviceClass = Arria10
    }

-- | @big64@ — RV64 default production core. Sv39 MMU, full
-- extension set, Linux + KVM guest capable via 'extH'.
big64 :: CoreConfig
big64 =
  big32
    { ccXLEN = 64
    , ccExt = (ccExt big32) {extH = True}
    , ccPriv = (ccPriv big32) {privModes = PrivMSUH, privMMU = MMUSv39}
    }

-- * Performance ---------------------------------------------------

-- | @performance32@ — widest tier (phase 4B). 4-wide OoO, 128+
-- ROB, TAGE branch prediction, speculative loads, stride
-- prefetch, full extension set bar V. Agilex target.
performance32 :: CoreConfig
performance32 =
  big32
    { ccPipeline = PipeOoO 12
    , ccPipelineDepth = 12
    , ccIssueWidth = 4
    , ccRetireWidth = 4
    , ccNumALU = 4
    , ccNumLSU = 2
    , ccNumBranch = 2
    , ccMulDiv =
        MdPipelined
          { mdStagesMul = 3
          , mdStagesDiv = 16
          , mdDspBacked = True
          }
    , ccFPU = FpuDouble {fpuPipelined = True}
    , ccRename = RenameMap {rsNPhys = 128, rsRatRd = 8, rsRatWr = 4}
    , ccROB = Rob {robEntries = 128, robRetireW = 4}
    , ccIssueQueue = IqClustered {iqClusters = 4, iqEntriesEach = 20}
    , ccLSQ =
        Lsq
          { lsqLdEntries = 32
          , lsqStEntries = 32
          , lsqStoreFwd = True
          , lsqSpecLoads = True
          }
    , ccBPU =
        BpuTAGE
          { bpTables = 5
          , bpHistLen = 131
          , bpBtbEntries = 512
          , bpRasDepth = 32
          , bpIndirect = True
          , bpLoop = True
          }
    , ccICache = CacheAssoc {cSize = 32 * 1024, cLine = 64, cWays = 4, cWriteBack = False, cMshrs = 4}
    , ccDCache = CacheAssoc {cSize = 32 * 1024, cLine = 64, cWays = 4, cWriteBack = True, cMshrs = 8}
    , ccL2 = Just (CacheAssoc {cSize = 512 * 1024, cLine = 64, cWays = 8, cWriteBack = True, cMshrs = 16})
    , ccPrefetch = PrefetchStride {pfStreams = 4}
    , ccFusion =
        Explicit
          noFusion
            { fsLuiAddi = True
            , fsAuipcAddi = True
            , fsAddiAdd = True
            , fsIndexedLd = True
            , fsIndexedSt = True
            , fsCmpBranch = True
            , fsLuiAddiAdd = True
            , fsLdPair = True
            }
    , ccExt =
        noExtensions
          { extM = True
          , extA = AFull
          , extF = True
          , extD = True
          , extC = True
          , extZba = True
          , extZbb = True
          , extZbc = True
          , extZbs = True
          , extZcmp = True
          , extZcmt = True
          , extZcb = True
          , extZicbom = True
          , extZicboz = True
          , extZicbop = True
          , extZicntr = True
          , extZihpm = True
          , extZicond = True
          , extZawrs = True
          , extZfh = True
          , extZfa = True
          , extH = True
          , extSmstateen = True
          }
    , ccPriv =
        PrivConfig
          { privModes = PrivMSUH
          , privMMU = MMUSv32
          , privSvadu = True
          , privSvnapot = True
          , privSvpbmt = True
          , privSmepmp = True
          , privAIA = AIASmaiaSsaia
          , privSstc = True
          , privPMP = PMP64
          , privZicsr = True
          , privZifencei = True
          }
    , ccDeviceClass = Agilex
    }

-- | @performance64@ — default RV64 performance core. Linux + KVM
-- + AIA at full scale.
performance64 :: CoreConfig
performance64 =
  performance32
    { ccXLEN = 64
    , ccPriv = (ccPriv performance32) {privMMU = MMUSv48}
    }

{- | @performance128@ — speculative RV128 variant. Not ratified
in the spec; carried as a research preset so when upstream
freezes RV128 we're already aligned. Not buildable on any
current FPGA budget.
-}
performance128 :: CoreConfig
performance128 = performance64 {ccXLEN = 128}
