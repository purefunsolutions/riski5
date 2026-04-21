<!--
SPDX-FileCopyrightText: 2026 Mika Tammi
SPDX-License-Identifier: MIT OR BSD-3-Clause
-->

# Core family — Tiny / Little / Mid / Big / Performance

**Status:** forward-looking design note. Supersedes the four-tier
sketch in
[`future-soc-configurability.md`](./future-soc-configurability.md),
which now redirects here. Phase 1 (pipelineless → 2-stage F+X on
Cyclone II) is the current shipping core; everything below lands phase
2 onwards. Cross-refs: [`CLAUDE.md`](../CLAUDE.md),
[`verification.md`](./verification.md),
[`references.md`](./references.md).

## 1. What this document defines

riski5 is growing from one concrete Clash RV32I core into a **family of
five presets** — **Tiny / Little / Mid / Big / Performance** — each
available in **multiple editions (RV32 and RV64 standard; RV128
speculative for Performance)**. Every preset is a value of a single
`CoreConfig` type-level record defined in
`src/Riski5/Core/Config.hs`. A "custom" core is a preset with
individual field overrides — for example `tiny32 { ccExt = (ccExt
tiny32) { extM = True } }` or `performance64 { ccIssueWidth = 6 }`.

Every architectural ISA extension is an individual knob on
`CoreConfig.ccExt` (or `CoreConfig.ccPriv`); presets set *defaults*.
Microarchitectural counts (ALUs, LSUs, branch units, ROB size, issue
width, pipeline depth, cache sizes, rename width, branch-predictor
shape) are also individual knobs with numeric or sum-type values.

Below the preset level, a set of reusable Clash blocks (`Fetch`,
`Decode`, `Rename`, `Dispatch`, `IssueQueue`, `FunctionalUnit`,
`LoadStoreUnit`, `ROB`, `Retire`, `BranchPredictor`, `Cache`,
`Prefetcher`, `CsrFile`, `TrapUnit`, `Mmu`) each consume their slice
of `CoreConfig`. In-order and OoO cores differ in how the blocks wire
(degenerate modes collapse to wires when their spec is `*None`), not
in which blocks exist.

## 2. Scope and non-goals

**In scope.**

- Five tier presets, each with RV32 and RV64 editions.
- A speculative RV128 Performance edition.
- Full modern RISC-V extension set (see §3) — M / A / F / D / C,
  Zba/Zbb/Zbs/Zbc, Zcmp/Zcmt/Zcb, Zicbom/Zicboz/Zicbop,
  Zicntr/Zihpm, Zicond, Zawrs, Zfa/Zfh, H (hypervisor),
  Smaia/Ssaia (Advanced Interrupt Architecture), Sstc, Svadu /
  Svnapot / Svpbmt, Smepmp, Smstateen.
- Privileged stack up through M+S+U+H, Sv32 / Sv39 / Sv48 MMU.

**Explicitly deferred.**

- **RISC-V Vector (V extension).** Large separate design effort.
  Reserved as a future doc. `VLEN` is orthogonal to `ccXLEN` when it
  arrives.
- **Multi-hart / cache coherency.** Single-hart only through phase 4.
  Adding `ccHarts :: Nat` + MESI-class coherency is a separate design
  note.
- **Board procurement.** We have exactly one board in hand — the
  Altera DE2 (Cyclone II EP2C35, 33 216 LEs, 105 M4K, 35 DSPs).
  Larger devices (DE2-115 / Cyclone V / Arria 10 / Agilex) stay
  aspirational until budget allows. See §7.

## 3. RISC-V extension glossary

The letters M / A / F / C (and the rest) are orthogonal ISA
extensions. A given core picks any subset through `ccExt` /
`ccPriv`. Base register width (XLEN) is itself a dimension,
documented first.

### 3.1 Base variant — XLEN 32 / 64 / 128

Register width (XLEN) is the most fundamental ISA choice. It decides
the width of every architectural register, the natural operand width of
arithmetic, the load/store granularity, the reset vector encoding, and
the MMU modes available. The RISC-V base ISA spec defines exactly three
widths: 32, 64, 128.

| Variant | Code | XLEN | Status | Effect |
|---|---|---|---|---|
| **RV32** | `XLEN32` | 32 | shipped | 32-bit integer registers (x0..x31). 32-bit address space. riski5 phase 1 is RV32I. |
| **RV64** | `XLEN64` | 64 | planned | 64-bit integer registers. Adds `.W` word-size instructions (`ADDW`, `SUBW`, `SLLW`, `SRLW`, `SRAW`, `ADDIW`, `SLLIW`, `SRLIW`, `SRAIW`) that operate on the low 32 bits and sign-extend. 64-bit load/store (`LD`, `SD`) and unsigned 32-bit load (`LWU`). |
| **RV128** | `XLEN128` | 128 | **speculative, long-term** | 128-bit integer registers. `.D` dword-size instructions on top of RV64's `.W`. 128-bit load/store (`LQ`, `SQ`). RVQ quad-precision FP pairs naturally. Spec: encoding slots reserved but variant *not* ratified. |
| **RV256+** | `XLEN256`, … | 256, 512, … | **non-standard, research fork only** | No standard RISC-V beyond RV128. Wider *vector* registers (VLEN) are standard via the V extension; wider *scalars* are not. The `ccXLEN :: Nat` type leaves the door open for research forks but no named preset targets it. |

**Standard vs non-standard wider widths.** The RISC-V base integer ISA
reserves exactly three widths — 32, 64, 128. There is no RV256 or
RV512 in the ratified spec and no reserved opcode allocation; a
256-bit scalar register file would be a research fork, not conformant
RISC-V. Wide-SIMD / wide-integer arithmetic has a proper RISC-V home:
the **V extension's VLEN** parameter, which is implementation-defined
and standardly runs 128 / 256 / 512 / 1024 / 2048+ bits. VLEN and
XLEN are orthogonal — a `performance128` tier paired with
`VLEN = 512` V would yield 128-bit scalars *and* 512-bit vectors in
independent register namespaces.

**Why RV128 at all.**

- **SIMD-within-a-register (packed SIMD).** A 128-bit integer register
  can be reinterpreted as four 32-bit lanes, two 64-bit lanes, eight
  16-bit lanes, etc. — the MMX / SSE / NEON / paired-single trick.
  Useful for DSP kernels, colour blending, checksums, character
  classification. On riski5 this would surface as a custom extension
  (`Zsimd128`-flavour opcodes decoded by an `Ext` module) rather than
  a ratified standard.
- **Custom GPU / shader / compute cores.** A 128-bit scalar register
  file pairs nicely with a vector / shader backend; the scalar side
  handles control, the V side handles data parallelism. Style used by
  Berkeley's Hwacha and contemporary open "RISC-V GPU" efforts.
- **Wide-memory bus natural fit.** If L1 D$ and the SDRAM/HBM bus are
  already 128-bit wide (Arria 10 / Agilex easily are), XLEN=128 makes
  the scalar path match the bus, one load fills a register without
  alignment mux overhead.

**Impact of XLEN on the extension set.**

- **M.** RV64M adds `MULW / DIVW / DIVUW / REMW / REMUW`. RV128M adds
  `MULD / DIVD / REMD`.
- **A.** RV64A adds 64-bit `LR.D / SC.D / AMO*.D`. RV128A adds `LR.Q
  / SC.Q / AMO*.Q`.
- **F / D / Q.** Independent of XLEN — the FP register file is its
  own 32 / 64 / 128-bit namespace. RVQ quad-precision FP becomes
  natural with RV128.
- **C.** RV32C, RV64C, and RV128C encodings differ; `C.LD / C.SD`
  replace `C.JAL` in RV64C, `C.LQ / C.SQ` replace `C.FLW / C.FSW` in
  RV128C.
- **Zba / Zbb / Zbs.** Width-indexed variants (`ADD.UW`, `SH1ADD.UW`,
  `ROLW`, etc.).
- **MMU.** Sv32 is RV32-only. Sv39 / Sv48 / Sv57 are RV64+ only.
- **Zcmp / Zcmt / Zcb.** RV32-only today (the spec targets embedded
  32-bit).
- **H.** `VSXLEN` mirrors host XLEN.

**Haskell type-level machinery.** XLEN is encoded as a type-level
`Nat` (via `DataKinds` + `KnownNat`), *not* a closed enum. Rationale:

1. **Clash's width-indexed types fall out naturally.** The register
   file is `BitVector xlen`, the ALU is
   `alu :: BitVector xlen -> BitVector xlen -> BitVector xlen`, the
   bus data word is `BitVector xlen` (or a multiple of it), etc.
   Clash already uses `Nat`-indexed widths everywhere; adopting
   `ccXLEN :: Nat` extends what's already there.
2. **Presets specialise by concrete `Nat`.** `tiny32 :: CoreConfig =
   CoreConfig { ccXLEN = 32, ... }`; Clash sees a concrete
   `KnownNat` at elaboration and emits one specialised Verilog module
   per preset.
3. **`ValidXLEN` gates spec-legal widths.** A closed type family
   `type family ValidXLEN n where ValidXLEN 32 = (); ValidXLEN 64 =
   (); ValidXLEN 128 = ()` restricts the synthesisable entry point;
   research builds lift the constraint.
4. **Future widths expressible without refactoring.** If we ever want
   to prototype a 256-bit scalar as a research fork, it's
   `performance256 = performance128 { ccXLEN = 256 }`.
5. **Type-level arithmetic composes.** Sv39 PTE layout uses fields
   whose widths depend on XLEN; deriving them as `xlen − 12` etc. at
   the type level is exactly how Clash already describes internal
   widths.

### 3.2 Classic extensions

| Code | Name | What it adds |
|---|---|---|
| **RV32I / RV64I / RV128I** | base integer | 47 instructions in RV32I (arith, loads, stores, branches, jumps). Mandatory on every tier, in the edition's XLEN. Already shipped at RV32I. |
| **Zicsr** | CSR access | `CSRRW / CSRRS / CSRRC` + immediate variants. Required for any interrupts or privileged mode. Already shipped. |
| **Zifencei** | instruction-fetch fence | `FENCE.I`. Needed for self-modifying / JIT code, Linux module load. Already shipped. |
| **M** | integer **M**ul / div | `MUL`, `MULH(S/U)`, `DIV(U)`, `REM(U)`. Cyclone II: ~600 LEs LUT-based, or ~0 LEs + 4 DSPs with DSP inference. |
| **A** | **A**tomic memory | `LR.W / SC.W` (Zalrsc subset) + full AMO set `AMOADD/XOR/OR/AND/MIN/MAX/*.W` (Zaamo). Needed for Linux SMP and any lock-free code. |
| **F** | single-precision **F**loating-point | 32-bit IEEE 754 FPU, `f0–f31` + `FADD.S / FMUL.S / …`. ~2500 LEs + multiple DSPs on Cyclone. |
| **D** | **D**ouble-precision FP | 64-bit IEEE 754. Requires F. Roughly doubles FPU cost. |
| **C** | **C**ompressed | 16-bit encodings of common instructions. Halves I-cache pressure; adds a 2→4-byte fetch realigner. Cheap win. |
| **Q** | **Q**uad-precision FP | 128-bit IEEE 754. Pairs with RV128. Not planned. |

### 3.3 Bit manipulation (Zb*)

| Code | What it adds |
|---|---|
| **Zba** | address-generation: `SH1ADD`, `SH2ADD`, `SH3ADD` — shift-and-add for indexed addressing. Cheap, high-frequency. |
| **Zbb** | basic bit manipulation: `ANDN`, `ORN`, `XNOR`, `CLZ`, `CTZ`, `CPOP`, `MIN`, `MAX`, `ROL / ROR`, `SEXT.B / SEXT.H`, `ZEXT.H`. Big code-size + perf win. |
| **Zbc** | carry-less multiply: `CLMUL`, `CLMULH`, `CLMULR`. Useful for CRC / crypto. |
| **Zbs** | single-bit ops: `BCLR`, `BEXT`, `BINV`, `BSET` + immediate forms. |

### 3.4 Code-size reduction (Zc*)

| Code | What it adds |
|---|---|
| **Zcb** | extra short compressed instructions. |
| **Zcmp** | push/pop + move pair: `PUSH`, `POP`, `MVA01S07` — collapses function prologue / epilogue, big code-size win. |
| **Zcmt** | compressed table jump for switches. |

### 3.5 Privileged / virtualisation

| Code | What it adds |
|---|---|
| **S-mode** | **S**upervisor mode. Linux / seL4 / FreeRTOS-class OS hosting. Needs paired M-mode. Adds supervisor CSRs + `SRET`. |
| **U-mode** | **U**ser mode. Application-level privilege. Paired with S for an OS. |
| **H** | **H**ypervisor. Two-stage address translation, VS / VU privilege levels, hypervisor CSRs. KVM target. |
| **Sv32 / Sv39 / Sv48 / Sv57** | page-based MMU at 32 / 39 / 48 / 57-bit virtual addresses. Sv32 is the RV32 canonical choice. |
| **Svadu** | hardware auto-update of A (accessed) and D (dirty) PTE bits — saves the soft-update trap cycle. |
| **Svnapot** | Naturally-Aligned-Power-Of-Two huge-page translation. |
| **Svpbmt** | page-based memory types — per-page cacheable / device / non-cacheable bits. |
| **Smepmp** | enhanced PMP (Physical Memory Protection). |

### 3.6 Interrupts / timers (modern controllers)

| Code | What it adds |
|---|---|
| **Smaia** (M-mode) + **Ssaia** (S-mode) | **A**dvanced **I**nterrupt **A**rchitecture. Replaces classic MIP / MIE bitmaps with per-source interrupt files scalable to hundreds of sources, plus **IMSIC** (Incoming Message-Signaled Interrupt Controller) and **APLIC** (Advanced Platform-Level Interrupt Controller). Needed for modern server / multi-core RISC-V. |
| **Sstc** | S-mode timer: `stimecmp` CSR — S-mode programs a timer interrupt without trapping to M-mode every tick. |
| **Smstateen** | fine-grained state-enable CSRs for newer extensions across privileges. |

### 3.7 Cache maintenance + miscellaneous

| Code | What it adds |
|---|---|
| **Zicbom** | cache-block management: `CBO.CLEAN`, `CBO.FLUSH`, `CBO.INVAL` — DMA coherency primitives. |
| **Zicboz** | cache-block zero: `CBO.ZERO`. |
| **Zicbop** | cache-block prefetch: `PREFETCH.I / R / W` hints. |
| **Zicntr** | basic counters: `cycle`, `time`, `instret`. |
| **Zihpm** | 29 HW performance-monitor counters. |
| **Zicond** | branchless conditional zeroing: `CZERO.EQZ`, `CZERO.NEZ`. |
| **Zawrs** | low-power wait-on-reservation-set: `WRS.NTO`, `WRS.STO`. |
| **Zfa** | additional FP: min / max variants, FP-to-int conversions, round instructions. |
| **Zfh** | half-precision (16-bit IEEE 754) FP. |

### 3.8 Vector (deferred)

| Code | What it adds |
|---|---|
| **V** | RISC-V Vector 1.0 (scalable SIMD). Large, separate design effort — **explicitly deferred**. Single dimension on `ccExt.extV`; defaults to `False` at every tier. |

## 4. The five tiers

### 4.1 Summary at a glance

One-line-per-tier headline view.

| Tier | Style | Issue / ROB | XLEN presets | Default I$ / D$ / L2 | Key extensions (default-on) | Comfortable board | DE2 minimal fit |
|---|---|---|---|---|---|---|---|
| **Tiny** | in-order pipelined, 2–5 stages | 1 / — | `tiny32`, `tiny64` | 1 KB / 1 KB / — | RV32I/64I + Zicsr + Zifencei; M / A / C opt-in | Cyclone II (DE2) | ✓ primary fit |
| **Little** | entry-level OoO, in-order retire | 1 / 8 | `little32`, `little64` | 2 KB / 2 KB / — | RV32IMC + Zicsr + Zifencei | Cyclone IV (DE2-115) | ✓ minimal variant likely fits |
| **Mid** | P2 / Core-2-class OoO, 3-wide | 3 / 40 | `mid32`, `mid64` | 8 KB / 8 KB / opt 32 KB | RV32IMAC + Zihpm; first S-mode + Sv32 (Linux-capable) | Cyclone V GT | ? tight minimal variant |
| **Big** | subset of Performance, 3-wide OoO | 3 / 64 | `big32`, `big64` | 16 KB / 16 KB / 128 KB | RV32IMAFC + Zba/Zbb/Zbs + Zicbom + Smaia/Ssaia + Sstc | Arria 10 | ✗ over budget (research-fit) |
| **Performance** | max OoO, 4-wide, TAGE, prefetch, speculation | 4 / 128+ | `performance32`, `performance64`, `performance128` (speculative) | 32 KB / 32 KB / 512 KB | everything bar V + full priv (M+S+U+H) + AIA + Sv39 / Sv48 | Agilex / high-end Arria 10 | ✗ over budget (sim-only on DE2) |

**Orthogonal dimensions applying to every tier.**

- **XLEN** — 32 / 64 / 128. Type-level `Nat`. 32 and 64 for every tier;
  128 for Performance only and only speculatively.
- **Extensions** — every ISA extension is an individual Boolean knob.
  Presets set defaults; customs override per field.
- **Privilege** — M / MU / MSU / MSUH. MMU: None / Sv32 / Sv39 / Sv48
  / Sv57.
- **Fusion / uop ISA** — in-situ for Tiny + Little; explicit uop ISA
  for Mid / Big / Performance (shared format, `rs3`-capable).

### 4.2 Tier matrix (microarchitectural defaults)

Every row is a *default* for the two editions of that tier. XLEN-
specific defaults shown as `32 / 64` where they differ; every knob
is individually overridable.

| Knob | Tiny | Little | Mid | Big | Performance |
|---|---|---|---|---|---|
| Editions | `tiny32`, `tiny64` | `little32`, `little64` | `mid32`, `mid64` | `big32`, `big64` | `performance32`, `performance64`, `performance128` (spec) |
| Pipeline | in-order pipelined, 2–5 stages | OoO exec + in-order retire, 4 stages | OoO, 5–6 stages | OoO, 7–8 stages | OoO, 9–12 stages |
| Issue width | 1 | 1 | 3 | 3–4 | 4–6 |
| Retire width | 1 | 1 | 3 | 3 | 4 |
| ALUs | 1 | 1 | 2 | 3 | 4 |
| LSUs | 1 | 1 | 1 (split AGU) | 2 | 2 |
| Branch units | shared w/ ALU | 1 | 1 | 1 | 2 |
| Mul / Div | iterative | iterative | pipelined mul / iter div | pipelined / pipelined | pipelined / pipelined |
| Branch pred | static BTFN | 1-bit BHT + BTB-8 + RAS-4 | gshare + BTB-128 + RAS-8 + indirect | gshare / tournament + BTB-256 + RAS-16 | TAGE + BTB-512 + RAS-32 + loop predictor |
| Rename | none | 32→48, 2-wide RAT | 32→64, 3-wide | 32→96, 6-wide | 32→128+, 8-wide |
| ROB | none | 8 | 40 (P2-class) | 64 | 128+ |
| IQ | none | unified 8 | unified / clustered 16 | clustered 16+16+16 | clustered 20+20+20+20 |
| LSQ | inline | 4 / 4 | 16 / 16 | 24 / 24 | 32 / 32 |
| I$ / D$ | 1 KB / 1 KB direct-mapped, write-through | 2 KB / 2 KB direct | 8 KB / 8 KB 2-way | 16 KB / 16 KB 2-way | 32 KB / 32 KB 4-way |
| L2 | none | none | optional 32 KB | 128 KB | 512 KB |
| Fusion | in-situ (`LUI + ADDI`) | in-situ extended | explicit uop ISA | explicit uop ISA | explicit uop ISA (widest patterns) |
| Uop ISA | none | implicit | explicit | explicit | explicit |
| Default priv | M | M | M+U or M+S+U | M+S+U (+ H optional) | M+S+U+H |
| Default MMU (RV32 / RV64) | none / none | none / none | Sv32 / Sv39 | Sv32 / Sv39 | Sv32 / Sv48 (or Sv39) |
| Comfortable target (RV32) | Cyclone II EP2C35 (DE2) | Cyclone IV GX (DE2-115) | Cyclone V GT | Arria 10 | Agilex |
| Comfortable target (RV64) | Cyclone IV (tight) / V | Cyclone V | Arria 10 | Arria 10 / Agilex | Agilex |
| **DE2 minimal-settings attempt** | primary fit ✓ | feasible (maybe tight) | stretch, likely over budget | aspirational, likely infeasible | almost certainly infeasible |
| Rough LE / ALM (RV32 / RV64) | 5–8 k / 10–14 k | 12–18 k / 20–30 k | 35–50 k / 55–75 k | 70–100 k / 110–150 k | 150+ k / 220+ k |

### 4.3 Tiny — in-order pipelined

Direct evolution of today's 2-stage F+X core
([`src/Riski5/Core.hs`](../src/Riski5/Core.hs)). Pipeline grows to a
classic 3–5 stages (F, D, X, M, W) with forwarding + hazard
detection but stays strictly in-order. No rename, no ROB, no
speculation.

**Defaults.** 1 ALU (with shift + branch compare), 1 LSU, optional
iterative Mul / Div when `extM` is on. Static BTFN branch prediction
— the 1-cycle taken-branch penalty matches the pipeline depth.

**Memory.** BRAM + SRAM + SDRAM via `Bus.hs` (unchanged). Small caches
are **standard on Tiny**: 1 KB direct-mapped I$ + 1 KB direct-mapped
D$ (write-through, no MSHR, single outstanding miss) sit transparently
between the core and SRAM / SDRAM. The BRAM at `0x0000_0000` remains
a tightly-coupled scratchpad — uncached by construction, direct
address-decoded, the same zero-latency path it has today. The caches
exist because without them every SDRAM access pays full CAS latency.
Cost: ~2 M4K for each cache (1 M4K tags + 1 M4K data), pair ≈ 4 M4K;
Tiny's M4K footprint rises from ~5 to ~9, still well inside the
105-block pool. `CacheNone` remains a valid knob for tightest-area
experiments.

**Fusion.** In-situ only, `LUI + ADDI` pattern. No separate uop ISA.

**Extension defaults.** RV32I + Zicsr + Zifencei. M / A / C are opt-in
knobs. F / D never on Tiny by default.

**Target.** Cyclone II EP2C35 (DE2). Budget 5–8 k LE (RV32) including
the 1 KB I$ + 1 KB D$, 10–14 k LE (RV64), ~9 M4K. Phase 2A
introduces `CoreConfig` and hoists `Core.hs` behind `tiny32`; phase
2B enables M via the iterative unit; **phase 2C lands
`Mem/Cache.hs`**, turning today's BRAM-only direct path into an
I$ / D$ fronting SRAM + SDRAM. The RV64 edition (`tiny64`) lands in
phase 5A — same pipeline, regfile widened to 64 bits, `.W`
instructions decoded, `LD` / `SD` paths added to the LSU. `tiny64` is
the largest *in-order pipelined* core that still plausibly fits DE2;
every larger tier leans on the minimal-variant feasibility exercise
(§7).

### 4.4 Little — entry-level OoO

First OoO tier. Single-issue, 8-entry ROB, simple rename
(32→48 physical). Designed to fit a DE2-115-class board.

**Pipeline.** 4 stages (F, D+Rename, Issue, EX+WB). ROB-based,
single-issue from a unified 8-entry issue queue. In-order retire per
RVFI contract.

**Functional units.** 1 ALU with branch, 1 LSU (AGU shared into the
ALU path), 1 iterative Mul / Div. 1-bit BHT (32 entries), BTB-8,
RAS-4.

**Caches.** 2 KB direct-mapped I$, 2 KB write-through D$. Small MSHR
file.

**Fusion.** Extended in-situ set (`LUI+ADDI`, `AUIPC+ADDI`,
`ADDI+ADD` displacement, etc.). No separate uop ISA yet — the extra
`rs3` slot in the downstream pipeline is unused.

**Extensions.** RV32IMC + Zicsr + Zifencei default. A (Zalrsc only)
optional. Zba / Zbb optional (cheap).

**Target.** Comfortable fit on Cyclone IV GX EP4CGX150 (DE2-115) or
Cyclone V; we don't own either. **On DE2 (Cyclone II EP2C35),
`little32Minimal` — 1-issue, 4-entry ROB, 2-entry IQ, 2 / 2 LSQ,
32→36 rename, 1 KB direct-mapped caches, no L2, no FPU — is likely
to fit** (estimate 15–19 k total LE including SoC). That's the
headline feasibility question for phase 3B: first OoO silicon on the
board we actually have. Phase 3B (RV32) / 5B (RV64). `little64` on
DE2 is almost certainly over budget.

### 4.5 Mid — Pentium II / Core-2 shape

The literal P2 / Core-2 machine in riski5 terms. First tier with an
**explicit uop ISA**.

**Pipeline.** 5–6 stages (F1 / F2, D+Rename, Dispatch, Issue,
EX+MEM+WB). 3-wide dispatch and retire, 40-entry ROB.

**Functional units.** 2 ALUs (one with branch), 1 LSU split into AGU
+ D$ access stages, pipelined mul (3–4 cycles, DSP-backed),
iterative div.

**Caches.** 8 KB 2-way I$, 8 KB 2-way write-back D$. Optional unified
32 KB L2 on bigger devices.

**Rename / ROB.** 32→64 physregs, 3-wide RAT, 40-entry ROB,
LSQ 16 / 16 with store-forwarding.

**Branch prediction.** gshare (8-bit history), BTB-128, RAS-8,
indirect predictor (target cache).

**Fusion.** Explicit uop ISA. Patterns: `LUI+ADDI`, `AUIPC+ADDI`,
`ADD+LW/SW` (indexed, 3-source), `SLT+BEQ/BNE` (compare+branch).

**Extensions.** RV32IMAC + Zicsr + Zifencei + Zihpm default. Optional
F (one FPU pipeline). Optional S-mode + Sv32 + Sstc (first
Linux-capable tier). Zba / Zbb default-on; Zbs / Zbc optional.

**Target.** Cyclone V GT / Arria 10 comfortable; **minimal-on-DE2
attempt** collapses to 1-issue with ROB=8, IQ=4, 1 KB caches, no L2
and becomes a research fit exercise on Cyclone II. Phase 3C (RV32) /
5C (RV64). `mid64` is the first Linux-capable RV64 tier — pairs with
Sv39 by default for 64-bit page tables — but needs a larger board
than DE2.

### 4.6 Big — subset of Performance

Identical microarchitectural *shape* to Performance, every knob
dialled down one notch.

**Pipeline.** 7–8 stages, 3-wide dispatch, 64-entry ROB, clustered
issue queues (int + mem + branch-FP).

**Functional units.** 3 ALUs, 2 LSUs, pipelined mul + pipelined div,
1 single-precision FPU pipeline (double optional).

**Caches.** 16 KB 2-way I$, 16 KB 2-way write-back D$, 128 KB unified
4-way L2. MSHR 4 per level.

**Rename / ROB.** 32→96 physregs, 6-wide RAT, 64-entry ROB, LSQ
24 / 24.

**Branch prediction.** gshare / tournament, BTB-256, RAS-16, indirect,
return-stack w/ mis-speculation recovery.

**Fusion.** Explicit uop ISA (shared with Mid / Performance).

**Extensions.** RV32IMAFC + Zicsr + Zifencei + Zihpm + Zba / Zbb /
Zbs + Zicbom + S-mode + Sv32 / Sv39 + Sstc + Smaia / Ssaia default.
Optional H + Svadu + Svpbmt. Zcmp / Zcmt optional.

**Target.** Arria 10 comfortable; **no DE2 fit expected** even with
every knob dialled to minimum — the OoO machinery (rename map, ROB
CAM, LSQ) in Big's shape plus the FPU will exceed 33 k LE / 105 M4K.
We still ship `big32Minimal` as a preset and record the Quartus fit
report showing which block is the dominant overhead; that number
motivates eventual board procurement. Phase 4A (RV32) / 5D (RV64).
`big64` is the default production RV64 core — Sv39 MMU, full
extension set, Linux + KVM guest capable via H.

### 4.7 Performance — everything

**Pipeline.** 9–12 stages, 4-wide dispatch, 128+ ROB, per-cluster
issue queues × 4 (int1, int2, mem, branch-FP).

**Functional units.** 4 ALUs (one complex w/ shift-mul-hint, one
branch-redirect, two plain), 2 independent LSUs into a dual-ported
D$, 2 branch units, pipelined mul + pipelined div, 2 FP pipelines (F
+ D).

**Caches.** 32 KB 4-way I$ (1-cycle hit), 32 KB 4-way write-back D$
(2 load ports, 2-cycle hit), 512 KB 8-way unified L2 (~8 cycles).
Stride prefetcher on L1D and L2. MSHR 8+ at D$, 16+ at L2.

**Rename / ROB.** 32→128+ physregs, 8-wide RAT, 128+ ROB,
LSQ 32 / 32 with speculative loads + order-violation replay.

**Branch prediction.** TAGE-class (5+ tagged tables), BTB-512,
RAS-32, loop predictor, indirect-target predictor. Speculative
execution with full checkpoint / walk-back.

**Fusion.** Widest set: `LUI+ADDI+ADD` (3-way base+disp),
`CMP+BRANCH`, load-pair / store-pair on consecutive aligned
addresses.

**Extensions.** Everything bar V. Full priv stack (M+S+U+H), AIA
(Smaia + Ssaia + IMSIC + APLIC), Sstc, Sv39 / Sv48, Svnapot, Svadu,
Svpbmt, Smstateen, Smepmp, Zicbom / Zicboz / Zicbop, Zba / Zbb / Zbs
/ Zbc, Zcmp / Zcmt / Zcb, Zicond, Zawrs, Zfa, Zfh, Zihpm, Zicntr.

**Target.** Agilex / high-end Arria 10 comfortable; **DE2 fit not
expected**. `performance32Minimal` exists for sim-only validation —
run the full catalog under verilambda (no area constraint there),
record the would-be LE / M4K cost from Quartus even if no bitstream
ships. Phase 4B. Vector (V) is a separate design doc.

## 5. Type-level parameter space

### 5.1 Top-level `CoreConfig`

```haskell
-- src/Riski5/Core/Config.hs
module Riski5.Core.Config where

data CoreConfig = CoreConfig
  { -- Base variant — register width
    ccXLEN          :: Nat             -- type-level Nat: 32, 64, 128 standard;
                                       -- 256+ reserved for non-standard research
                                       -- variants (no opcode slot in the spec).
                                       -- KnownNat constraint + width-indexed
                                       -- BitVector XLEN throughout the core.
    -- Pipeline + issue
  , ccPipeline      :: PipelineShape
  , ccIssueWidth    :: Nat
  , ccRetireWidth   :: Nat
  , ccPipelineDepth :: Nat
    -- Functional-unit counts
  , ccNumALU        :: Nat
  , ccNumLSU        :: Nat
  , ccNumBranch     :: Nat
  , ccMulDiv        :: MulDivSpec
  , ccFPU           :: FpuSpec
    -- Speculation / rename / OoO
  , ccRename        :: RenameSpec      -- RenameNone for in-order
  , ccROB           :: RobSpec         -- RobNone for in-order
  , ccIssueQueue    :: IqSpec
  , ccLSQ           :: LsqSpec
    -- Branch prediction
  , ccBPU           :: BpuSpec
    -- Memory system
  , ccICache        :: CacheSpec
  , ccDCache        :: CacheSpec
  , ccL2            :: Maybe CacheSpec
  , ccPrefetch      :: PrefetchSpec
    -- Fusion / uop
  , ccFusion        :: FusionSpec
  , ccUopISA        :: UopIsaMode
    -- Architectural extensions
  , ccExt           :: ExtConfig
    -- Privilege + memory model
  , ccPriv          :: PrivConfig
    -- Observability
  , ccRVFI          :: Bool
    -- Target device hint (informational)
  , ccDeviceClass   :: DeviceClass
  }
```

### 5.2 Sub-records

```haskell
data PipelineShape
  = PipeInOrder Nat          -- N classic in-order scalar stages
  | PipeOoO Nat              -- N front + back stages, OoO exec

data MulDivSpec
  = MdNone
  | MdIterative { mdCyclesMul :: Nat, mdCyclesDiv :: Nat }
  | MdPipelined { mdStagesMul :: Nat, mdStagesDiv :: Nat, mdDspBacked :: Bool }

data FpuSpec
  = FpuNone
  | FpuSingle { fpuPipelined :: Bool }
  | FpuDouble { fpuPipelined :: Bool }
  | FpuQuad                                -- reserved, not planned

data RenameSpec
  = RenameNone
  | RenameMap { rsNPhys :: Nat, rsRatRd :: Nat, rsRatWr :: Nat }

data RobSpec   = RobNone | Rob { robEntries :: Nat, robRetireW :: Nat }

data IqSpec
  = IqNone
  | IqUnified   { iqEntries :: Nat, iqWakeupPorts :: Nat }
  | IqClustered { iqClusters :: Nat, iqEntriesEach :: Nat }

data LsqSpec
  = LsqNone
  | Lsq { lsqLdEntries :: Nat, lsqStEntries :: Nat
        , lsqStoreFwd :: Bool, lsqSpecLoads :: Bool }

data BpuSpec
  = BpuStatic
  | BpuBimodal    { bpBhtEntries :: Nat, bpBtbEntries :: Nat, bpRasDepth :: Nat }
  | BpuGShare     { bpHistBits :: Nat, bpBtbEntries :: Nat, bpRasDepth :: Nat
                  , bpIndirect :: Bool }
  | BpuTournament { bpLocalBht :: Nat, bpGlobalHist :: Nat, bpChooser :: Nat
                  , bpBtbEntries :: Nat, bpRasDepth :: Nat
                  , bpIndirect :: Bool, bpLoop :: Bool }
  | BpuTAGE       { bpTables :: Nat, bpHistLen :: Nat, bpBtbEntries :: Nat
                  , bpRasDepth :: Nat, bpIndirect :: Bool, bpLoop :: Bool }

data CacheSpec
  = CacheNone
  | CacheDirect { cSize :: Nat, cLine :: Nat }
  | CacheAssoc  { cSize :: Nat, cLine :: Nat, cWays :: Nat
                , cWriteBack :: Bool, cMshrs :: Nat }

data PrefetchSpec = PrefetchNone | PrefetchStride { pfStreams :: Nat }

data FusionSpec   = NoFusion | InSitu FusionSet | Explicit FusionSet
data UopIsaMode   = UopNone | UopImplicit | UopExplicit

data FusionSet = FusionSet
  { fsLuiAddi    :: Bool  -- LUI + ADDI  → LI20
  , fsAuipcAddi  :: Bool  -- AUIPC + ADDI → PC-relative LI
  , fsAddiAdd    :: Bool  -- displacement + base addr calc
  , fsIndexedLd  :: Bool  -- ADD + LW → LW_IDX (3-source)
  , fsIndexedSt  :: Bool  -- ADD + SW → SW_IDX
  , fsCmpBranch  :: Bool  -- SLT / SLTU + BEQ / BNE
  , fsLuiAddiAdd :: Bool  -- 3-way base + disp
  , fsLdPair     :: Bool  -- LW + LW consecutive (Performance only)
  }

-- Every architectural extension as an individual Boolean knob. Presets
-- only set *defaults*; customs override any field.
data ExtConfig = ExtConfig
  { -- Classic
    extM          :: Bool
  , extA          :: AExt
  , extF          :: Bool
  , extD          :: Bool
  , extC          :: Bool
    -- Bit manipulation
  , extZba        :: Bool
  , extZbb        :: Bool
  , extZbc        :: Bool
  , extZbs        :: Bool
    -- Code size
  , extZcb        :: Bool
  , extZcmp       :: Bool
  , extZcmt       :: Bool
    -- Counters / perf
  , extZicntr     :: Bool
  , extZihpm      :: Bool
    -- Cache management
  , extZicbom     :: Bool
  , extZicboz     :: Bool
  , extZicbop     :: Bool
    -- Misc
  , extZicond     :: Bool
  , extZawrs      :: Bool
  , extZfh        :: Bool
  , extZfa        :: Bool
    -- Hypervisor + vector
  , extH          :: Bool
  , extV          :: Bool                  -- reserved; not implemented
    -- State-enable
  , extSmstateen  :: Bool
  }

data AExt = AOff | AZalrsc | AFull         -- Zalrsc = LR / SC only; AFull adds Zaamo

data PrivConfig = PrivConfig
  { privModes     :: PrivModes             -- M | MU | MSU | MSUH
  , privMMU       :: MMUSpec               -- None | Sv32 | Sv39 | Sv48 | Sv57
  , privSvadu     :: Bool
  , privSvnapot   :: Bool
  , privSvpbmt    :: Bool
  , privSmepmp    :: Bool
  , privAIA       :: AIASpec               -- None | Smaia | SmaiaSsaia (+ IMSIC / APLIC opt)
  , privSstc      :: Bool
  , privPMP       :: PMPSpec               -- 0 / 16 / 64 regions
  , privZicsr     :: Bool
  , privZifencei  :: Bool
  }

data PrivModes  = PrivM | PrivMU | PrivMSU | PrivMSUH
data MMUSpec    = MMUNone | MMUSv32 | MMUSv39 | MMUSv48 | MMUSv57
data AIASpec    = AIANone | AIASmaia | AIASmaiaSsaia
data PMPSpec    = PMPNone | PMP16 | PMP64

data DeviceClass = CycloneII | CycloneIV | CycloneV | Arria10 | Agilex
```

### 5.3 The presets (values — sketched)

```haskell
-- src/Riski5/Core/Presets.hs
module Riski5.Core.Presets where

-- Each preset is a delta on the one below (tiny → little → mid → big → performance).
tiny32, tiny64            :: CoreConfig
little32, little64        :: CoreConfig
mid32, mid64              :: CoreConfig
big32, big64              :: CoreConfig
performance32             :: CoreConfig
performance64             :: CoreConfig
performance128            :: CoreConfig   -- speculative; RV128 not ratified

-- Custom core: a preset with overrides.
tinyImc :: CoreConfig
tinyImc = tiny32
  { ccExt = (ccExt tiny32) { extM = True, extC = True } }

performanceWide :: CoreConfig
performanceWide = performance64 { ccIssueWidth = 6 }
```

Presets get their full values in `src/Riski5/Core/Presets.hs` during
phase 2A.

### 5.4 Elaboration

```haskell
coreWith ::
  forall (cfg :: CoreConfig) dom.
  (HiddenClockResetEnable dom, KnownCoreConfig cfg) =>
  CoreIn dom -> CoreOut dom
```

`KnownCoreConfig` bundles `KnownNat` / `SingI` constraints on every
field. Clash specialises per-`cfg` and emits one Verilog module per
invocation — zero runtime overhead, fully synthesisable.

## 6. Composable block layer

Cores are assembled from reusable Clash blocks. Each block consumes
only *its slice* of `CoreConfig`.

| Block | Config slice it consumes |
|---|---|
| `Fetch` | `ccICache`, `ccBPU`, `ccIssueWidth` |
| `BranchPredictor` | `ccBPU` |
| `Decode` | — (shares `Riski5.ISA`) |
| `FusionPass` | `ccFusion`, `ccUopISA` |
| `Rename` | `ccRename` |
| `Dispatch` | `ccROB`, `ccIssueQueue` |
| `IssueQueue` | `ccIssueQueue` |
| `FunctionalUnit` × N | `ccNumALU`, `ccNumBranch`, `ccMulDiv`, `ccFPU` |
| `LoadStoreUnit` | `ccLSQ`, `ccDCache` |
| `ROB` | `ccROB` |
| `Retire` | `ccROB`, `ccRetireWidth`, `ccRVFI` |
| `Cache` (generic) | `CacheSpec` at each level |
| `Prefetcher` | `ccPrefetch` |
| `CsrFile` | `ccExt.extZihpm`, `ccPriv` |
| `TrapUnit` | `ccPriv` |
| `Mmu` | `ccPriv.privMMU`, `ccPriv.privSvadu`, etc. |
| `InterruptController` | `ccPriv.privAIA`, `ccPriv.privSstc` |

**Key wiring trick — in-order vs OoO with the same block topology.**
`Rename` / `ROB` / `IssueQueue` / `LSQ` each have a **degenerate
mode** for their `*None` specs: they elide to wires under Clash's
dead-code elimination. Tiny's dataflow (`Fetch → Decode →
FunctionalUnit → Retire`) goes through the same block topology as
Performance with zero extra logic. OoO tiers simply light up the
degenerate blocks into real logic by turning the knobs up.

### 6.1 Module layout

```
src/Riski5/
├── ISA.hs                      (single source of truth; parameterised on XLEN)
├── MemMap.hs                   (unchanged)
├── Rvfi.hs                     (unchanged)
├── Core.hs                     (Tiny's kernel in phase 2A)
├── Uop.hs                      NEW  internal uop ISA
├── Core/
│   ├── Config.hs               NEW  CoreConfig + sub-records
│   ├── Presets.hs              NEW  tiny/little/mid/big/performance × 32/64(/128)
│   ├── Assembly.hs             NEW  coreWith :: forall cfg. …
│   ├── Block/
│   │   ├── Fetch.hs
│   │   ├── BranchPredictor.hs
│   │   ├── FusionPass.hs
│   │   ├── Rename.hs
│   │   ├── Dispatch.hs
│   │   ├── IssueQueue.hs
│   │   ├── ROB.hs
│   │   ├── Retire.hs
│   │   ├── LoadStoreUnit.hs
│   │   ├── Mmu.hs
│   │   ├── CsrFile.hs          (extends existing CSR.hs with Zihpm / AIA / Sstc)
│   │   └── TrapUnit.hs
│   ├── FU/
│   │   ├── ALU.hs              (wraps today's Riski5.ALU)
│   │   ├── Branch.hs
│   │   ├── MulDiv.hs
│   │   └── Fpu.hs
│   └── Mem/
│       ├── Cache.hs
│       └── Prefetcher.hs
├── Ext/                        NEW  per-extension decoders / executors
│   ├── Zba.hs
│   ├── Zbb.hs
│   ├── Zbs.hs
│   ├── Zbc.hs
│   ├── Zcmp.hs
│   ├── Zicond.hs
│   ├── Zicbom.hs
│   └── H.hs                    (hypervisor)
└── Priv/                       NEW  privileged-mode modules
    ├── Supervisor.hs
    ├── Hypervisor.hs
    ├── Mmu/
    │   ├── Sv32.hs
    │   ├── Sv39.hs
    │   └── Sv48.hs
    └── Interrupts/
        ├── Aia.hs              (Smaia + Ssaia)
        ├── Imsic.hs
        └── Aplic.hs
```

## 7. Feasibility on DE2 (Cyclone II EP2C35) — minimal variants

riski5 has exactly one board in hand — the Altera DE2 (Cyclone II
EP2C35, 33 216 LEs, 105 M4K, 35 DSPs). No funds for DE2-115 /
Cyclone V / Arria 10 / Agilex kits in the near term. The plan
therefore keeps Big / Performance as *sim-only* tiers until a larger
board becomes procurable, while exploring *minimal-on-DE2* variants
of every tier to document LE / M4K cost honestly.

### 7.1 Budget math

SoC peripherals held at today's ~5 k LE / ~10 M4K.

| Tier (RV32, minimal knobs) | Core LE estimate | + SoC | Total vs 33 k LE | M4K vs 105 | Verdict |
|---|---:|---:|---|---:|---|
| `tiny32` no-cache (phase-1 style) | 4–6 k | +5 k | 9–11 k — **fits comfortably** | ~10 | ✓ phase 1 today |
| `tiny32` default (with 1 KB I$ + 1 KB D$) | 5–8 k | +5 k | 10–13 k — **fits** | ~14 | ✓ target from phase 2C |
| `tiny32 + M + C` | 7–10 k | +5 k | 12–15 k — **fits** | ~14 | ✓ |
| `little32Minimal` (1-issue, ROB=4, IQ=2, LSQ=2/2, rename 32→36, 1 KB direct I$ / D$, no L2) | 10–14 k | +5 k | 15–19 k — **likely fits** | 20–25 | ✓ probable |
| `mid32Minimal` (1-issue (collapse from 3), ROB=8, IQ=4, LSQ=4/4, 1 KB I$ + D$, no L2, gshare-small, *explicit uop ISA still on*) | 18–25 k | +5 k | 23–30 k — **tight but probable** | 25–35 | ? |
| `big32Minimal` (OoO shape preserved, 1 ALU, 1 LSU, ROB=16, IQ=8, 1 KB caches, **no L2**, no FPU) | 30–45 k | +5 k | 35–50 k — **over budget** | 35–50 | ✗ likely |
| `performance32Minimal` | 50+ k | +5 k | 55+ k — **over budget** | 60+ | ✗ almost certainly |
| any RV64 OoO tier (minimal) | ~2× the RV32 number | +5 k | **over budget for Little+** | — | ✗ |

**Caveats.** These are rough orders of magnitude inferred from
published OoO-core numbers; actual Clash codegen on a given preset
can swing ±30 % either way. The only way to know is to generate the
Verilog and run Quartus Fit.

### 7.2 What we do with this

Even when a tier clearly doesn't fit, the *attempt* is valuable — the
Quartus fit report tells us exactly which block is the LE hog
(usually the rename map, the ROB CAM, or the clustered issue queue).
That number per block, recorded in
`docs/fits/<tier>-minimal-de2.rpt`, is the factual basis for the
eventual decision about what larger board to procure, and guides
"which tier gives best return per LE on Cyclone II." Research output
is legitimate even when the bitstream never flashes.

Every tier's test catalog passes in verilambda sim (no area
constraint) **before** we worry about fitting; Quartus fit reports
then tell us which tiers actually reach silicon.

## 8. Phase / roadmap

Phase numbering continues from the phase-1 plan at
`/home/mika/.claude/plans/look-at-repositories-alterade2-flake-starry-shell.md`.
Phase 1 (pipelineless single-cycle + SoC on DE2) is the stable shipping
scope.

### Phase 2 — configurability skeleton + Tiny

- **2A.** Introduce `CoreConfig` + `Presets.hs` + `Core/Assembly.hs`.
  Hoist today's `Core.hs` behind `tiny32`. Zero functional change;
  Verilog diff ≈ 0; RVFI + riscv-formal still green on DE2.
- **2B.** M-extension as a knob via iterative mul / div:
  `tiny32 { ccExt = (ccExt tiny32) { extM = True } }`.
  `riscv-formal` `insn_mul* / div*` green.
- **2C.** `Mem/Cache.hs` lands: 1 KB direct-mapped I$ + 1 KB
  direct-mapped D$, write-through, single-outstanding-miss. Caches
  front SRAM (`0x2000_0000`) and SDRAM (`0x8000_0000`); BRAM at
  `0x0` stays direct-addressed (uncached scratchpad). C-extension
  knob + 16-bit fetch realigner. Zba / Zbb as cheap bit-manip knobs.

### Phase 3 — Little + Mid

- **3A.** Rename / ROB / IssueQueue / LSQ / Mmu blocks land in
  degenerate modes (area-neutral for Tiny).
- **3B.** `little32` preset green: 1-issue OoO with 8-entry ROB.
  First OoO silicon on DE2 via the `little32Minimal` custom.
- **3C.** `mid32` preset: 3-issue OoO, 40-entry ROB, explicit uop
  ISA introduced. First S-mode + Sv32 → first Linux boot target.
  AIA + Sstc scaffolding.

### Phase 4 — Big + Performance

- **4A.** `big32` preset: clustered IQ, L2, single-precision FPU,
  Zba / Zbb / Zbs, Zicbom, Sstc, AIA, S-mode default. Arria 10 target
  (procurement deferred); `big32Minimal` records Quartus fit cost on
  DE2.
- **4B.** `performance32` preset: TAGE, speculative loads, prefetch,
  full extension set (bar V), H-extension, Sv39, Svadu, Svpbmt.
  Agilex target (procurement deferred); sim-only on DE2.
- **4C+.** V (RISC-V Vector): separate design doc, not part of this
  plan.

### Phase 5 — RV64 editions

- **5A.** `tiny64`. Regfile widened, `.W` instructions, `LD` / `SD`
  in LSU. Plausibly fits DE2.
- **5B.** `little64`. DE2 minimal fit uncertain.
- **5C.** `mid64`. First Linux-capable RV64 tier; pairs with Sv39.
- **5D.** `big64`. Default production RV64 core with full extensions.
- **5E.** `performance64`. Linux + KVM + AIA.
- **5F+.** `performance128` when the RV128 spec ratifies (and only as
  a research preset until then).

### 8.1 Build-order priority (across phases)

1. `Core/Config.hs` + `Presets.hs` + `Assembly.hs` — even empty,
   forces every block to commit to its config slice.
2. `FU/ALU.hs` + `FU/Branch.hs` wrapping today's `Riski5.ALU`.
3. `Block/Fetch.hs` + `Block/BranchPredictor.hs` (static variant
   first).
4. `Block/LoadStoreUnit.hs` (degenerate in-order).
5. `Block/Retire.hs` + RVFI wiring preserved from
   [`src/Riski5/Rvfi.hs`](../src/Riski5/Rvfi.hs).
6. `FU/MulDiv.hs` (iterative) — phase 2B.
7. `Mem/Cache.hs` — phase 2C. The small direct-mapped cache is part
   of the Tiny preset, so it lands with Tiny, not later.
8. `Block/Rename.hs` + `Block/ROB.hs` + `Block/IssueQueue.hs` —
   phase 3A, degenerate first.
9. `Block/FusionPass.hs` + `Uop.hs` — phase 3C.
10. `Block/Mmu.hs` + `Priv/Supervisor.hs` +
    `Priv/Interrupts/Aia.hs` — phase 3C.
11. Branch-predictor variants (bimodal → gshare → tournament → TAGE)
    — grown through phases 3–4.
12. `Priv/Hypervisor.hs` + `Priv/Mmu/Sv39.hs` — phase 4B.

## 9. Verification

- **RVFI contract** from [`src/Riski5/Rvfi.hs`](../src/Riski5/Rvfi.hs)
  binds every tier. The retire stage emits one RVFI retire per
  architectural RV32I / RV64I instruction — fused uops split into
  multiple retires at commit, preserving the `riscv-formal` contract
  without the harness needing to know about fusion.
- **`pkgs/riski5-formal`** runs SymbiYosys per-tier with the same
  check set; higher tiers add cover tests for new extensions
  (bit-manip, atomics, FPU, paging).
- **Spike differential (`SpikeDiffSpec`)** is extended per extension:
  every enabled knob in `CoreConfig` gets a Spike-diff catalog entry.
- **Verilator sim via verilambda** runs per preset. CI builds each
  preset and runs `CoreSimSpec` + `SocHwSim` against it.
- **Hardware validation** per tier targets the appropriate dev board
  — DE2 for Tiny, DE2-115 / Cyclone V for Little / Mid (when
  procured), Arria / Agilex boards for Big / Performance (likewise).
  Until larger boards are procured, Big / Performance pass through
  sim + Quartus-fit-report only.

See [`verification.md`](./verification.md) for the three-layer
verification plan (reference-executor differential, Spike
differential, RVFI + riscv-formal) that each tier inherits.

## 10. Open design questions

- **DE2-only budget today.** The Altera DE2 (Cyclone II EP2C35) is
  the only board on hand. No funds for DE2-115 / Cyclone V / Arria 10
  / Agilex kits in the near term. Procurement is a future decision
  informed by the fit reports we collect along the way — see §7.
- **Feasibility of Mid / Big / Performance on DE2.** The honest
  unknown. Mid-minimal probably fits Cyclone II at 25–30 k LE;
  Big-minimal is estimated 35–50 k LE and likely over budget;
  Performance-minimal almost certainly doesn't fit. The way to know
  is to generate Verilog for each minimal preset and run Quartus Fit
  — one `docs/fits/<tier>-minimal-de2.rpt` per preset. Phase-3 / 4
  exit criteria.
- **Cache coherency.** Single-hart only through phase 4. Multi-hart
  adds `ccHarts :: Nat` dimension and MESI-class coherency; separate
  design doc.
- **Memory ordering.** `FENCE` is a nop today; needs real teeth on
  Mid+ once store-forwarding + speculative loads exist. Choose WMO
  vs TSO per tier.
- **DDR off-board memory.** Performance wants DDR3 / DDR4, not SDR
  SDRAM. Tied to eventual board procurement; DE2's 8 MB SDR SDRAM is
  the baseline for every DE2-targeted tier.
- **Vector (V).** Whole separate design effort; deferred. When it
  arrives, `VLEN` is independent of `ccXLEN` — V registers are their
  own namespace at 128 / 256 / 512 / 1024+ bits.
- **RV128 timing.** RV128 is spec-reserved but not ratified.
  `performance128` is useful as a research / GPU-substrate preset;
  locking in its decoder early means when the spec freezes we're
  already aligned. Packed-SIMD within 128-bit scalars (custom
  `Zsimd128` or similar) could land as a riski5-local extension well
  before upstream ratification. RV128 almost certainly will not fit
  DE2 at any tier.
- **Wider-than-128 scalar widths.** RV256 / RV512 scalars are *not*
  standard RISC-V. Keep the XLEN type-level `Nat` open so a research
  fork can set `ccXLEN = 256` without touching the block layer, but
  do not add a named preset. Wide vectorised compute goes through the
  V extension's `VLEN`, not through `XLEN`.

## 11. Cross-references

- [`CLAUDE.md`](../CLAUDE.md) — project conventions, Altera-IP
  policy, M4K budget, Cyclone-II targeting rules.
- [`verification.md`](./verification.md) — three-layer verification
  plan (reference-executor, Spike, RVFI + riscv-formal).
- [`future-soc-configurability.md`](./future-soc-configurability.md)
  — superseded by this document. Retained for historical context;
  its SoC-level IP-provider-per-peripheral story continues to apply
  at the SoC level, unchanged by this core-family expansion.
- [`references.md`](./references.md) — upstream research links
  (lion, clash-riscv, riscv-semantics, riscv-formal, etc.).
- Phase-1 task list
  `/home/mika/.claude/plans/look-at-repositories-alterade2-flake-starry-shell.md`
  — stable T1–T44 for the shipping phase-1 core.
