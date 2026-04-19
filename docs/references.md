<!--
SPDX-FileCopyrightText: 2026 Mika Tammi
SPDX-License-Identifier: MIT OR BSD-3-Clause
-->

# External references

Upstream projects and papers consulted during riski5's design. One line
of rationale per link so future sessions know why we looked there. No
URL in this file is invented — all have been opened and verified.

## RISC-V cores in Clash

- **[standardsemiconductor/lion](https://github.com/standardsemiconductor/lion)**
  — formally-verified Clash RV32I core, last release 2024-08-03.
  Primary style reference; most actively-maintained of the bunch.
- **[adamwalker/clash-riscv](https://github.com/adamwalker/clash-riscv)**
  — 5-stage pipelined RV32I in Clash. Useful for structural ideas
  (decoder, forwarding) even though riski5 starts pipelineless.

## RISC-V semantics in Haskell (type-level and executable)

- **[mit-plv/riscv-semantics](https://github.com/mit-plv/riscv-semantics)**
  — MIT PLV's executable Haskell ISA semantics with a Clash backend
  emitting a single-cycle model. Closest thing to "type-level ISA +
  Clash + verification" all in one place. Paper:
  [Flexible Instruction-Set Semantics via Type Classes (arXiv 2104.00762)](https://arxiv.org/pdf/2104.00762).
- **[GaloisInc/grift](https://github.com/GaloisInc/grift)** — Galois's
  type-level RISC-V semantics. Unmaintained, but a reference for how
  to encode the ISA in types. Paper:
  [SpISA '19 — GRIFT](https://www.cl.cam.ac.uk/~jrh13/spisa19/paper_10.pdf).
- **[rsnikhil/Forvis_RISCV-ISA-Spec](https://github.com/rsnikhil/Forvis_RISCV-ISA-Spec)**
  — plain Haskell reference simulator by Rishiyur Nikhil. Older
  (last reading-guide revision July 2018); secondary reference only.

## Verification

- **[YosysHQ/riscv-formal](https://github.com/YosysHQ/riscv-formal)**
  — RVFI + SymbiYosys-based formal checker. Runs on the Verilog
  Clash emits, so we can use it once the core stabilizes.

## Serial / debug on the Altera DE2

- **[Tom Verbeure — Intel JTAG UART without Nios II](https://tomverbeure.github.io/2021/05/02/Intel-JTAG-UART.html)**
  — confirms Altera's JTAG UART IP can be attached to a non-Nios II
  core over Avalon and driven from `nios2-terminal`. The approach
  riski5 uses in phase 1B.

## Sibling flakes

- **[mikatammi/alterade2-flake](https://github.com/mikatammi/alterade2-flake)**
  — Quartus II 13.0sp1 packaging under Nix, USB Blaster udev module,
  `de2-blinky` example and flashing script. Consumed as a flake input.
- **[purefunsolutions/verilambda](https://github.com/purefunsolutions/verilambda)**
  — our Haskell interface to Verilator. Drives every riski5 testbench.
  Consumed as a flake input.
