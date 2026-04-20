<!--
SPDX-FileCopyrightText: 2026 Mika Tammi
SPDX-License-Identifier: MIT OR BSD-3-Clause
-->

# CLAUDE.md

This file captures durable conventions and decisions for Claude Code
sessions in this repo. Read it before starting work.

## Project in one paragraph

A minimal **Clash RV32I + SoC** on the Altera DE2 (Cyclone II
EP2C35F672C6). **Pipelineless single-cycle** core with
**Zicsr + M-mode + Zifencei**, aiming eventually at Linux. Sibling
repos `alterade2-flake` (Quartus + flashing) and `verilambda` (our
Haskell wrapper around Verilator) are consumed as flake inputs — both
path-based during active development. The ISA is defined at the
Haskell type level and is the single source of truth for both the
hardware decoder and the firmware assembler eDSL.

## Design style — load-bearing

- **Pipelineless single-cycle.** No pipeline registers, no forwarding,
  no stalls. One instruction retires per clock. The only caveat is a
  one-cycle BRAM read latency (PC at N−1 → instruction at N), which we
  accept rather than fight.
- **Type-level ISA is the single source of truth.** `src/Riski5/ISA.hs`
  is consumed by the hardware decoder *and* the firmware assembler.
  Changing the ISA means editing one file.
- **No external RISC-V assembler in phase 1.** Hello-world and every
  test firmware is built from Haskell via `Riski5.Asm`.
  `pkgsCross.riscv32-embedded.buildPackages.binutils` enters only in
  phase 2 when we need to link C or the upstream `riscv-tests`.

## Testing rule

Every RV32I instruction and every memory region must pass in
**verilambda simulation *and* on the real DE2** via the on-board test
agent + JTAG-UART diff. `test/InstrCatalog.hs` is the shared source;
never duplicate a test between sim-only and hardware-only. A feature is
not "done" until both layers are green.

## Formal verification policy

Three complementary layers, in rising order of strength and cost. See
[docs/verification.md](./docs/verification.md) for the full plan.

1. **Haskell-side differential testing against a reference executor**
   (live from Day 1). `src/Riski5/Reference.hs` is a minimal pure-Haskell
   RV32I interpreter — a golden oracle that Hedgehog properties compare
   against. Not a formal proof, but the tightest standalone check we
   can run without a hardware simulator. The reference is inspired by
   `mit-plv/riscv-semantics` and can later be swapped for (or
   cross-checked against) that upstream package; see
   `docs/references.md` for the link.

2. **RVFI + YosysHQ/riscv-formal** (lands at the end of phase 1B,
   once `Core.hs` exists). RVFI tap ports get added to the core from
   the start so the Verilog Clash emits is `riscv-formal`-ready.
   SymbiYosys model-checks the Verilog against the RVFI contract
   (register-file, memory, pc-advance, trap, CSR) for a few hundred
   bounded cycles per instruction class. This is the industrial-grade
   formal-proof layer.

3. **Liquid Haskell on pure modules** (phase 2 opt-in, annotate
   selectively). Refinement types for things the Haskell type system
   can't express naturally — e.g. "B-type immediate bit 0 is always
   zero", "`decode` is total across its domain", "FENCE `fm` field is
   exactly 0 for non-TSO". Not adopted in phase 1 because the value
   over the existing width-indexed types is marginal and the build
   complexity (SMT + plugin pinning) is not.

**No Verilator upstream contributions for now** — per the verilambda
policy, sim-layer issues are patched in verilambda.

## Hardware targeting rules (Cyclone II-specific)

- Map program/data memory + cache tag/data arrays to M4K (via
  Clash `blockRam`), never LUT-RAM. **Exception: the phase-1
  regfile is an async-read register array (~1024 FFs + 32:1 read
  mux on LEs), not M4K.** The pipelineless single-cycle design
  can absorb at most one cycle of read latency per instruction —
  that slot goes to the imem fetch. Moving the regfile back onto
  M4K is on the menu when we pipeline the core (see `Riski5.Regfile`
  header for the full rationale); a 2+ stage pipeline naturally
  aligns regfile reads with an ID or EX stage.
- Write the ALU adder as plain `+` on `BitVector`/`Signed` so Quartus
  infers Cyclone II carry chains; same for the PC and branch-target
  adders.
- Barrel shifter = 5-stage log shift (1/2/4/8/16), each stage a
  2:1 mux — 4-LUT-friendly on Cyclone II.
- Reserve the 35 embedded 18×18 multipliers for phase-2 M-extension.
  When used, write the multiply at the bit-width level so Quartus's
  DSP inference picks them up; **never hand-build a multiplier**.
- Phase 1 is a single clock domain. Start at 50 MHz (`CLOCK_50`
  directly); phase 1E explores maxing out fmax via a PLL, still
  single-domain.
- Quartus synthesis effort: **Area/Balanced, not Speed**.
- Register every external-facing signal in the DE2 top entity so
  Quartus places FFs in the I/O cells.

## Don't invent

Never fabricate URLs, Nix attributes, flag names, chip part numbers,
or Terasic pin names. If a claim can be verified (DE2 User Manual,
GitHub releases page, `nix search`, `nixpkgs` source), verify it. If
it can't be verified in the session, mark it clearly as
"typical / to confirm" and move on.

## Altera IP black-boxing policy

Prefer own-Clash implementations for the learning value, but use
Altera's free IP (JTAG UART, SDRAM controller, PLLs) when either
(a) it's a deep-standard peripheral we don't gain from reimplementing,
or (b) we hit a real-hardware timing issue we can't solve ourselves.
Decision recorded here when made.

**Current phase-1 decisions:**

- JTAG UART: Altera IP, black-boxed via `Riski5.JtagUart`.
- SDRAM: Altera IP first (phase 1D, T31–T39). Own Clash controller is
  the fallback (T32a–T36a) only if the IP fails to bring up.

**Forward-looking — SoC configurability.** Phase 1 builds one concrete
SoC. Phase 2+ grows a type-parameterised SoC generator: IP-provider
choice per peripheral (Altera vs own-Clash), cache configurations,
four core classes (tiny / little / big / performance). Every variant
we ship along the way records Fmax / LE / M4K data that feeds that
design. See
[docs/future-soc-configurability.md](./docs/future-soc-configurability.md)
for the full note.

## Verilambda policy

verilambda (`github:purefunsolutions/verilambda`, our own Haskell
wrapper around Verilator) is the project's simulator interface. When
we need features or fixes at the sim layer, patch **verilambda** at
`~/verilambda` directly — it's our repo. Improvements land as ordinary
commits there; no external tracker, no PRs to anyone else.
**No Verilator upstream contributions for now.** If a Verilator-level
issue surfaces, the workaround goes inside verilambda (shim, codegen
tweak, pinned version), never in riski5's testbenches.

## Memory map lives in one file

`src/Riski5/MemMap.hs` holds every physical address constant in one
place; any address anywhere else must import from there. Bus decoder,
reset PC, default `mtvec`, firmware peripheral addresses, test
catalogs — all refer back to one authoritative map.

Phase-1 map (decoded on upper 4 bits in `Bus.hs`):

| Region  | Base          | Size    |
|---|---|---:|
| BRAM    | `0x0000_0000` | 4 KB    |
| JTAG UART | `0x1000_0000` | 16 B   |
| GPIO    | `0x1000_0020` | 32 B    |
| LCD     | `0x1000_0040` | 32 B    |
| CLINT   | `0x1000_0060` | 64 B    |
| SRAM    | `0x2000_0000` | 512 KB  |
| SDRAM   | `0x8000_0000` | 8 MB    |

Reset PC = `0x0000_0000`. Default `mtvec.base` = `0x0000_0100`.

## M4K budget discipline

Cyclone II EP2C35 has 105 M4K blocks (each 4608 bits, ≈ 59 KB total).
Every new logical RAM records its M4K footprint in a comment above the
`blockRam` call site. `reports/Riski5.fit.rpt`'s "Total block memory
bits" gets watched across commits; sudden jumps are investigated.

Reserved long-term: ~58 M4K for future L1 I$/D$ + L2 + headroom.
Phase 1 should stay ≤ 10 M4K.

## Task discipline

The phase-1 task list **T1–T44** in
`/home/mika/.claude/plans/look-at-repositories-alterade2-flake-starry-shell.md`
is stable. Ongoing state lives in [TODO.md](./TODO.md).

- Update TODO.md when **starting** and **finishing** each task;
  don't batch.
- "Done" entries get the commit SHA appended once merged.
- Sub-tasks discovered during work become lettered additions
  (T14a, T14b, …) in both TODO.md and the plan.

## Blog article (external — purefun-front)

There is a running write-up of the riski5 project at
`~/purefun-front/src/blog/posts/building-riski5-rv32i-clash-core.md`
(slug `building-riski5-rv32i-clash-core`). It lives on the
`blog_claude_building_verilator` branch of
`~/purefun-front`, alongside the verilambda article.

**Rule: keep the blog article current as work progresses.** After every
meaningful chunk of work lands in this repo — new phase reached, a
milestone hit, a design decision flipped — update the article's
"Current progress" and "What's next" sections. Don't batch updates;
the article should be readable as a live document at any point.

When editing:

- Edit the markdown in `~/purefun-front/src/blog/posts/…`.
- Re-run `cargo build` under `nix develop` in purefun-front to confirm
  the generated Yew code still compiles.
- Commit there as a separate commit on the
  `blog_claude_building_verilator` branch — don't push unless the
  user asks.

## Reference docs are pinned

PDFs under `docs/` are version-stamped (release date or tag in the
filename). `docs/riscv/README.md` records release tag + source URL.
`.gitignore` blocks any opportunistic PDF dumps; only files the plan
explicitly names get committed.

## Commits

Small, one task ≈ one commit. Messages describe what changed and
**why**, not a mechanical diff summary.

**Fixes land as `fixup!` / `squash!` commits.** When we find a bug
later that was introduced by commit `<abc>`, don't land the fix as a
standalone commit — use `git commit --fixup=<abc>` (or `--squash` when
a new message is warranted). At a convenient merge boundary
(typically end of phase or before pushing), run
`git rebase -i --autosquash <base>` to fold them into their targets
so the final history is one-task-per-commit with clean messages.
Normal feature / scope commits stay as-is.
