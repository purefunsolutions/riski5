<!--
SPDX-FileCopyrightText: 2026 Mika Tammi
SPDX-License-Identifier: MIT OR BSD-3-Clause
-->

# riski5

A **5-stage F/D/X/M/W pipelined** **RV32IMA + Zicsr + Zifencei + Zbb**
soft core in **Clash**, with EX→X / MEM→X forwarding and a multi-PLL
three-domain SoC targeting the **Altera DE2**
(Cyclone II EP2C35F672C6). Aimed at running Linux on a 2007-vintage
development board — and currently does, on real silicon. The ISA is
defined at the Haskell type level (`src/Riski5/ISA.hs`) and is the
single source of truth for both the hardware decoder and the firmware
assembler eDSL (`Riski5.Asm`).

Project conventions live in [CLAUDE.md](./CLAUDE.md); the current
state lives in [TODO.md](./TODO.md); per-commit silicon performance is
tracked in [`docs/perf/coremark-history.md`](./docs/perf/coremark-history.md).

## Status — what works on silicon today

- **RV32IMA + Zicsr + Zifencei + Zbb** decoder + datapath, all
  differentially tested against the pure-Haskell `Riski5.Reference`
  oracle. M-extension is hybrid: combinational MUL (Quartus infers
  ~6 of the 35 embedded 18×18 DSP blocks via Haskell native `*`) +
  iterative DIV/REM. A-extension is a 4-state Mealy FSM in
  `Riski5.Core.FU.Amo` covering LR/SC + every AMO op.
- **Multi-PLL three-domain SoC** — `DomBus` (40 MHz), `DomCore`
  (40 MHz, splittable), `DomSdram` (50 MHz). Two CDC bridges
  (`Riski5.CoreCdcBridge`, `Riski5.SdramCdcBridge`) carry
  Avalon-MM-shaped traffic across domain boundaries via toggle
  handshakes. SDRAM is the Altera IP controller behind our own Clash
  controller fallback (`Riski5.SdrController`).
- **Linux 6.18 RV32 nommu boots on real DE2 silicon today** —
  earlycon prints kernel boot through `Mountpoint-cache hash table
  entries`. Latest boot logs at `docs/perf/linux-multipll-mulcomb-silicon-2026-05-05.log`.
  Two recent fixes unlocked this: cbrFlush race fix in
  `Riski5.CoreCdcBridge` (commit `18d8b64`) and the hybrid
  MUL-via-DSP workaround for the silicon-broken iterative MUL FSM
  (commit `ee47123`).
- **JTAG-Avalon-Master upload path** (`Riski5.JtagAvalonMaster` +
  `scripts/boot-linux-master.tcl`) lets us push a kernel + DTB into
  SDRAM in seconds without reflashing the bitstream.
- **CoreMark on silicon**: ~46 iterations/sec, 1.15 CMs/MHz on the
  multi-PLL build.
- **Verilator hwsim** via `verilambda` runs every firmware variant
  + the kernel boot, and reproduces silicon hangs in RTL.

## Sibling repos

Both consumed as path-based flake inputs during active dev:

- [`alterade2-flake`](https://github.com/mikatammi/alterade2-flake) —
  Quartus II 13.0sp1 packaging, USB-Blaster udev module, board
  flashing. Supplies the `quartus-ii-13` package.
- [`verilambda`](https://github.com/purefunsolutions/verilambda) —
  our Haskell wrapper around Verilator; the project's simulation
  backend.

## Memory map

Single source: `src/Riski5/MemMap.hs`. Decoded on the upper 4 bits in
`Riski5.Bus`.

| Region    | Base          | Size    |
|---|---|---:|
| BRAM      | `0x0000_0000` | 4 KB    |
| JTAG UART | `0x1000_0000` | 16 B    |
| GPIO      | `0x1000_0020` | 32 B    |
| LCD       | `0x1000_0040` | 32 B    |
| CLINT     | `0x1000_0060` | 64 B    |
| SRAM      | `0x2000_0000` | 512 KB  |
| SDRAM     | `0x8000_0000` | 8 MB    |

Reset PC = `0x0000_0000`. Default `mtvec.base` = `0x0000_0100`.

## Build and test

```sh
nix develop           # devshell: Clash, Quartus, Verilator, Cabal, HLS, REUSE
cabal build all       # build library + every firmware
cabal test            # Hedgehog property suite + reference-diff + CDC + integration
nix flake check       # REUSE lint + formatters
```

The Hedgehog suite covers the decoder, ALU, regfile, every memory,
both CDC bridges, the SDRAM controller, the JTAG-UART adapter, the
PLIC + CLINT, the AMO/MulDiv functional units, and the whole-SoC
chain. Reference-diff specs (`test/CoreSimSpec.hs`,
`test/SpikeDiffSpec.hs`) compare the silicon datapath against
`Riski5.Reference` (a pure-Haskell RV32I interpreter) and against
Spike via `Riski5.SpikeDriver`.

## Build for hardware

The default flash target is the BRAM-only memtest:

```sh
nix run .#flash-riski5             # USB Blaster — flashes the .sof
nix run .#console                  # nios2-terminal over the same cable
```

Each firmware variant has matching `riski5-core-<name>` package +
`flash-riski5-<name>` app — for instance:

```sh
nix run .#flash-riski5-coremark        # CoreMark benchmark
nix run .#flash-riski5-aexttest        # A-extension regression
nix run .#flash-riski5-amostress       # AMO stress
nix run .#flash-riski5-lrscstress      # LR/SC stress
nix run .#flash-riski5-stackstress     # stack save/restore
nix run .#flash-riski5-trapstress      # trap-during-stress
nix run .#flash-riski5-timerirqtest    # CLINT timer IRQ
nix run .#flash-riski5-sramexec        # exec-from-SRAM
nix run .#flash-riski5-sdramexec       # exec-from-SDRAM
nix run .#flash-riski5-sdramstress     # SDRAM read/write stress
nix run .#flash-riski5-sdramdatastress # SDRAM data path stress
```

For Linux:

```sh
# Best current silicon path: hybrid MUL-via-DSP + cbrFlush fix.
nix run .#flash-riski5-linux-master-combmd
nix run .#boot-linux-master-combmd

# Single-PLL fallbacks still available:
nix run .#flash-riski5-linux           # JTAG-UART firmware loader path
nix run .#boot-linux                   # one-shot via JTAG-UART
nix run .#flash-riski5-linux-master    # JTAG-Avalon-Master path
nix run .#boot-linux-master            # one-shot via JTAG-Avalon-Master
```

The `boot-linux-master*` apps drive `scripts/boot-linux-master.tcl`,
which talks to `Riski5.JtagAvalonMaster` to upload kernel + DTB
directly into SDRAM (faster + more reliable than the older JTAG-UART
firmware loader).

## Design discipline

These are non-negotiable; the full reasoning is in CLAUDE.md.

- **5-stage pipeline (F / D / X / M / W) with forwarding.** One
  instruction retires per clock under steady state. Stages:
    - **F** — `pcFetch` drives imem (synchronous BRAM read,
      1-cycle latency).
    - **D** — IF/ID → `decode` + regfile read → ID/EX.
    - **X** — ID/EX → EX→X and MEM→X forwarding muxes →
      `handleInstr` (ALU, branch compare, CSR, load-address,
      trap detect) → EX/MEM.
    - **M** — passthrough today; async-read dmem already returned
      the load value during X's cycle → MEM/WB.
    - **W** — MEM/WB writes `rd` back to the regfile.

  Taken-branch penalty is 2 cycles (squash D + ID/EX on redirect
  from X). Three stall sources feed a single `stallInternal`:
  external bus back-pressure (`stallS`), `mdBusyS` (DIV/REM still
  iterative; MUL is now combinational/DSP via the hybrid
  `mulDivFUMulComb`), and `amoBusyS`. Full per-stage description
  is in the `src/Riski5/Core.hs` header.
- **Regfile.** Async-read register array
  (`Riski5.Regfile.regfileAsync`, ~1024 FFs + 32:1 read mux on
  LEs); `Core.hs` aliases `regfile = regfileAsync`. An M4K-friendly
  `regfileSync` (1-cycle read latency) is also implemented and
  swapping to it is a follow-up — the ID stage could absorb the
  synchronous read, but it needs an EX-side bypass for the
  write-during-D-read case the async variant gets for free.
- **Type-level ISA in `Riski5.ISA`** is consumed by both the
  hardware decoder and `Riski5.Asm`. Changing the ISA edits one
  file.
- **No external RISC-V assembler in phase 1.** Every test firmware
  is built from Haskell.
- **Dual-rail testing.** Every instruction and every memory region
  must pass in **verilambda simulation *and* on the real DE2** via
  the on-board test agent + JTAG-UART diff. `test/InstrCatalog.hs`
  is the shared source.
- **Cyclone II targeting.** RAMs go to M4K; ALU adders are plain
  `+` so Quartus infers carry chains; barrel shifter is a 5-stage
  log shift; the multiplier inference relies on Haskell native `*`
  at the right widths. Synthesis effort is Area/Balanced.

## Formal verification

Three layers, see [`docs/verification.md`](./docs/verification.md):

1. **Reference-diff** (live). `Riski5.Reference` is a pure-Haskell
   RV32I interpreter; Hedgehog properties compare every instruction
   against it.
2. **RVFI + YosysHQ/riscv-formal** (lands at end of phase 1B).
   `Riski5.Rvfi` taps + `Riski5.FormalTop` are scaffolded; the
   `pkgs/riski5-formal` Nix package wires SymbiYosys against the
   Verilog Clash emits.
3. **Liquid Haskell** on pure modules (phase 2 opt-in).

## Where the docs are

- [CLAUDE.md](./CLAUDE.md) — durable conventions, design rules,
  testing rule, M4K budget, commit policy.
- [TODO.md](./TODO.md) — live task state.
- [docs/core-family.md](./docs/core-family.md) — phase-2+
  type-parameterised core family plan.
- [docs/future-soc-configurability.md](./docs/future-soc-configurability.md)
  — SoC-level IP-provider / cache-configuration plan.
- [docs/verification.md](./docs/verification.md) — formal
  verification roadmap.
- [docs/multi-pll-sdram-design.md](./docs/multi-pll-sdram-design.md)
  — three-domain split rationale.
- [docs/linux-boot.md](./docs/linux-boot.md) — kernel/DTB upload +
  boot procedure.
- [docs/references.md](./docs/references.md) — upstream references
  (RISC-V spec PDFs under `docs/riscv/`, mit-plv/riscv-semantics,
  etc.).
- [docs/perf/coremark-history.md](./docs/perf/coremark-history.md) —
  per-commit silicon CoreMark + Linux-boot log; reading top-to-bottom
  is the project's performance + bringup story.
