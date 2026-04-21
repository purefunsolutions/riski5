-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DerivingStrategies #-}

{- |
Module      : Riski5.Core.Config
Description : Type for the riski5 core-family configuration record.

Forward-looking configurability per
"docs/core-family.md" §5. A single value-level
'CoreConfig' record holds every architectural and
microarchitectural knob a preset can set:

  * Base register width (XLEN 32 / 64 / 128)
  * Pipeline shape + issue / retire widths
  * Functional-unit counts, mul\/div + FPU specs
  * Rename / ROB / IQ / LSQ for OoO tiers
  * Branch-predictor family
  * I\$ / D\$ / L2 cache + prefetch specs
  * Fusion + uop-ISA mode
  * Every RISC-V ISA extension as an individual 'ExtConfig' knob
  * Privilege stack ('PrivConfig') with MMU + AIA + Sstc etc.
  * RVFI observability toggle (always on for now)
  * Informational device-class hint

Phase 2A reaches for scaffolding only: today's pipelineless\/F+X
core is hoisted behind the 'Riski5.Core.Presets.tiny32' preset
exactly matching its current shape. Later phases (2B → 2C → 3 → 4
→ 5) grow the blocks that each knob toggles.

Knobs whose effect is not yet implemented are still carried on
the record — unused values round-trip as ordinary data; they only
cost anything when a block actually consumes their slice. Cf.
"docs/core-family.md" §6 for the block / knob mapping.

Value-level, not type-level. @ccXLEN@ is 'Natural' rather than a
promoted 'Nat'; when RV64 arrives in phase 5A we'll promote to a
type-level parameter for width-indexed 'Clash.Prelude.BitVector',
and 'CoreConfig' gains an @xlen@ type parameter. That refinement
is out of scope for 2A.
-}
module Riski5.Core.Config (
  CoreConfig (..),

  -- * Sub-records
  PipelineShape (..),
  MulDivSpec (..),
  FpuSpec (..),
  RenameSpec (..),
  RobSpec (..),
  IqSpec (..),
  LsqSpec (..),
  BpuSpec (..),
  CacheSpec (..),
  PrefetchSpec (..),
  FusionSpec (..),
  UopIsaMode (..),
  FusionSet (..),
  ExtConfig (..),
  AExt (..),
  PrivConfig (..),
  PrivModes (..),
  MMUSpec (..),
  AIASpec (..),
  PMPSpec (..),
  DeviceClass (..),

  -- * Convenience
  noFusion,
  noExtensions,
  mModeOnly,
) where

import Numeric.Natural (Natural)

-- | Top-level configuration record. One value per preset.
data CoreConfig = CoreConfig
  { -- | Register width. Spec-legal values: 32, 64, 128. Wider
    -- ('256' and above) is research-fork territory — no standard
    -- RISC-V opcode slot.
    ccXLEN :: Natural
  , ccPipeline :: PipelineShape
  , ccIssueWidth :: Natural
  , ccRetireWidth :: Natural
  , ccPipelineDepth :: Natural
  , ccNumALU :: Natural
  , ccNumLSU :: Natural
  , ccNumBranch :: Natural
  , ccMulDiv :: MulDivSpec
  , ccFPU :: FpuSpec
  , ccRename :: RenameSpec
  , ccROB :: RobSpec
  , ccIssueQueue :: IqSpec
  , ccLSQ :: LsqSpec
  , ccBPU :: BpuSpec
  , ccICache :: CacheSpec
  , ccDCache :: CacheSpec
  , ccL2 :: Maybe CacheSpec
  , ccPrefetch :: PrefetchSpec
  , ccFusion :: FusionSpec
  , ccUopISA :: UopIsaMode
  , ccExt :: ExtConfig
  , ccPriv :: PrivConfig
  , -- | Include the RVFI observability bundle on the core's output.
    -- Synthesis builds discard it; verilambda + riscv-formal
    -- require it.
    ccRVFI :: Bool
  , -- | Informational only — hints at which board class the preset
    -- was designed around. Lets tooling flag a mismatch ("Big on
    -- Cyclone II") without enforcing it.
    ccDeviceClass :: DeviceClass
  }
  deriving stock (Eq, Show)

-- * Pipeline + execution -------------------------------------------

-- | In-order pipelined vs out-of-order execution.
data PipelineShape
  = -- | @PipeInOrder n@ — @n@ classic in-order scalar stages
    -- (F, D, X, …). Today's core is @PipeInOrder 2@ (F + X).
    PipeInOrder Natural
  | -- | @PipeOoO n@ — @n@ total front + back stages, out-of-order
    -- execution with in-order retire per the RVFI contract.
    PipeOoO Natural
  deriving stock (Eq, Show)

-- | Integer multiply / divide unit.
data MulDivSpec
  = -- | No 'M' extension.
    MdNone
  | -- | Iterative — small, slow. Shift-and-add multiplier over
    -- 'mdCyclesMul' cycles; restoring-style divider over
    -- 'mdCyclesDiv' cycles.
    MdIterative {mdCyclesMul :: Natural, mdCyclesDiv :: Natural}
  | -- | Pipelined — throughput of one per cycle after latency
    -- 'mdStagesMul' (mul) and 'mdStagesDiv' (div). On Cyclone II,
    -- @mdDspBacked = True@ asks Quartus DSP-inference to map the
    -- multiply onto embedded 18×18 multipliers rather than LEs.
    MdPipelined
      { mdStagesMul :: Natural
      , mdStagesDiv :: Natural
      , mdDspBacked :: Bool
      }
  deriving stock (Eq, Show)

-- | Floating-point unit.
data FpuSpec
  = FpuNone
  | FpuSingle {fpuPipelined :: Bool}
  | FpuDouble {fpuPipelined :: Bool}
  | -- | Quad-precision (RV128 / Q). Reserved, not planned.
    FpuQuad
  deriving stock (Eq, Show)

-- * Rename / ROB / IQ / LSQ ----------------------------------------

-- | Register renaming.
data RenameSpec
  = -- | No rename — in-order tiers.
    RenameNone
  | -- | @RenameMap nPhys ratRd ratWr@ — map from 32 architectural
    -- to 'rsNPhys' physical registers, with 'rsRatRd' read ports
    -- and 'rsRatWr' write ports per cycle.
    RenameMap
      { rsNPhys :: Natural
      , rsRatRd :: Natural
      , rsRatWr :: Natural
      }
  deriving stock (Eq, Show)

-- | Reorder buffer (OoO retire backing).
data RobSpec
  = RobNone
  | Rob {robEntries :: Natural, robRetireW :: Natural}
  deriving stock (Eq, Show)

-- | Issue-queue topology.
data IqSpec
  = IqNone
  | IqUnified {iqEntries :: Natural, iqWakeupPorts :: Natural}
  | IqClustered {iqClusters :: Natural, iqEntriesEach :: Natural}
  deriving stock (Eq, Show)

-- | Load / store queue.
data LsqSpec
  = LsqNone
  | Lsq
      { lsqLdEntries :: Natural
      , lsqStEntries :: Natural
      , lsqStoreFwd :: Bool
      , lsqSpecLoads :: Bool
      }
  deriving stock (Eq, Show)

-- * Branch prediction ---------------------------------------------

-- | Branch-predictor family. Cost grows roughly linearly down
-- this list.
data BpuSpec
  = -- | Static backward-taken / forward-not-taken. Tiny default.
    BpuStatic
  | -- | 1-bit BHT + BTB + RAS.
    BpuBimodal
      { bpBhtEntries :: Natural
      , bpBtbEntries :: Natural
      , bpRasDepth :: Natural
      }
  | -- | gshare — global history XOR'd with PC into BHT.
    BpuGShare
      { bpHistBits :: Natural
      , bpBtbEntries :: Natural
      , bpRasDepth :: Natural
      , bpIndirect :: Bool
      }
  | -- | Local + global tournament with chooser; loop predictor
    -- optional on 'bpLoop'.
    BpuTournament
      { bpLocalBht :: Natural
      , bpGlobalHist :: Natural
      , bpChooser :: Natural
      , bpBtbEntries :: Natural
      , bpRasDepth :: Natural
      , bpIndirect :: Bool
      , bpLoop :: Bool
      }
  | -- | TAGE — state-of-the-art tagged-tables predictor.
    BpuTAGE
      { bpTables :: Natural
      , bpHistLen :: Natural
      , bpBtbEntries :: Natural
      , bpRasDepth :: Natural
      , bpIndirect :: Bool
      , bpLoop :: Bool
      }
  deriving stock (Eq, Show)

-- * Memory system -------------------------------------------------

-- | One cache level's shape. Tiny defaults to @CacheDirect@;
-- Performance uses @CacheAssoc@ with write-back.
data CacheSpec
  = CacheNone
  | CacheDirect {cSize :: Natural, cLine :: Natural}
  | CacheAssoc
      { cSize :: Natural
      , cLine :: Natural
      , cWays :: Natural
      , cWriteBack :: Bool
      , cMshrs :: Natural
      }
  deriving stock (Eq, Show)

-- | Hardware prefetcher.
data PrefetchSpec
  = PrefetchNone
  | PrefetchStride {pfStreams :: Natural}
  deriving stock (Eq, Show)

-- * Fusion / uop --------------------------------------------------

-- | Fusion strategy. 'NoFusion' on Tiny; in-situ patterns (no
-- separate uop form) on Little; explicit uop representation from
-- Mid upward.
data FusionSpec
  = NoFusion
  | InSitu FusionSet
  | Explicit FusionSet
  deriving stock (Eq, Show)

-- | Uop-ISA presence. Even when 'FusionSpec' is 'Explicit', the
-- uop ISA can be 'UopImplicit' (pipeline carries an extra
-- @rs3@-capable slot but no first-class uop type) or
-- 'UopExplicit' (internal uop type is its own ADT consumed by the
-- back end).
data UopIsaMode = UopNone | UopImplicit | UopExplicit
  deriving stock (Eq, Show)

-- | Which fusion patterns are enabled. Every knob is Boolean
-- because a pattern either fires or doesn't — no knob gradations
-- here.
data FusionSet = FusionSet
  { fsLuiAddi :: Bool
  -- ^ @LUI + ADDI → LI20@
  , fsAuipcAddi :: Bool
  -- ^ @AUIPC + ADDI → PC-relative LI20@
  , fsAddiAdd :: Bool
  -- ^ Displacement + base-address calc
  , fsIndexedLd :: Bool
  -- ^ @ADD + LW → LW_IDX@ (3-source)
  , fsIndexedSt :: Bool
  -- ^ @ADD + SW → SW_IDX@
  , fsCmpBranch :: Bool
  -- ^ @SLT(U) + BEQ\/BNE@
  , fsLuiAddiAdd :: Bool
  -- ^ 3-way base + displacement
  , fsLdPair :: Bool
  -- ^ Consecutive @LW@s on aligned addresses
  }
  deriving stock (Eq, Show)

-- | Convenience — every fusion pattern off.
noFusion :: FusionSet
noFusion =
  FusionSet
    { fsLuiAddi = False
    , fsAuipcAddi = False
    , fsAddiAdd = False
    , fsIndexedLd = False
    , fsIndexedSt = False
    , fsCmpBranch = False
    , fsLuiAddiAdd = False
    , fsLdPair = False
    }

-- * Extensions ----------------------------------------------------

-- | Every architectural RISC-V extension as an individual knob.
-- Presets set defaults; customs override per field. See
-- "docs/core-family.md" §3 for the full catalogue.
data ExtConfig = ExtConfig
  { -- Classic
    extM :: Bool
  -- ^ Integer Mul / Div.
  , extA :: AExt
  -- ^ Atomics (per 'AExt').
  , extF :: Bool
  -- ^ 32-bit IEEE 754 FPU.
  , extD :: Bool
  -- ^ 64-bit IEEE 754 FPU. Requires 'extF'.
  , extC :: Bool
  -- ^ Compressed 16-bit encodings.
  , -- Bit manipulation
    extZba :: Bool
  -- ^ Address-generation (SH*ADD).
  , extZbb :: Bool
  -- ^ Basic bit manipulation (CLZ, CTZ, CPOP, ROL, …).
  , extZbc :: Bool
  -- ^ Carry-less multiply (CLMUL[H|R]).
  , extZbs :: Bool
  -- ^ Single-bit ops (BCLR, BEXT, BINV, BSET).
  , -- Code-size reduction
    extZcb :: Bool
  -- ^ Extra short compressed instructions.
  , extZcmp :: Bool
  -- ^ Push / pop + move pair prologue\/epilogue.
  , extZcmt :: Bool
  -- ^ Compressed table-jump for switches.
  , -- Counters / perf
    extZicntr :: Bool
  -- ^ @cycle@, @time@, @instret@.
  , extZihpm :: Bool
  -- ^ 29 HW performance-monitor counters.
  , -- Cache-block management
    extZicbom :: Bool
  -- ^ @CBO.CLEAN / FLUSH / INVAL@.
  , extZicboz :: Bool
  -- ^ @CBO.ZERO@.
  , extZicbop :: Bool
  -- ^ @PREFETCH.I / R / W@.
  , -- Misc
    extZicond :: Bool
  -- ^ @CZERO.EQZ / NEZ@ branchless conditional zeroing.
  , extZawrs :: Bool
  -- ^ @WRS.NTO / STO@ wait-on-reservation-set.
  , extZfh :: Bool
  -- ^ Half-precision (16-bit IEEE 754) FP.
  , extZfa :: Bool
  -- ^ Additional FP (min\/max variants, rounds, …).
  , -- Hypervisor + vector
    extH :: Bool
  -- ^ Hypervisor extension.
  , extV :: Bool
  -- ^ RISC-V Vector. Reserved — not implemented in any phase plan.
  , -- State-enable
    extSmstateen :: Bool
  -- ^ Fine-grained state-enable CSRs across privileges.
  }
  deriving stock (Eq, Show)

-- | Atomic-extension variant.
data AExt
  = -- | No 'A'.
    AOff
  | -- | Zalrsc only — @LR.W@ + @SC.W@ (+ 'LR.D\/SC.D' on RV64\/128).
    AZalrsc
  | -- | Full A — Zalrsc + Zaamo (all @AMO*.W@\/@.D@\/@.Q@).
    AFull
  deriving stock (Eq, Show)

-- | No extension knobs on. Tiny's 'RV32I + Zicsr + Zifencei' lives
-- in 'PrivConfig' because Zicsr\/Zifencei are technically
-- privileged infrastructure, not classic ISA extensions.
noExtensions :: ExtConfig
noExtensions =
  ExtConfig
    { extM = False
    , extA = AOff
    , extF = False
    , extD = False
    , extC = False
    , extZba = False
    , extZbb = False
    , extZbc = False
    , extZbs = False
    , extZcb = False
    , extZcmp = False
    , extZcmt = False
    , extZicntr = False
    , extZihpm = False
    , extZicbom = False
    , extZicboz = False
    , extZicbop = False
    , extZicond = False
    , extZawrs = False
    , extZfh = False
    , extZfa = False
    , extH = False
    , extV = False
    , extSmstateen = False
    }

-- * Privilege stack -----------------------------------------------

-- | Privilege-mode + MMU configuration.
data PrivConfig = PrivConfig
  { privModes :: PrivModes
  , privMMU :: MMUSpec
  , privSvadu :: Bool
  -- ^ Hardware auto-update of A (accessed) and D (dirty) PTE bits.
  , privSvnapot :: Bool
  -- ^ Naturally-Aligned-Power-Of-Two huge-page translation.
  , privSvpbmt :: Bool
  -- ^ Page-based memory types.
  , privSmepmp :: Bool
  -- ^ Enhanced Physical Memory Protection.
  , privAIA :: AIASpec
  -- ^ Advanced Interrupt Architecture variant.
  , privSstc :: Bool
  -- ^ S-mode timer CSR @stimecmp@.
  , privPMP :: PMPSpec
  -- ^ Physical Memory Protection region count.
  , privZicsr :: Bool
  -- ^ @CSRR*@ instructions + CSR file.
  , privZifencei :: Bool
  -- ^ @FENCE.I@ instruction for self-modifying code.
  }
  deriving stock (Eq, Show)

-- | Which privilege modes the core implements.
data PrivModes
  = -- | Machine only (bare-metal, no OS).
    PrivM
  | -- | Machine + User (microcontroller-style isolation).
    PrivMU
  | -- | Machine + Supervisor + User (Linux-class hosting).
    PrivMSU
  | -- | + Hypervisor (virtualisation host).
    PrivMSUH
  deriving stock (Eq, Show)

-- | Virtual-memory MMU shape.
data MMUSpec
  = -- | No paging (physical-only addressing).
    MMUNone
  | -- | 32-bit virtual addresses, RV32-only.
    MMUSv32
  | -- | 39-bit virtual addresses, RV64-only.
    MMUSv39
  | -- | 48-bit virtual addresses, RV64-only.
    MMUSv48
  | -- | 57-bit virtual addresses, RV64-only. Reserved.
    MMUSv57
  deriving stock (Eq, Show)

-- | Advanced Interrupt Architecture.
data AIASpec
  = AIANone
  | AIASmaia
  -- ^ M-mode AIA only.
  | AIASmaiaSsaia
  -- ^ M + S-mode AIA. IMSIC\/APLIC components wired separately.
  deriving stock (Eq, Show)

-- | Physical Memory Protection region count.
data PMPSpec = PMPNone | PMP16 | PMP64
  deriving stock (Eq, Show)

-- | Convenience — classic "M-mode only with Zicsr + Zifencei"
-- baseline, as shipped today.
mModeOnly :: PrivConfig
mModeOnly =
  PrivConfig
    { privModes = PrivM
    , privMMU = MMUNone
    , privSvadu = False
    , privSvnapot = False
    , privSvpbmt = False
    , privSmepmp = False
    , privAIA = AIANone
    , privSstc = False
    , privPMP = PMPNone
    , privZicsr = True
    , privZifencei = True
    }

-- * Device class --------------------------------------------------

-- | Target FPGA family. Informational only; drives no codegen
-- today, but lets a preset assert "designed for Cyclone II" so
-- tooling can warn when the pairing is wrong.
data DeviceClass
  = -- | Altera Cyclone II — DE2 (EP2C35). 33 216 LEs, 105 M4K.
    CycloneII
  | -- | Altera Cyclone IV — DE2-115 (EP4CE115) or similar.
    CycloneIV
  | -- | Altera Cyclone V.
    CycloneV
  | -- | Intel Arria 10.
    Arria10
  | -- | Intel Agilex.
    Agilex
  deriving stock (Eq, Show)
