<!--
SPDX-FileCopyrightText: 2026 Mika Tammi
SPDX-License-Identifier: MIT OR BSD-3-Clause
-->

# Verification strategy

How riski5 is checked for correctness — written down so a reviewer can
tell, at a glance, which parts are "proven", which are "tested", and
which are "observed on hardware and trusted". All three categories are
valuable; none of them pretends to be the others.

## Three layers

### Layer 1 — Reference-executor differential testing

**Status:** live from Day 1, runs on every `cabal test`.

A small pure-Haskell RV32I interpreter lives in
[`src/Riski5/Reference.hs`](../src/Riski5/Reference.hs). It is *our*
reference semantics: given an `Instr` and a machine state (register
file, memory, PC, CSRs), it returns the state after executing that
instruction. No hardware, no simulation — just a function.

Hedgehog properties in `test/ReferenceSpec.hs` compare:

- **Encoder/decoder roundtrip against the Reference's own
  encode/decode** — already covered by `test/DecodeSpec.hs`.
- **Reference executor totality** — every legal `Instr` steps to a
  valid state.
- **Instruction semantics against the spec** — a curated list of
  exercise programs (extended over time into `InstrCatalog`) run in
  the Reference and against hand-written expected final states.

Once `Core.hs` exists (phase 1B), the *same* `InstrCatalog` will run
against the Clash-in-Verilator simulation via verilambda and its
final state is diffed against the Reference. Same catalogue on both
sides — no duplication.

**What this buys us.** Exhaustive differential coverage across every
RV32I + Zicsr + M-mode instruction, reproducible in pure Haskell,
runnable in under a second. **What it doesn't buy us.** It's testing,
not proof; a bug present in both Reference and core can pass. And the
Reference is *our* implementation — cross-checking it against an
upstream executable spec (see Layer 1.5) closes that gap.

### Layer 1.5 — Cross-check against `mit-plv/riscv-semantics` (future)

Future work, not adopted yet. The
[`mit-plv/riscv-semantics`](https://github.com/mit-plv/riscv-semantics)
package is an executable Haskell semantics of RV32I/RV64I from MIT
PLV. When we're ready, a test module will run the same `InstrCatalog`
through both `Riski5.Reference` and `riscv-semantics` and diff final
states. Any divergence is a bug in *our* Reference (they're the
upstream spec, we're not).

Deferred because (a) phase 1A already has its own Hedgehog properties
for the decoder/encoder roundtrip, (b) introducing a new Haskell
dependency with GHC-version constraints is complexity we can postpone.
Reach for it when a bug makes us want an independent oracle.

### Layer 1.75 — Verilator-backed whole-SoC simulation via verilambda

**Status:** skeleton landed as of 2026-04-20; first real test to
follow in the next working session.

Layer 1 checks the CPU *core* against a Haskell semantics. It says
nothing about the rest of the SoC — the bus decoder, the
peripherals, the vendor IP we black-box for synthesis. That gap is
load-bearing: on 2026-04-20 we shipped a correctly-synthesised SoC
to real silicon, saw `hello, world\n` come out as a stream of NUL
bytes, and traced the bug to the Altera JTAG UART IP's 1-cycle
registered write-data semantics. The master (our pipelined core)
wasn't holding `av_writedata` while `av_waitrequest` was asserted.
Our pure-Clash `jtagUartSim` model had no such requirement — it
was a behaviourally simplified stand-in that didn't match what the
real IP does. Layer 1 couldn't catch it because Layer 1 never sees
the real IP's Verilog.

Layer 1.75 closes that gap. We compile the Clash-emitted Verilog
*together with the ip-generate-emitted Altera JTAG UART Verilog*
(the IP's sim variant — no encrypted primitives — thanks to the
`//synthesis translate_on/off` directives inside its file) under
Verilator 5.040+, via
[verilambda](https://github.com/purefunsolutions/verilambda) (our
own Verilator wrapper), and drive the whole-SoC sim from a Haskell
test-suite. TX bytes land through a small `UART_TX_VALID` /
`UART_TX_BYTE` tap inside `riski5_sim_top.v`, so the test harness
sees each byte the IP's FIFO actually latches.

Pieces:

  - [`pkgs/riski5-sim/verilog/riski5_sim_top.v`](../pkgs/riski5-sim/verilog/riski5_sim_top.v) —
    hand-written Verilator top wrapping `riski5` + `riski5_jtag_uart`.
  - [`pkgs/riski5-sim/package.nix`](../pkgs/riski5-sim/package.nix) —
    Nix derivation producing `libVriski5_sim_top.a`.
  - [`pkgs/riski5-sim/clash-manifest.json`](../pkgs/riski5-sim/clash-manifest.json) —
    hand-authored manifest describing the sim-top's ports.
  - [`test/SocHwSim.hs`](../test/SocHwSim.hs) — currently a skeleton
    test; the actual verilambda wiring + HKD port record + FFI
    declarations + regression test for the 2026-04-20 UART bug land
    in the next session.

**What this buys us.** Catches peripheral-protocol bugs before
hardware. The moment the first test compiles, it becomes the
regression fence against future similar errors (e.g. the SDRAM
controller IP's Avalon-MM semantics in phase 1D). **What it doesn't
buy us.** Any vendor IP whose *simulation variant* is encrypted or
doesn't exist can't be verified this way — we'd fall back to Layer
1 or a protocol-faithful Haskell model for that specific
peripheral.

### Layer 2 — RVFI + YosysHQ/riscv-formal on the Clash-emitted Verilog

**Status:** scaffolding from phase 1B; activated at the end of phase 1B
once `Core.hs` is running.

[`YosysHQ/riscv-formal`](https://github.com/YosysHQ/riscv-formal) is
the industry-standard formal-verification harness for RISC-V cores.
It defines the **RVFI** (RISC-V Formal Interface): a small set of
output ports that expose, per retired instruction, the instruction
bits, the `(rs1, rs2, rd, wdata)` it read/wrote, the memory access
(if any), the PC advance, the mode, and the trap taken. SymbiYosys
then model-checks the Verilog for bounded cycles against per-insn
contracts from the `checks/` directory in `riscv-formal`.

For us: the core carries an RVFI output bus from the day `Core.hs`
is born. It's a tiny amount of combinational wiring — a few dozen
LEs — and it lets us run `riscv-formal` proofs on the generated
Verilog without touching the design afterwards.

**What this buys us.** Real formal verification (bounded model
checking, practically exhaustive for a single-cycle core) against an
independent ISA specification. **What it doesn't buy us.** It
verifies the *Verilog*. If Clash has a compiler bug between our
Haskell and the emitted Verilog, `riscv-formal` won't catch it in our
favour (it might catch it as a spec-divergence from the Verilog
side). Layer 1 is still needed to pin the Haskell source.

### Layer 3 — Liquid Haskell on pure modules (phase 2, opt-in)

**Status:** not adopted in phase 1.

Liquid Haskell would let us annotate things like:

- "`bOffset`'s `Signed 13` result always has bit 0 == 0."
- "`encode` is total over `Instr`."
- "`Fence (fm, pred, succ)` only admits `fm == 0` (we don't emit
  FENCE.TSO)."

These are all already true by construction (types + exhaustive pattern
matching). The marginal value of turning them into explicit refinement
types is lower than the cost of:

- Pinning Liquid Haskell to a specific GHC + `liquid-base` version.
- Keeping annotations fresh as the ISA evolves.
- Teaching every future session to speak LH.

Adopted only if a subtle ISA invariant causes a real bug we'd have
caught by refinement types. Until then, GHC's type system carries the
load.

## Summary

| Layer | Strength | Cost | Phase |
|---|---|---|---|
| Reference executor + Hedgehog | Differential testing (CPU semantics) | Low | 1A+ |
| `riscv-semantics` cross-check | Independent oracle (CPU semantics) | Medium (new dep) | Deferred |
| Verilator + verilambda SoC sim | Peripheral / bus protocol testing | Medium (shim setup) | Adding now (after 2026-04-20 UART bug) |
| RVFI + `riscv-formal` | Bounded formal proof on Verilog | Medium (harness setup) | Immediately after 1.75 |
| Liquid Haskell | Static refinement types | Medium-high | 2+ opt-in |

The phase-1 deal: **Layer 1 now, Layer 1.75 next, Layer 2 right after,
Layer 1.5 and Layer 3 are real options not commitments.**
