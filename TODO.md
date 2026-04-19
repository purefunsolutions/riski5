<!--
SPDX-FileCopyrightText: 2026 Mika Tammi
SPDX-License-Identifier: MIT OR BSD-3-Clause
-->

# TODO

Authoritative, always-current view of riski5 phase-1 state. Tasks
T1–T44 are defined in the plan at
`/home/mika/.claude/plans/look-at-repositories-alterade2-flake-starry-shell.md`;
this file tracks their progress. See [CLAUDE.md](./CLAUDE.md) for the
rules around maintaining it.

## In flight

- (nothing — T8 just landed; T9 is next)

## Next up — phase 1B (core + SoC on BRAM, hello-world on hardware)

- **T9. Regfile on M4K.** `src/Riski5/Regfile.hs`.
- **T10. Pipelineless datapath (no CSR).** `src/Riski5/Core.hs`.
- **T11. Whole-core sim via verilambda.** `test/CoreSpec.hs`.
- **T12. CSR file + M-mode traps.** `src/Riski5/CSR.hs`.

Remaining phase-1 work (T8–T44) is detailed in the plan; summary:

- **Phase 1B** (T8–T25): ALU, regfile, core, CSRs, SoC, DE2 top,
  hello-world on hardware, InstrCatalog, on-board test agent, MemSpec.
- **Phase 1C** (T26–T31): SRAM controller + tests + firmware demo.
- **Phase 1D** (T32–T39): SDRAM via Altera IP + tests + firmware demo.
- **Phase 1D fallback** (T32a–T36a): own Clash SDRAM controller, only
  if Altera IP doesn't bring up cleanly.
- **Phase 1E** (T40–T44): max-out-clock-speed exploration.

## Done

- **T1. Repo scaffold** (2026-04-19)
  - `flake.nix`, `riski5.cabal`, `nix/{default,devshell,checks,treefmt}.nix`,
    `pkgs/default.nix`, `fourmolu.yaml`, `.gitignore`,
    `LICENSE-BSD`/`LICENSE-MIT`, placeholder `src/Riski5{,/ISA}.hs`,
    `README.md`.
  - `nix flake check` green, `cabal build` succeeds.
- **T2. CLAUDE.md + TODO.md** (2026-04-19)
  - `CLAUDE.md` captures design style, testing rule, Cyclone II
    targeting rules, Altera IP / verilambda policies, memory map,
    M4K budget discipline, task + blog disciplines, reference-doc
    rules.
  - `TODO.md` (this file) bootstraps T1–T44 tracking.
- **T3. Reference docs** (2026-04-19)
  - `docs/riscv/riscv-spec-2026-04-16.pdf` pinned from upstream tag
    `riscv-isa-release-ea0f0fc-2026-04-16`.
  - `docs/riscv/README.md` records the pin + how to re-pin.
  - `docs/references.md` links upstream RISC-V-in-Haskell / Clash /
    verification / DE2 references with one-line rationales.
- **T4. Type-level ISA** (2026-04-19)
  - `src/Riski5/ISA.hs` — `Reg` (x0..x31 + ABI names), `Csr` (12-bit
    address + M-mode constants), `Opcode` with 7-bit bit patterns,
    and `Instr` ADT covering all 47 RV32I + Zifencei + 6 Zicsr + MRET
    instructions. Width-indexed immediates (`Signed 12/13/21`,
    `BitVector 20/5`).
- **T5. Encoder** (2026-04-19)
  - `src/Riski5/Encode.hs` — total `Instr -> BitVector 32` covering
    every constructor via rType/iType/shiftI/sType/bType/uType/jType
    helpers plus hard-coded ECALL/EBREAK/MRET encodings.
- **T6. Decoder + roundtrip tests** (2026-04-19)
  - `src/Riski5/Decode.hs` — total `BitVector 32 -> Maybe Instr` for
    every RV32I + Zifencei + Zicsr + M-mode pattern; `Nothing` on
    illegal (including RVC opcodes).
  - `test/{Spec,DecodeSpec}.hs` — tasty + Hedgehog, 2 properties
    passing 100 cases each.
- **T7. Asm eDSL** (2026-04-19)
  - `src/Riski5/Asm.hs` — state-monad assembler with `label` /
    `labelUnplaced` / `placeAt`, real-instruction wrappers
    (addi/add/lw/sw/lui/auipc/jal/jalr/ecall/ebreak/mret/csrrw/csrrs),
    pseudo-ops (nop/mv/li/ret/j/jr/beqz/bnez/beq/bne/blt/bge/bltu/bgeu).
    Two-pass resolver catches undefined labels + out-of-range offsets.
  - `test/AsmSpec.hs` — 12 HUnit cases covering every pseudo-op and
    label-dependent combinator. `cabal test` runs 14 tests green.
- **Tv1. Formal verification policy** (2026-04-19)
  - `CLAUDE.md` adds the three-layer FV section: Reference-executor
    differential testing (from Day 1), RVFI + riscv-formal (end of
    phase 1B), Liquid Haskell (phase 2 opt-in).
  - `docs/verification.md` details each layer, what it buys us, and
    what it doesn't.
- **Tv2. Reference executor** (2026-04-19)
  - `src/Riski5/Reference.hs` — pure-Haskell RV32I + Zicsr + M-mode
    interpreter. `step` fetches from memory, decodes, executes;
    `run` bounds execution by step count. Traps thread through
    `TrapCause` values.
  - `Riski5.Asm` gained wrappers for `sub`/`slti`/`sltiu`/`xori`/
    `ori`/`andi`/`slli`/`srli`/`srai` so reference tests can write
    programs readably.
  - `test/ReferenceSpec.hs` pins the reference's behaviour with 10
    HUnit cases covering ADDI/LUI/ADD/SUB/BEQ (taken and not)/SW+LW
    round-trip/SRAI/JAL/ECALL-trap/SLTI. All 24 tests pass
    (14 original + 10 reference).
- **T8. ALU + tests** (2026-04-19)
  - `src/Riski5/ALU.hs` — combinational `alu :: AluOp -> BitVector
    32 -> BitVector 32 -> BitVector 32` covering all ten RV32I
    arithmetic/logical/shift/compare ops, plus a separate
    `branchTaken :: BranchOp -> ...` for the six branch comparators.
  - `test/AluSpec.hs` — 16 Hedgehog properties (10 ALU + 6 branch),
    each passing 500–1000 random cases biased toward boundary
    values (0, ±1, signed/unsigned min/max, alternating patterns).
    Total now: 40 tests green in ≈ 100 ms.

## Ongoing

- **Blog article** — `~/purefun-front/src/blog/posts/building-riski5-rv32i-clash-core.md`
  on branch `blog_claude_building_verilator`. Update the
  "Current progress" + "What's next" sections as each phase advances.

## Blocked / parked

- (nothing)

## Open questions

- (collected here between sessions so they're not lost)
