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

- (nothing — T17 just landed; T18 next)

## Next up — phase 1B (core + SoC on BRAM, hello-world on hardware)

- **T18. Hello-from-Riski5 firmware.** `firmware/phase1/Hello.hs`
  via `Riski5.Asm`, writes `hello, world\n` to UART and
  `Hello from Riski5` to the LCD; `Emit.hs` dumps the assembled
  program as a Quartus `.mif`.
- **T11-verilambda.** Wrap T11's pure-Clash sim in a verilambda
  driver so the same diff runs through Verilator. Deferred until the
  SoC-with-BRAM interface stabilizes (T14), since the top-entity
  shape is more naturally a SoC than a bare core.

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
- **T9. Regfile on M4K** (2026-04-19, superseded by the async-read
  rewrite committed immediately after)
  - Original M4K-backed synchronous-read implementation landed, then
    a follow-up commit switched to a register-array **async-read**
    regfile (~1024 FFs + 32:1 mux on LEs). The async version is what
    Core.hs consumes; the M4K option is deferred to the pipeline
    phase (rationale in `Riski5.Regfile` header + CLAUDE.md).
  - `test/RegfileSpec.hs` pins the async-read semantics (reset
    cycle, same-cycle reads after writes commit on the clock edge,
    x0 hard-wired zero). Total: 44 tests green.
- **T10. Pipelineless datapath (no CSR)** (2026-04-19)
  - `src/Riski5/Core.hs` — combinational dispatch table
    (`handleInstr`) covering every RV32I + Zifencei + Zicsr + M-mode
    mnemonic. CSRs and traps stubbed as NOP-advance until T12; load /
    store / branch / JAL / JALR / LUI / AUIPC / R-type / I-type ALU
    all wired correctly. Byte-enable + store-data shifting + load
    sign-extension handled in-module (shared with future SoC bus).
  - `test/CoreSpec.hs` — pure-Clash sanity check: PC advances by 4
    per NOP cycle; ADDI sequence doesn't stall. Full verilambda-
    driven diff against Reference lands in T11. Total: 46 tests.
- **T11. Whole-core sim (pure Clash) + Reference diff** (2026-04-19)
  - `core` gained an observability output: the regfile write-back
    signal (`Signal dom (Maybe (BitVector 5, BitVector 32))`).
    Synthesizable targets will ignore it; simulation drivers use it
    to reconstruct architectural register state without poking
    inside the regfile.
  - `test/CoreSimSpec.hs` — nine differential tests running small
    Asm programs (ADDI / LUI+ADDI / ADD+SUB / XOR+OR+AND+SLTIU /
    SLL+SRL+SRA / BEQ-taken / BNE-not-taken / SLTI / backward-
    branch 3-iteration loop) through both the Clash core and
    `Riski5.Reference`, asserting identical final integer register
    files. All pass; no divergences found.
  - Verilambda/Verilator wrapping intentionally deferred until the
    SoC-with-BRAM interface lands — the top-entity shape is more
    natural as a SoC than as a bare core. Tracked as
    T11-verilambda.
  - Total: 55 tests green.
- **T12. CSR file + M-mode traps** (2026-04-19)
  - `src/Riski5/CSR.hs` — M-mode CSR record (mstatus/mtvec/mepc/
    mcause/mtval/mscratch), pure read/write functions, `applyTrap`
    helper, and the numeric priv-spec cause constants. Other CSR
    addresses read as zero and drop writes (to be tightened in a
    later phase once we trap on unknown CSRs).
  - `src/Riski5/Core.hs` rewrite: handleInstr now takes/returns a
    Csrs record; CSRRW/S/C/WI/SI/CI are real reads+writes;
    ECALL/EBREAK/illegal-instr/misaligned-load/misaligned-store
    latch a trap (mepc ← pc, mcause ← cause, mtval ← context) and
    jump to mtvec.base; MRET sets pc ← mepc. Out of flight-check
    MEPC bumping is firmware's responsibility, matching the priv
    spec.
  - `test/TrapSpec.hs` — 8 HUnit cases covering every trap path
    plus CSRRS/CSRRC set/clear semantics. All green; no bugs
    found. Total: 63 tests green.
- **T13. Bus + BRAM + JTAG UART skeleton** (2026-04-19)
  - `src/Riski5/MemMap.hs` — the 4-bit-MSB address decoder plus
    named region bases and reset defaults. Single source of truth
    for every address constant in the code base.
  - `src/Riski5/Bram.hs` — word-addressable async-read RAM with
    byte-enable writes. Backed by a register-array (like the
    regfile) for the same pipelineless reason; sync-BRAM swap is
    deferred to the pipeline phase.
  - `src/Riski5/JtagUart.hs` — a minimal functional model for
    simulation (TX observable, RX stubbed, CTL.TxReady always
    asserted). The Altera IP black-box annotation gets added with
    the Quartus flow in T17.
  - `test/BramSpec.hs` — 3 direct HUnit tests for the BRAM wrapper
    (word write+read, byte-enable, two sequential writes).
  - `test/BramCoreSpec.hs` — 4 integration tests wiring Core + BRAM
    + BRAM (imem and dmem) and diffing against Reference for
    SW/LW / multi-word / SB+LBU / SH+LH negative. All green. First
    test that exercises Core's byte-enable + store-data-lane
    plumbing end-to-end.
  - Total: 70 tests green.
- **T14. LCD controller** (2026-04-19)
  - `src/Riski5/Lcd.hs` — minimal HD44780 16×2 controller. FSM
    cycles Idle → Pulse (16 cycles, E high) → Wait (2000 cycles,
    enforcing the 37 µs post-write minimum at 50 MHz) → Idle. MMIO
    window exposes DATA (offset 0, RS=1), CMD (offset 4, RS=0), and
    STATUS (offset 8, bit 0 = busy). Firmware runs the power-on
    init sequence itself via sequential MMIO writes.
  - `test/LcdSpec.hs` — 2 HUnit cases: E-strobe pulse width (cycles
    2..17 high, 18 low after a write issued on cycle 1); busy flag
    asserted continuously through pulse+idle. 72 tests green.
- **T15. SoC top** (2026-04-19)
  - `src/Riski5/Soc.hs` — SoC top wiring core + imem-BRAM + dmem-BRAM
    + JTAG UART + LCD + GPIO through the address decoder. Exposes
    `SocIn` (switches, keys) and `SocOut` (LEDR, LEDG, LCD pins,
    observable UART TX byte).
  - `src/Riski5/Gpio.hs` — MMIO LEDR/LEDG/SW/KEY block.
  - `test/SocSpec.hs` — 2 integration tests. First program writes
    'H' then 'i' through SW to the UART DATA register; observed TX
    stream matches "Hi". Second program writes 0x15 to LEDR via SW
    to the GPIO register; SoC's LEDR output reflects it.
  - Integration caught a real bug: JTAG UART, LCD, and GPIO slaves
    were comparing against relative offsets but the bus passes
    absolute addresses. Fixed as `fixup!` commits against T13 + T14
    to keep history clean. 74 tests green.
- **T16. DE2 top entity + pin assignments + SDC** (2026-04-19)
  - `app/Top.hs` — Clash top entity named `riski5` (with proper
    port names via `:::`), instantiates Soc with a six-instruction
    counter firmware baked into the initial BRAM contents, drops
    the UART TX observability channel (not synthesizable; the real
    Altera IP integration is T17). On-board LEDs will toggle at
    ~12 Hz when hardware bring-up starts — the "core is alive"
    signal.
  - `pkgs/riski5-core/Riski5.qpf` — Quartus project file.
  - `pkgs/riski5-core/Riski5.sdc` — 50 MHz create_clock + false-path
    on the async KEY0 reset.
  - `pkgs/riski5-core/Riski5.qsf` — Cyclone II device + verified
    CLOCK_50, KEY0, LEDR[0..7] pins (from alterade2-flake); KEY[1..3],
    SW[0..17], LEDR[8..17], LEDG[0..8], and the eight LCD pins are
    left as `TODO` comments to be filled in from the Terasic DE2 pin
    table before first flash. No pins invented.
  - `cabal build` across library + riski5-top sublib + tests all
    green; Quartus flow lands in T17.
- **T17. Nix build + flash + console apps** (2026-04-19)
  - `pkgs/riski5-core/package.nix` — mkDerivation that runs
    `clash --verilog` on `app/Top.hs`, then `quartus_sh --flow
    compile Riski5`, copies the produced `.sof` + reports + Verilog
    into `$out`. Source filter keeps dist-newstyle / result /
    .claude / .git / test/ out of the build closure.
  - `apps/flash-riski5.nix` — writeShellApplication that
    auto-detects a USB-Blaster via `jtagconfig` and pushes the .sof
    with `quartus_pgm`. Mirrors alterade2-flake's flash-de2.
  - `apps/console.nix` — writeShellApplication that launches
    `nios2-terminal`; notes that Nios II EDS is a separate
    download from Quartus and prints a clear message if the
    binary isn't available.
  - `pkgs/default.nix` — now re-exports `quartus-ii-13` from the
    alterade2-flake input and wires the three new packages + two
    apps into the flake output. `nix flake check` passes all
    derivation evaluations. Actual `nix build .#riski5-core`
    is deferred to hardware bring-up (T19) — needs Quartus
    running + the user's ~4 GB Quartus tarball prefetched.

## Ongoing

- **Blog article** — `~/purefun-front/src/blog/posts/building-riski5-rv32i-clash-core.md`
  on branch `blog_claude_building_verilator`. Update the
  "Current progress" + "What's next" sections as each phase advances.

## Blocked / parked

- (nothing)

## Open questions

- (collected here between sessions so they're not lost)
