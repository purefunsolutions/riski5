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

- **T5. Encoder** [started 2026-04-19]
  - `src/Riski5/Encode.hs` — total `Instr -> BitVector 32`.

## Next up

- **T6. Decoder + roundtrip tests.** `Decode.hs` + `DecodeSpec.hs`.
- **T7. Asm eDSL.** `Asm.hs` + `AsmSpec.hs`.

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

## Ongoing

- **Blog article** — `~/purefun-front/src/blog/posts/building-riski5-rv32i-clash-core.md`
  on branch `blog_claude_building_verilator`. Update the
  "Current progress" + "What's next" sections as each phase advances.

## Blocked / parked

- (nothing)

## Open questions

- (collected here between sessions so they're not lost)
