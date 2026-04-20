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

### Layer 1.5 — Cross-check against Spike (official RISC-V ISS)

**Status:** scaffolding landed 2026-04-20; SpikeDriver + first
triple-diff test to follow in the next working session.

Spike ([`riscv-software-src/riscv-isa-sim`](https://github.com/riscv-software-src/riscv-isa-sim))
is the official functional ISS maintained by the RISC-V software
community — the de-facto golden reference every production RV core
diffs against. Our Layer-1.5 path turns each program we run into
a three-way diff:

1. Interpret it under `Riski5.Reference` (our Haskell semantics).
2. Run it under Spike.
3. Run it under the Clash core (pure Clash sim or the verilambda
   Layer-1.75 harness).

All three architectural traces must agree; any two-against-one
disagreement points at the third as the bug location. This catches
the class of faults where our own Reference and our own Core share
a bug and silently agree with each other.

The scaffolding committed this session:

  - `pkgs.spike` + `pkgs.dtc` +
    `pkgsCross.riscv32-embedded.buildPackages.binutils` on the
    devshell. `dtc` is load-bearing because Spike's default boot
    ROM at @0x1000@ reads its entry pointer from a device-tree
    blob it dynamically generates, and refuses to start without
    `dtc` on PATH.
  - [`src/Riski5/Elf.hs`](../src/Riski5/Elf.hs) renders an
    assembly stub (one `.word` per retired instruction) + a
    linker script placing `.text.firmware` at `0x8000_0000`, then
    shells out to `riscv32-none-elf-as` + `-ld` to produce a
    standards-compliant ELF32 little-endian RV executable Spike
    consumes without complaint. An earlier attempt hand-rolled
    the ELF headers in Haskell; Spike's loader asserts on edge
    cases (`e_shstrndx < e_shnum`, memory at `0x0`) so we pivoted
    to real binutils.
  - [`firmware/phase1/Emit.hs`](../firmware/phase1/Emit.hs) now
    emits `hello.mif` (Quartus), `hello.bin` (raw LE bytes for
    our own sim), and `hello.elf` (for Spike) alongside each
    other.

**Why not `mit-plv/riscv-semantics`** (the previous Layer-1.5
candidate): `riscv-semantics` is a Haskell-only alternative golden
model that'd slot in as a library dependency. Spike wins on two
fronts: (a) it's what the RISC-V community actually uses as the
reference, (b) interfacing to it as an external binary keeps our
Haskell build dependencies stable. We retain the Reference.hs
hedgehog path; Spike joins as a third oracle, not a replacement.

**What this buys us.** An official cross-check against a widely-
shared ISS maintained by the people who write the spec. Catches
bugs shared between our Reference and our Core. **What it
doesn't buy us.** Spike is functional, not cycle-accurate — it
says nothing about timing closure, pipeline hazards, or
peripheral protocol bugs. That's what Layers 1.75 and 2 are for.

### Layer 1.75 — Verilator-backed whole-SoC simulation via verilambda

**Status:** live as of 2026-04-20 — first real test green, and it
already caught a bug nobody else would have seen until silicon
(see below).

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

Pieces (all live):

  - [`pkgs/riski5-sim/verilog/riski5_sim_top.v`](../pkgs/riski5-sim/verilog/riski5_sim_top.v) —
    hand-written Verilator top wrapping `riski5` + `riski5_jtag_uart`.
  - [`pkgs/riski5-sim/package.nix`](../pkgs/riski5-sim/package.nix) —
    Nix derivation producing `libVriski5_sim_top.a` +
    `libverilated.a`.
  - [`pkgs/riski5-sim/clash-manifest.json`](../pkgs/riski5-sim/clash-manifest.json) —
    hand-authored manifest describing the sim-top's ports. Field
    order is 32-bit → 16-bit → 8-bit so the emitted C struct has
    zero internal padding; the Haskell Storable mirror in
    [`test/SocHwSim.hs`](../test/SocHwSim.hs) matches it byte-for-byte.
  - [`test/SocHwSim.hs`](../test/SocHwSim.hs) — verilambda wiring
    (HKD port record + Storable mirror + FFI + `SimBackend`) plus
    the first real test, which runs the Hello firmware under the
    Altera IP and asserts the UART TX stream begins with
    `hello, world\n`.

Activate with `cabal test --flag=hwsim`; under Nix, `nix build
.#riski5-sim` produces `libVriski5_sim_top.a` and the test-suite
links against it via `--extra-lib-dirs=${riski5-sim}/lib`.

**What the first test already caught.** The Core.hs change that
plumbed `UART_READY` into `stallS` wasn't enough on its own: the
core also gated `dmemBe` to 0 on stall, which combined with the IP's
`av_waitrequest = chipselect & ~write_n & (be != 0)` created a
combinational loop (`stall=1 → be=0 → waitrequest=0 → stall=0 →
be=be_native → waitrequest=1 → stall=1 → …`). Verilator's UNOPTFLAT
detector flagged it; the sim then showed 0 UART bytes over 200k
cycles. Dropping the `dmemBe` stall gating (safe because Avalon-MM
slaves handle single-commit internally, SRAM writes don't stall,
and SRAM reads don't use `be`) broke the loop. The same test, run
against a spot-reverted copy of `Core.hs`, correctly reports zero
bytes collected — i.e. it is a real regression fence, not a
tautology.

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
| Spike (official RV ISS) triple-diff | Independent oracle (CPU semantics) | Medium (binutils + dtc on devshell) | Scaffolding landed 2026-04-20 |
| Verilator + verilambda SoC sim | Peripheral / bus protocol testing | Medium (shim setup) | Adding now (after 2026-04-20 UART bug) |
| RVFI + `riscv-formal` | Bounded formal proof on Verilog | Medium (harness setup) | Immediately after 1.75 |
| Liquid Haskell | Static refinement types | Medium-high | 2+ opt-in |

The phase-1 deal: **Layer 1 now, Layer 1.75 next, Layer 2 right after,
Layer 1.5 and Layer 3 are real options not commitments.**
