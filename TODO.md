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

- **T19. ✦ Hello on hardware.** First-flash succeeded (`Riski5.sof`
  loaded over USB-Blaster, LEDR shows `0x8F` proving the entire
  Hello firmware ran to completion). LCD still shows black boxes
  on the top row though — debugging the HD44780 path. So far:
  - **Fixed** an LCD address-setup-time bug (data + RS rose on the
    same edge as `E`; HD44780 needs ≥40 ns lead). Added a `Setup`
    state to `Riski5.Lcd`'s FSM.
  - **Suspect 1**: missing HD44780 power-on wake sequence (3× `0x30`
    writes with proper inter-write delays).
  - **Suspect 2**: post-Clear wait too short — controller waits
    40 µs, HD44780 needs 1.52 ms to finish Clear/Home, so all
    subsequent character writes land in a busy chip and are
    dropped.
- **T19a. LCD backlight — closed: module has no backlight LED.**
  Pulled the canonical DE2 schematic into
  `docs/de2/DE2_Schematic.pdf`. Backlight drive on the board side
  is `LCD_BLON → R14 (680Ω) → base of Q5 (8050 NPN) → 47Ω → BL
  pin of LCD module U2`, emitter to GND — i.e. active-HIGH and
  fully populated on the PCB. `Top.hs` drives `LCD_BLON` HIGH.
  Owner observed in a fully dark room that there is *zero* light
  output from behind the LCD — not even leakage glow — while the
  on-board LEDs are bright enough to make HD44780 characters
  readable by reflection alone. That rules out a transistor /
  resistor defect (those would still leak some current), wrong
  polarity (already tested both), or pin-table errors.
  **Conclusion**: this DE2 shipped with the no-backlight variant
  of the HD44780 module — pins 15 / 16 on the LCD module have
  no LED soldered between them. The board's drive path is fine;
  the consumable just isn't there. Phase-1B isn't blocked
  because the LCD itself works perfectly. Re-open only if the
  user swaps in a backlit HD44780 module (standard 16-pin
  pinout, drop-in replacement).

## Next up — phase 1B (core + SoC on BRAM, hello-world on hardware)

- **T19. ✦ Milestone: hello on hardware.** The synthesis pipeline
  already closes (`nix build .#riski5-core` produces `Riski5.sof`;
  7 070 LEs / 21 %, Fmax 41.53 MHz — under our 50 MHz target, but
  hardware bring-up only needs functional silicon to toggle pins).
  Remaining blockers are physical: DE2 + USB Blaster connected,
  Quartus tarball prefetched into the Nix store, and the TODO pin
  assignments in `Riski5.qsf` filled in from the Terasic DE2 Pin
  Table. Then `nix run .#flash-riski5` and visually verify
  "Hello from Riski5" on the LCD and `hello, world\n` on the
  JTAG-UART console.
- **Timing closure at 50 MHz** — deferred to phase 1E (T40–T44).
  The current 41.53 MHz is from the single-cycle critical path
  (fetch → decode → regfile-read → ALU → writeback-mux) and the
  barrel shifter. Area is also high at 7 070 LEs / 21 % because
  Quartus inferred zero block memory bits — both register file
  and BRAM are currently distributed LUT-RAM. Moving them onto
  M4K is a phase-1E micro-optimisation, not a prerequisite for
  first hardware run.
- **T11-verilambda.** Wrap T11's pure-Clash sim in a verilambda
  driver so the same diff runs through Verilator. Deferred until the
  SoC-with-BRAM interface stabilizes (T14), since the top-entity
  shape is more naturally a SoC than a bare core.

Remaining phase-1 work (T8–T44) is detailed in the plan; summary:

- **Phase 1B** (T8–T25): ALU, regfile, core, CSRs, SoC, DE2 top,
  hello-world on hardware, InstrCatalog, on-board test agent, MemSpec.
- **Phase 1C** (T26–T31): SRAM controller + tests + firmware demo.
  Phase-1C exposes the SRAM as **half-word (16-bit) memory only**;
  see also T31a below for the deferred 32-bit-word access work.

- **T31b. Optimize the pipelineless single-cycle core — before
  starting phase 2.** The current design closes at Fmax ≈ 36.6 MHz
  (we run at 40 MHz via PLL, ~9 % over slow-corner) and uses
  ≈ 8 943 LEs (27 % of EP2C35) with **0 M4K block-memory bits**.
  Three obvious wins worth doing while the core is still simple,
  *before* the architecture expands into multiple pipeline stages:
  1. **Move the program / data memories onto M4K.** Right now
     Quartus infers them as distributed LUT-RAM (which is why
     LE count is ~5x the original ~1 600-LE estimate). Moving
     to M4K via Clash's @blockRam@ recovers thousands of LEs
     and frees them for caches / M-extension later. Need to
     handle the 1-cycle BRAM read latency cleanly — easiest is
     to align it with the natural one-cycle PC-to-imem path.
  2. **Critical-path hunt.** Read @Riski5.fit.rpt@'s worst paths;
     usual offenders on a single-cycle core are
     ALU + branch-compare → writeback mux, the barrel shifter,
     and the BRAM-read → decode → regfile-read chain. Any cone
     we can shorten without adding pipeline registers is pure
     fmax win.
  3. **Move the regfile back onto M4K** if the pipeline-stage
     work below makes it natural (currently the async-read
     register array is the right call for the pipelineless
     contract, see CLAUDE.md).
  Doing this before the EX/MEM split keeps the optimisation
  surface manageable; once we add stages, every change touches
  more wires.

- **T31a. SRAM 32-bit (word) accesses — partially unblocked,
  still phase 2.** The bus + core now carry a back-pressure
  `ready` signal (T31c, below), so multi-cycle slaves can stall
  the core. The remaining work for 32-bit SRAM access is just
  the controller-side state machine that issues two half-word
  reads/writes in sequence and only asserts `ready` after the
  second one settles. Lift to phase 2 alongside pipelining so
  the natural EX/MEM split absorbs the back-pressure cleanly.

- **T31c. Core back-pressure / multi-cycle memory — done in
  phase 1C.** Added a `ready` output from `Riski5.Sram.sram`
  (False on the first cycle of a freshly-issued read, True on
  subsequent same-address cycles plus all writes / idles). SoC's
  bus mux feeds it as `stall` to the core; `core` freezes its
  PC, CSR, and regfile-writeback registers while stalled.
  Firmware no longer needs explicit settle delays around SRAM
  accesses — `sh` followed by `lhu` works directly.
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
- **T18. Hello-from-Riski5 firmware** (2026-04-19)
  - `firmware/phase1/Hello.hs` — full `Riski5.Asm` program:
    initialises the HD44780 (function-set → display-on →
    entry-mode → clear) via the busy-polled path, writes
    `Hello from Riski5` to LCD line 1, then `hello, world\n` to
    the JTAG UART, then spins. ~150 instructions end to end.
  - `firmware/phase1/Emit.hs` — executable (`cabal run
    riski5-emit-hello -- out.mif`) that assembles the Hello
    program and emits a Quartus-compatible Memory Initialization
    File, NOP-padded to 256 words. Matches the imem size in
    `Top.hs`.
  - `app/Top.hs` — now embeds `helloFirmwareWords` instead of the
    placeholder counter. Bumps `ProgSize` from 64 to 256 words.
  - `test/HelloSpec.hs` — drives the full SoC with the Hello
    firmware for 60 000 cycles (enough for the LCD busy-wait
    loops to drain) and asserts the observed JTAG-UART TX stream
    is exactly `hello, world\n`. **First fully integrated test —
    core + bus + BRAM + LCD + UART + firmware — passes on first
    try.** 75 tests green.

## Ongoing

- **Blog article** — `~/purefun-front/src/blog/posts/building-riski5-rv32i-clash-core.md`
  on branch `blog_claude_building_verilator`. Update the
  "Current progress" + "What's next" sections as each phase advances.

## Blocked / parked

- (nothing)

## Open questions

- (collected here between sessions so they're not lost)
