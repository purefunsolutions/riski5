<!--
SPDX-FileCopyrightText: 2026 Mika Tammi
SPDX-License-Identifier: MIT OR BSD-3-Clause
-->

# riski5

A pipelineless single-cycle **RV32I** soft core (plus Zicsr, M-mode,
Zifencei) in **Clash**, with a minimal SoC targeted at the **Altera DE2**
(Cyclone II EP2C35F672C6).

Long-term goal: grow this into a Linux-capable system. Phase 1 is
deliberately small: a single-cycle core, BRAM scratch + 512 KB SRAM +
8 MB SDRAM, JTAG UART for `printf` debug, and a 16×2 HD44780 LCD that
says `Hello from Riski5`. The plan lives in
`/home/mika/.claude/plans/look-at-repositories-alterade2-flake-starry-shell.md`;
the current state lives in [TODO.md](./TODO.md); project conventions
live in [CLAUDE.md](./CLAUDE.md).

## Sibling projects

- [`alterade2-flake`](https://github.com/mikatammi/alterade2-flake) —
  Quartus II 13.0sp1 packaging, USB-Blaster udev module, board flashing
  script.
- [`verilambda`](https://github.com/purefunsolutions/verilambda) —
  Haskell interface to Verilator, used as riski5's simulation backend.

Both are consumed as flake inputs (path-based during development).

## Build

```sh
nix develop           # devshell: Clash, Quartus, Verilator, Cabal, HLS, REUSE
cabal build all       # build library
cabal test            # Hedgehog property suite (starts with the decoder)
nix flake check       # REUSE lint + formatters
```

Phase 1 milestones (see TODO.md for current state) reach hardware with:

```sh
nix build .#riski5-core   # Clash → Verilog → Quartus → .sof
nix run .#flash-riski5    # USB Blaster
nix run .#console         # nios2-terminal over the same cable
```
