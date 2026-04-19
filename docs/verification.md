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
| Reference executor + Hedgehog | Differential testing | Low | 1A+ |
| `riscv-semantics` cross-check | Independent oracle | Medium (new dep) | Deferred |
| RVFI + `riscv-formal` | Bounded formal proof on Verilog | Medium (harness setup) | end of 1B |
| Liquid Haskell | Static refinement types | Medium-high | 2+ opt-in |

The phase-1 deal: **Layer 1 now, Layer 2 before phase-1 declaration**.
Layer 1.5 and Layer 3 are real options, not commitments.
