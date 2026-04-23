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

- **CM — CoreMark on riski5 silicon.** Port the EEMBC CoreMark 1.01
  C benchmark, cross-compile via `pkgsCross.riscv32-embedded`, run
  on the DE2, read the score over JTAG-UART. Gives us a publishable
  number comparable against the EEMBC score database
  (https://www.eembc.org/coremark/scores.php) and against Cortex-M0 /
  PicoRV32 / VexRiscv reference runs. Four sub-tasks:
  - **CM-1. ✓ Nix derivation** `pkgs/coremark/package.nix` (+
    `bin-to-mif.py`). Fetches `eembc/coremark@v1.01`, drops our
    riski5 port alongside upstream ports, cross-compiles to
    `coremark.elf` + `coremark.bin` + `coremark.mif` + disasm +
    size report. Not wired into `pkgs/default.nix` yet (CM-3) —
    wiring waits until the port directory exists so
    `nix flake check` stays green.
  - **CM-2. ✓ Platform port.** `firmware/phase2/coremark-port/`:
    `core_portme.{c,h,mak}`, `start.S`, `linker.ld`. `start.S`
    sets up the stack + BSS zero-init + jumps to `main`;
    `linker.ld` lays `.text` at `0x0000_0000` with reset at the
    entry; `core_portme.c` implements `start_time` /
    `stop_time` / `get_time` / `time_in_secs` against `mcycle`
    (read via `rdcycle` CSR), `portable_init` / `portable_fini`
    nop, `uart_putchar` → JTAG UART MMIO at `0x1000_0000`.
  - **CM-3. ✓ Wire flake + imem-bus-port + ProgSize bump.**
    Wired `coremark = pkgs.callPackage ./coremark/package.nix {}`
    into `pkgs/default.nix`. `Riski5.Soc` now instantiates a
    second `blockRam progInit` addressed by `dAddrS` so loads in
    the SlaveBram region (`0x0000_0000..`) return the imem
    contents (.text + .rodata of CoreMark, when the CoreMark
    bytes are eventually baked in). The 1-cycle sync-read
    latency costs one stall per SlaveBram load, gated by a
    small state register `bramWaitingS`. Old Vec-based 64-word
    writable dmem dropped — writes to SlaveBram silently drop
    now, but no existing firmware / test relied on it. `ProgSize`
    bumped 2048 → 4096 in `app/Top.hs` (16 KB imem, ~32 M4K in
    the dual-port-shared case or ~64 M4K if duplicated). Stub
    `firmware/phase1/CoreMark.hs` exporting `coreMarkFirmwareWords`
    as 4096 NOPs; CM-4 replaces the body with the real
    cross-compiled bytes. 147 / 147 cabal tests green.
  - **CM-4. ✓ ✦ First EEMBC-valid CoreMark score on silicon
    (2026-04-23).** riski5 at 40 MHz = **44.57 CoreMark 1.0 /
    1.114 CoreMarks/MHz**, validated (all three
    `list`/`matrix`/`state` CRCs match the upstream
    `known_id=3` triplet, 13.46 s wall-clock ≥ EEMBC 10 s
    minimum). Two follow-up issues found + fixed in the
    same session: (a) the Altera JTAG UART IP hung
    reliably at every 64-byte FIFO boundary under back-to-
    back `sw` — fixed by polling WSPACE before each write
    in `core_portme.c::uart_send_char`; (b) `mcycle` was
    unimplemented (`Riski5.CSR` fall-through returned 0) —
    added `cMcycle` to the `Csrs` record with a free-running
    every-clock increment in `Core.hs`. Full writeup in
    [`docs/perf/coremark-2026-04-23.md`](./docs/perf/coremark-2026-04-23.md)
    including the comparison table against PicoRV32, VexRiscv
    Min/Full, and Rocket.

## Next up

- **Phase 2 P2-B.** M4K regfile swap (`regfileAsync` → `regfileSync`
  — the `RegfileBacking` scaffolding from P2A-1 is already in place).
  Saves ~300 LEs, consumes 2 M4K. Requires ID/EX reg to carry
  addresses instead of data, plus a regfile-output forwarding mux
  at X.

  **2026-04-24 attempt — reverted (silicon-only regression).** Full
  swap landed in sim (dropped `idRs1Data`/`idRs2Data` from `IdEx`,
  removed `dForward`, added `wbHoldS` for the W-1→X forwarding tier
  that covers `blockRamPow2`'s read-first gap, gated regfile read
  port through `effectiveRs{1,2}AddrS` so multi-cycle stalls keep
  the operand on the output). `cabal test`: 147 / 147 green. On
  silicon: **MemTest bitstream ran cleanly end-to-end** (SRAM /
  SDRAM tests all passed) but the **CoreMark bitstream produced
  zero UART output in 45 s** of capture — firmware hung somewhere
  before the first `ee_printf` landed a byte on the JTAG UART.
  Fmax closed at 50.87 MHz (+5.34 ns slack at the 40 MHz target),
  so timing is not the cause. Attempt archived as
  [`docs/perf/phase-2b-attempt-2026-04-24.patch`](./docs/perf/phase-2b-attempt-2026-04-24.patch).

  Diagnostic next steps when resumed:
  1. Reproduce the hang in simulation by baking the CoreMark
     firmware bytes into a new sim test (`test/SocCoremarkSim.hs`?)
     that runs `socSim` for ~50M cycles with a sim-side JTAG UART
     collector — catch the hang pre-silicon.
  2. If sim doesn't reproduce, instrument the silicon bitstream
     (e.g. GPIO-tap the pipeline stage IdEx.pc + IdEx.idRs1 + rs1FwdS)
     to see which pc the hang stops on.
  3. Suspects to rule out: (a) the read-address gating
     (`effectiveRs{1,2}AddrS`) — may interact badly with the 1-cycle
     BRAM-read stall that CoreMark hits on `.rodata` loads but
     MemTest never exercises; (b) `wbHoldS` capturing `Nothing`
     during sustained stalls losing a forward that would be needed
     at stall-release (possible but regfile memory state naturally
     has the value by that point — unless there's a subtle timing
     window); (c) some CoreMark-specific instruction sequence
     (mcycle CSR read plus BRAM load plus UART poll) that doesn't
     show up in any `test/*Spec.hs` case.

- **CM-5. UART back-to-back-write regression test.** The
  CM-4-era fix (polling WSPACE in `core_portme.c::uart_send_char`
  before every write to `0x1000_0000`) unblocked CoreMark's
  silicon run, but right now nothing in the test suite catches a
  future regression that re-introduces unchecked back-to-back
  `sw`s. Add a sim-level test that:
  1. Extends `jtagUartSim` (or adds a new sim model alongside
     it) to faithfully model the Altera IP's **first-cycle-
     waitrequest + FIFO-full-waitrequest** behaviour, including
     the single-cycle `av_write=0` gap the real IP's drain FSM
     needs between writes to advance reliably. The current
     `jtagUartSim` returns `siUartReady = True` constantly, which
     masks the bug.
  2. Wires that improved model into `socSim` (or a dedicated
     `SocCoreMarkLikeSpec`) and runs a small firmware image that
     does ~100 back-to-back `sw` writes to `0x1000_0000` with
     *no* WSPACE poll in between — the test asserts that either
     every byte eventually lands on the sim-UART output **or**
     the sim deadlocks within a bounded cycle budget (which is
     the failure we want to catch pre-silicon).
  3. Adds a second test using the CM-2-port pattern (WSPACE
     poll before each write) and asserts the full byte stream
     lands without deadlock — i.e. proves the fix actually
     fixes it.
  Lives in `test/UartBackpressureSpec.hs`, aggregated into
  `test/Spec.hs`. Passes without Quartus / hardware — pure
  Clash `sampleN` over `socSim` — so it catches the regression
  in `cabal test`, long before the next silicon bring-up.
  Document the expected contract in a module header so whoever
  re-writes `uart_send_char` next understands why the poll is
  load-bearing.
- **Phase 2 P2-C.** Sync dmem + first caches (direct-mapped
  1 KB I$ + 1 KB D$, per the Tiny tier defaults in
  [`docs/core-family.md`](./docs/core-family.md) §4.3).
- **Phase 2 P2-D.** PLL bump to 45 MHz once the X cone shrinks
  (either from M4K regfile or the M-stage split) gives headroom.

## Done — phase 2 P2-A (pipelining + PLL retarget)

- **P2A-1. ✓ Regfile backing abstraction (2026-04-21 → commit
  3b9ce6a).** `Riski5.Regfile` now exports two interchangeable
  backings with identical black-box semantics modulo read
  latency: `regfileAsync` (today's LE-based combinational-read
  register-array) and `regfileSync` (2 × `blockRamPow2`, maps
  to two M4K on Cyclone II, 1-cycle read latency). A
  value-level `RegfileBacking` tag documents the choice for
  future `CoreConfig` integration. Existing `regfile` stays as
  a backward-compat alias for `regfileAsync`. `RegfileSpec`
  grows a second matching test group for the sync backing.
  147 / 147 green.
- **P2A-2. ✓ 5-stage F|D|X|M|W with full forwarding (2026-04-21
  → commit 10fa187).** Full rewrite of `Riski5.Core` from
  2-stage F+X to the classic 5-stage in-order pipeline the
  Tiny tier targets. Pipe registers IF/ID / ID/EX / EX/MEM /
  MEM/WB; EX→X + MEM→X 3-source forwarding muxes at X stage
  inputs; W→D same-cycle bypass on the async regfile read
  path; 2-cycle branch-taken flush (flush + flushPrev) to
  cover the sync-imem stale-fetch slot after redirect; held
  imem register preserves the about-to-latch instruction at
  stall onset so SRAM / SDRAM back-pressure doesn't lose an
  instruction. Full test suite (147 / 147) green; tests
  updated for the deeper pipeline depth (6-cycle warm-up
  drop, RVFI-valid-counted `take nSteps` so retirements match
  the Reference's step budget).
- **P2A-4. ✓ Quartus synthesis + Fmax measurement + PLL
  retarget (2026-04-21 → commit 4a023c3).** New slow-model
  Fmax **53.62 MHz** (+62.6 % over baseline 32.98 MHz). PLL
  retargeted 50 × 3 / 5 = 30 MHz → 50 × 4 / 5 = 40 MHz, closing
  with +6.35 ns slack at the slow-85 °C corner. LEs 10,955 / 33,216
  (33 %; −432 vs baseline). Critical path now the X stage's
  combinational cone (`idExS → handleInstr dispatch → EX/MEM`),
  ~18.6 ns. Documented in
  [`docs/timing/pipeline5-2026-04-21.md`](./docs/timing/pipeline5-2026-04-21.md).
- **P2A-5. ✓ ✦ Silicon green at 40 MHz (2026-04-21 → fixup
  commit 735796e).** First flash of the 5-stage bitstream
  turned up a silicon-only bug — SW/SRAM words stored
  with a corrupted hi half — traced to forwarding collapse
  when EX/MEM drained to bubble during stall cycles (the
  stalled SW's rs2 forwarding fell back to the stale
  ID/EX-captured value, so SRAM latched the right lo half
  at cycle-N WE↑ but the wrong hi half at cycle-N+2 WE↑).
  Fix: EX/MEM and MEM/WB now hold frozen on stall instead
  of draining to bubble; `writeBackOutS` + `rvfiValidS`
  gated on `not stall` so a held MEM/WB doesn't retire
  repeatedly. All five phase-1 Hello diagnostics then print
  OK on `nios2-terminal` first try: `hello, world` /
  `M-ext OK` / `SRAM OK` / `SRAM W32 OK` / `SDRAM OK` on
  the freshly flashed DE2 at 40 MHz. Same bitstream closes
  with +6.35 ns slack on slow-85 °C STA.
  **Phase 2 P2-A complete end-to-end.**

## Done — phase 1D

- **T32. ✓ Avalon-MM bus shim (2026-04-21).** New
  `src/Riski5/AvalonMm.hs` owns the canonical master-side record
  (`AvalonMmBus` — `ambSel` / `ambAddr` / `ambWdata` / `ambBe` /
  `ambRe`) and a matching `AvalonMmReply` for the slave → master
  leg, plus tiny helpers (`mkAvalonMmBus`, `mkAvalonMmReply`,
  `avRead`, `avWrite`). Replaces the old ad-hoc `JtagUartBus`
  with the shared type so the SDRAM IP wrapper (T34) drops
  straight in. `Riski5.JtagUart` / `Riski5.Soc` / `app/Top.hs`
  + hardware wrapper already carried an identical shape under
  `ubX` field names — renamed through to `ambX`; semantics
  unchanged. Six new `AvalonMmSpec` tests pin the strobe truth
  table and signal-bundling round-trip so a future refactor of
  the shim breaks a test instead of silently propagating into
  every IP wrapper. Full suite **135 / 135 green**.
- **T33. ✓ Generate Altera SDRAM Controller IP (2026-04-21).**
  The `altera_avalon_new_sdram_controller_hw.tcl` component is
  scriptable via `ip-generate` just like the JTAG UART IP was —
  no MegaWizard hand-click needed. `pkgs/riski5-core/package.nix`
  gets a second `ip-generate` invocation with the IS42S16400-7B
  timing parameters (CL=2, tRCD=20, tRP=20, tRFC=70, tWR=14 ns;
  refresh 15.625 µs, powerUp 100 µs, dataWidth=16). The generated
  `altera-ip/sdram/riski5_sdram.v` drops alongside the UART IP
  and the .qsf picks it up as a VERILOG_FILE source.
- **T34. ✓ Black-box SDRAM IP from Clash (2026-04-21).**
  `src/Riski5/Sdram.hs` mirrors `Riski5.Sram` in shape: a 7-state
  FSM splits 32-bit core accesses into two back-to-back 16-bit
  Avalon-MM transactions against the IP. `SdramIpBus` carries the
  master-side signals to the IP; `SdramIpReply` carries @za_data@
  / @za_valid@ / @za_waitrequest@ back. `sdramIpSim` provides a
  behavioural IP-plus-chip model for the Clash testbench. Cycle
  costs at 30 MHz (best case, no chip-level bank contention):
  SB/SH 2 cycles, SW 3 cycles, LW 5 cycles. Six new `SdramSpec`
  tests cover round-trips, byte-index routing, back-to-back
  writes, and pin the exact ready-high cycle counts. Full suite
  **141 / 141 green**.
- **T35. ✓ SDRAM pins + SDC (2026-04-21).** All 38 DRAM_* pin
  assignments added to `Riski5.qsf` (pulled from
  `docs/de2/DE2_Pin_Table_2006-02-15.pdf` via pdftotext +
  cross-reference). `Riski5.sdc` gains a `create_generated_clock`
  for DRAM_CLK so STA carries the constraint to the SDRAM-chip
  output pins. DRAM_CLK is forwarded from clk30 directly (no
  phase-shifted PLL tap) — at 30 MHz the setup/hold margin
  against IS42S16400-7B's 1.5 / 0.8 ns requirements is well
  over 15 ns either way.
- **T36. ✓ Route SDRAM onto bus at 0x8000_0000 (2026-04-21).**
  `Soc.hs` grows `siSdramReply` input and `soSdramBus` output
  plus the Slave{Bus,Stall,ReadMux} arms; `socSim` plugs
  `sdramIpSim` into the bus tap so the whole SoC simulation
  keeps working end-to-end through SDRAM accesses.
  `app/Top.hs` exposes 3 input + 6 output ports for the SDRAM
  signals. `riski5_top.v` instantiates `riski5_sdram`, inverts
  our active-high strobes into the IP's active-low
  `az_{rd,wr}_n` / `az_be_n`, forwards clk30 to DRAM_CLK, and
  wires the IP's `zs_*` ports to the DRAM_* board pads (with
  the inout DRAM_DQ handled by the IP internally).
- **T37. ✓ SDRAM sim coverage (2026-04-21).** `SocSpec` gains
  `case_sdramRoundTrip`, which SW/LWs 0x5A at sdramBase through
  the full SoC (bus → adapter → sim IP) and observes the
  round-tripped byte surface on the JTAG UART TX stream.
  **142 / 142 green** after this lands.
- **T38. ✓ Firmware SDRAM bring-up demo (2026-04-21).** Hello
  firmware gets an SDRAM block after the SRAM checks: writes
  0xCAFEBABE to sdramBase, reads back via LW, folds the
  comparison into the hexReg failure accumulator, and prints
  `SDRAM OK` / `SDRAM ERR got=0xXXXXXXXX` on the UART. LCD
  summary line flips between "riski5: MEM OK" and
  "riski5: MEM ERR" based on all three checks (SRAM half-word,
  SRAM 32-bit, SDRAM 32-bit). Firmware size 680 / 1024 words.
## Done — phase 1E

- **T40. ✓ Baseline fmax + critical-path snapshot (2026-04-21).**
  `docs/timing/baseline-2026-04-21.md` + archived STA / fit
  reports capture the post-phase-1D state: 32.98 MHz slow-model
  Fmax, +3.012 ns slack at the 30 MHz target, worst path is the
  imem address register → regfile write-port cone at 30.287 ns
  data delay. That's the whole pipelineless single-cycle
  datapath in one clock period (fetch → decode → regfile read →
  ALU / MulDiv / CSR → writeback mux → regfile write).
  T41 / T43 / T44 skipped — no PLL retarget that closes timing
  is available and no Quartus-effort change moves the needle
  meaningfully. The next Fmax step is **phase-2 P2-A
  pipelining**, which is what the plan's T42 scope-guard
  prescribed for this outcome.

## Done — phase 1D

- **T39. ✓ ✦ SDRAM green on DE2 silicon (2026-04-21).**
  First flash with the T38 firmware bitstream
  (`42sswq0r95k3j83lzwf3bslk284gaswg`): `nios2-terminal`
  printed `hello, world` / `M-ext OK` / `SRAM OK` /
  `SRAM W32 OK` / `SDRAM OK` on boot — the 0xCAFEBABE 32-bit
  SW / LW round-trip through the off-chip IS42S16400 via the
  Altera `altera_avalon_new_sdram_controller` IP + our
  `Riski5.Sdram` 32 ↔ 16 FSM came back intact. LEDR[17] lit,
  LCD line 1 "riski5: MEM OK  ", line 2 "SRAM+SDRAM:CAFE ".
  Fit (T38-firmware bitstream `42sswq0r95k3j83lzwf3bslk284gaswg`):
  11,387 LEs (34 % of EP2C35; +1,087 vs pre-phase-1D baseline,
  of which ≈ 474 is SDRAM adapter + IP routing and ≈ 613 is the
  extended Hello firmware's imem M4K bits spilling into tie-off
  logic), 31,744 block memory bits (~7 M4K of 105), Fmax 32.98 MHz
  at slow-85 °C — the pre-T38 build's 10,774 LEs was the same
  design without the T38 firmware expansion baked into imem.
  **Phase 1D complete.** Next up is phase 1E's fmax
  exploration.

## Done — phase 1C completion

- **T31a. ✓ SRAM 32-bit word access (2026-04-21).** `Riski5.Sram`
  rewritten around an explicit FSM that gives every write a
  pulse + recovery cycle pair (fixing the latent back-to-back
  `WE_N`-held-low hazard) and promotes every read to a 3-cycle
  32-bit word fetch. `LW` returns the full word; `LH` / `LB`
  still work because the core's own load-width masking picks
  the right bits from the 32-bit rdata. Byte / half-word writes
  keep their per-lane `UB_N` / `LB_N` gating. Cycle costs at
  30 MHz: any read 3 cycles (100 ns); SB / SH 2 cycles (66.67 ns);
  SW 4 cycles (133.33 ns).
  `sramSim` tightened to latch only on the `WE_N` rising edge —
  previously it committed on any `WE=low` cycle, which silently
  tolerated controllers that skipped the recovery cycle. Three
  new SramSpec cases cover 32-bit SW/LW round-trip, back-to-back
  SH overwrite (regression for the latent bug), and same-address
  read-after-write. Full suite **129 / 129 green** (SramSpec 6/6
  including the 3 new T31a cases). Hello firmware extended with
  `SRAM W32 OK` / `SRAM W32 ERR got=0xXXXXXXXX` UART diagnostic
  and an LCD "half A5A5 w DEAD" status line; firmware 551 / 1024
  words.
  **Silicon: green.** `nios2-terminal` from the freshly flashed
  DE2 showed `hello, world` / `M-ext OK` / `SRAM OK` / `SRAM W32 OK`
  on first boot — the 32-bit round-trip at `0x2000_0004` with
  `0xDEADBEEF` survived the SW → LW trip through the off-chip
  IS61LV25616 and the FSM combined the two half-word reads back
  into a single 32-bit word correctly. Fit report: 10,300 LEs
  (+32 vs pre-T31a for the FSM state + `wordLoReg`; 31 % of
  EP2C35); Fmax 32.7 MHz at slow-85C (vs pre-T31a 32.86 MHz — a
  0.16 MHz regression within noise, not the uptick expected).
  The critical path the STA report flags is `altsyncram imem
  address register → regfile[N]` at 30.5 ns data delay — the
  pipelineless fetch → decode → ALU → writeback cone, *not* the
  SRAM data path, so T31a's registration didn't move the
  overall ceiling. Breaking that cone needs proper pipelining
  (phase-2 P2-A), not more combinational shortening.

## Phase-2+ planning artefacts

- **Core-family plan landed (2026-04-21).** Forward-looking design
  note at [docs/core-family.md](./docs/core-family.md) — five tiers
  (Tiny / Little / Mid / Big / Performance) each in RV32 / RV64
  editions (+ speculative RV128 Performance), `CoreConfig`
  type-level parameter space, composable block layer, DE2
  minimal-variant feasibility math, phase 2–5 roadmap.
  [docs/future-soc-configurability.md](./docs/future-soc-configurability.md)
  carries a forward-pointer header noting supersession;
  [CLAUDE.md](./CLAUDE.md) forward-looking section updated.
  First implementation step (phase 2A) is still pending — not
  blocked on anything; any session can pick it up.

## Done — phase 2 milestones

- **Phase 2B on silicon. ✓ RV32M smoke test green on DE2
  (2026-04-21).** Rebuilt the bitstream with Hello firmware
  extended to run five UART-diagnosed M-op checks before
  SRAM / LCD: MUL (7×6=42), DIVU (100/7=14), REMU (100%7=2),
  MULH signed ((-1)×(-1) high-32 = 0), DIVU-by-zero (→ -1).
  `nios2-terminal` showed `MUL OK` / `DIVU OK` / `REMU OK`
  / `MULH OK` / `DIV0 OK` in that order on the first boot.
  The iterative FU, the `stallInternal = stallS ‖ mdBusy`
  path, and the `writeBackWithMd` retire mux all behave on
  Cyclone II exactly like they do in sim and formal —
  silicon agrees with the 126/126 + 61/61 proofs. Fit
  report: 10,268 LEs (+1,134 vs pre-M baseline = 31 % of
  EP2C35); Fmax 32.86 MHz (vs pre-M 34.22 MHz — 1.4 MHz
  drop, still closing with real margin at the 30 MHz core
  clock). ProgSize bumped 256 → 512 words (the extended
  firmware is 455 words); M4K usage rose from 2 → 4 blocks,
  still far under the ~95-block budget.

- **Phase 2B. ✓ RV32M M-extension via iterative MulDiv FU
  (2026-04-21).** Eight new `Instr` constructors (MUL / MULH /
  MULHSU / MULHU / DIV / DIVU / REM / REMU) wired through
  `Riski5.ISA` + `Encode` + `Decode` + `Asm` + `Reference`.
  New `src/Riski5/Core/FU/MulDiv.hs` implements an iterative
  shift-and-add multiplier (32 iter, 34 cycles including
  dispatch + done) + restoring-division divider with divide-
  by-zero early-out (2 cycles) and natural signed-overflow
  handling. The FU's `mdBusy` OR's into the existing `stallS`
  path — no pipeline restructure. `tiny32M` preset = `tiny32
  { ccMulDiv = MdIterative 32 33, extM = True }`; `coreWith`
  dispatches it through the same kernel (the FU idles when
  `extM` is off). Synth callers (`Soc.hs`, `FormalTop.hs`,
  `app/Top.hs` via `Soc`) now target `tiny32M`. Spike driver
  default ISA flipped to `rv32im`.
  **Cabal: 126 / 126 green** (+10 M catalog in `CoreSimSpec`,
  +10 in `SpikeDiffSpec` — triple-diff Spike ↔ Reference ↔
  Core).
  **Formal: 61 / 61 PASS.** Closure came via a two-step
  retreat: first added a `mulDivFUCombinational` variant in
  `Riski5.Core.FU.MulDiv`, CPP-gated on `FORMAL_FAST_MULDIV`
  (passed as `-optP-DFORMAL_FAST_MULDIV` from the formal
  package.nix). That lets the formal build see a 1-cycle
  retire instead of the 34-cycle FSM. The combinational
  multiply on its own still left the solver grinding for
  7+ min per proof (32×32→64 SAT is hard for both boolector
  and z3). Second fix: route `combMd` through the exact
  `RISCV_FORMAL_ALTOPS` bitmask formulas upstream riscv-formal
  ships for exactly this case — `(rs1 ± rs2) ^ 32'h…` per
  op — and `\`define RISCV_FORMAL_ALTOPS` in checks.cfg. The
  solver now compares two bit-identical expressions; all 8
  M proofs close in depth-10 BMC in seconds. Soundness
  argument: the formal proof establishes the core pipeline
  routes M-op operands correctly; arithmetic correctness of
  the iterative FU is covered by the triple-diff harness
  against Spike's native RV32IM. A phase 2C+ task is the
  FU-isolation proof (`mulDivFUIterative` ≡
  `mulDivFUCombinational` under a standalone SymbiYosys
  proof) that would turn triple-diff into exhaustive
  coverage for the arithmetic.

## Done — phase 1B hardware + verification milestones

- **T19-continued. ✓ Altera JTAG UART IP verified on hardware
  (2026-04-21).** Rebuilt the bitstream at commit `ca7ff3c`
  (9,134 LEs / 27 %, 8 KB M4K, Fmax 34.22 MHz at slow-85C
  corner). `nix run .#flash-riski5` pushed it over the USB-
  Blaster; `nix run .#console` → `nios2-terminal` showed a
  clean `hello, world\n` from the JTAG UART. The 2026-04-20
  NUL-byte bug (dropped `av_writedata` while `av_waitrequest`
  was asserted, plus the combinational loop via `dmemBe`
  stall gating) is fixed on real silicon. All three
  verification layers — Reference interpreter, Spike triple-
  diff, Verilator-via-verilambda SoC sim, and SymbiYosys
  formal — said "green" before the flash, and silicon agreed.

- **Wider formal proofs — done (2026-04-21).** `checks.cfg` now
  enables `pc_fwd`, `pc_bwd`, `reg`, `causal`, `ill`, `unique`
  alongside the per-instruction proofs, plus `csrw_<csr>` for
  each of the six M-mode CSRs and `csrc_any_<csr>` for the
  three purely CSR-mutated ones
  (`mstatus`/`mtvec`/`mscratch`) via the new `RvfiCsr`
  observability blocks. The trap-written CSRs
  (`mepc`/`mcause`/`mtval`) stay in `csrw_*` only — csrc_any's
  shadow-register model can't see the trap path updating them.
  `reg` runs under boolector at depth 10 (nerv's config);
  `csrc_any_*` get swapped to z3 via sed post-processing
  because boolector's bit-blaster stalls on their quantifier-
  heavy invariants. Total: **52 / 52 green**. `liveness`
  remains deferred — adversarial JAL-to-self symbolic imem
  can hold `squashNext=True` forever in the pipelineless
  core, which no fixed-depth k-induction closes.

## Done — Spike + riscv-formal verification layers

- **T-VS. Spike Layer-1.5 differential (green, 2026-04-20).**
  Three modules cover it:
    - `pkgs.spike` + `pkgs.dtc` +
      `pkgsCross.riscv32-embedded.buildPackages.binutils` on
      the devshell.
    - `src/Riski5/Elf.hs` renders @.word@-per-instruction
      assembly + linker script → `riscv32-none-elf-{as,ld}` →
      ELF loaded at `0x8000_0000` (Spike's RAM base).
    - `src/Riski5/SpikeDriver.hs` spawns Spike under `stdbuf
      -eL` for line-buffered stderr, reads the
      `--log-commits` trace into `SpikeCommit` records, and
      terminates cleanly on commit/line/wallclock budgets.
    - `test/SpikeDiffSpec.hs` runs 9 pure-ALU catalog programs
      through both Reference and Spike, diffs non-zero GPRs.
      All 9 green.
    - `firmware/phase1/Emit.hs` now emits `hello.{mif,bin,elf}`.

- **T-VF-2. RVFI + riscv-formal (green, 2026-04-21).**
  SymbiYosys model-checking of the Clash-emitted Verilog
  against the YosysHQ/riscv-formal RVFI spec for every RV32I
  instruction:
    - `src/Riski5/Rvfi.hs` — 20-ish RVFI signal record.
    - `src/Riski5/Core.hs` — computes the record from internal
      datapath signals, exposes as 8th core output.
    - `src/Riski5/FormalTop.hs` — second Clash top emitting
      flat `rvfi_*` ports named as the spec expects.
    - `pkgs/riscv-formal/package.nix` pins
      YosysHQ/riscv-formal by commit.
    - `pkgs/riski5-formal/{wrapper.sv,checks.cfg,package.nix}`
      run `genchecks.py` + `make -C checks` to exercise the
      per-instruction + `pc_fwd` / `pc_bwd` / `reg` /
      `causal` / `ill` check families under boolector.
  Two real bugs in `Riski5.Core` fell out of the first real
  proof run (commit 8e6b9d2):
    1. `rvfi_mem_addr` was the byte address where the spec wants
       `addr & ~3` — fix in the RVFI tap.
    2. Branches / JAL / JALR didn't raise
       `InstrAddrMisaligned` when the target's bottom two bits
       weren't zero. Our hand-written tests never hit this
       because the Asm eDSL can't emit a misaligned immediate,
       but the formal harness drives symbolic inputs and walked
       straight into it. Fix in each of those instruction
       handlers + a matching fix in `doBranch` that tests the
       actual `next_pc[1:0]` (not just the taken-target) — the
       fall-through path can be misaligned if `pc` itself is
       misaligned, which only the harness can set up.
  After both fixes: 37/37 per-insn proofs PASS; running the
  wider families (pc_fwd/pc_bwd/reg/causal/ill) is a rebuild
  away.

## Done since last compaction

- **T-VF-1. Verilator SoC sim via verilambda (green as of
  2026-04-20).** The skeleton landed earlier in the day got the
  real meat:
    - `test/SocHwSim.hs` — full HKD port record + 36-byte Storable
      mirror + 4 `foreign import ccall` bindings + `SimBackend`
      wiring. The port layout in `pkgs/riski5-sim/clash-manifest.json`
      was reordered to 32-bit → 16-bit → 8-bit so the C struct has
      zero internal padding (1-byte trailing pad only).
    - First real test: boots the Hello firmware under the real
      Altera IP Verilog, collects the UART TX byte stream via a
      `UART_TX_VALID` / `UART_TX_BYTE` tap in `riski5_sim_top.v`,
      asserts the stream begins with `hello, world\n`. Stops early
      once 13 bytes are seen; total runtime ~0.1 s.
    - Build plumbing: the `hwsim` cabal flag + `cabal.project`
      entry pulling in verilambda as a sibling package;
      `pkgs/riski5-sim/package.nix` exposed in the flake output;
      devshell added the env-var hint for `RISKI5_SIM_LIB_DIR`.
    - Two supporting fixes the first build shook out:
      * Renamed the `byte` signal in `Riski5.Core.extendLoad`
        (`loadByte`) and the `byte` pattern variable in
        `Riski5.Lcd.{userWaitFor,beginUser,nextStateS}` (`dataByte`) —
        SystemVerilog reserves `byte`, so Clash's emitted signals
        tripped Verilator 5.
      * Dropped the `dmemBe`-stall gating in `Riski5.Core` (see
        T19-continued above — a real bug, not just a sim-only
        workaround).
    - Regression fence verified: against a spot-reverted copy of
      `Core.hs`, the test correctly fails with "collected 0 bytes"
      — this would have manifested on silicon as the 2026-04-20 NUL
      bytes.
    - All 90 tests pass (placeholder path without the flag, real
      test under `--flag=hwsim`).

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
- **Phase 1C** (T26–T31, incl. T31a): SRAM controller + tests +
  firmware demo. 32-bit word access landed 2026-04-21.

- **T31b. Optimize the pipelineless single-cycle core — explored;
  most gains deferred to phase 2.**
  * **Done**: switched Quartus to OPTIMIZATION_TECHNIQUE SPEED
    plus physical-synthesis combo-logic / register-duplication /
    register-retiming at EXTRA effort. Fmax 36.59 → **41.63 MHz**
    (+14 %), LEs 8943 → 8557. Free win, kept.
  * **Tried + reverted**: moved imem to M4K via a `bramSyncRead`
    variant and routed its per-fetch ready signal through the
    stall path. LEs only dropped ~150 and Fmax *regressed* to
    35.36 MHz — the stall-on-every-fetch approach added a LUT
    to every register's feedback that Quartus couldn't retime
    through, and the 2-cycles-per-instruction penalty halved
    throughput. Real M4K / regfile / critical-path gains need
    proper pipelining with overlapping fetch + execute stages,
    which is phase 2.
  * **Still to try (phase 2 territory)**: proper EX/MEM split
    with overlapping stages, M4K regfile, barrel-shifter
    rework, maybe a PLL re-target to push the 40 MHz core clock
    higher now that there's slack.

- **T31d. STA-reported critical path is PC → regfile array.**
  The top ~100 slack-negative paths in the phase-1C fit report
  all run from `pc[N]` (PC register output) to `regs[M]` (regfile
  register array), with ~27 ns data delay vs 25 ns cycle. The
  path is the full single-cycle chain:
  PC → imem LUT-RAM 256:1 mux → decode → regfile read mux →
  ALU → writeback mux → regs[rd]. Any meaningful shortening
  needs a pipeline boundary somewhere in that chain — phase 2.

- **History: autosquash attempted, deferred.** Tried
  `git rebase -i --autosquash` across the phase-1 fixups. The 19
  fixups landed interleaved with ~30 feature commits (same files
  edited by non-fixup work in between), so each squash produced a
  content conflict that had to be resolved manually — too much
  churn for the benefit. Keeping the messy-but-accurate history:
  every fixup commit message names which feature commit it
  amends, and the `pre-autosquash-backup` branch preserves this
  state. Phase 2 can still start from a clean base (the working
  tree is consistent). Revisit if the log ever needs to be
  published externally.

- **T31a. ✓ SRAM 32-bit word access — shipped 2026-04-21** (see
  "Done — phase 1C completion" above).

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

## Phase 2 — pipelining

Kick-off attempted, reverted. Lessons from the attempt to bank
for the next session's take:

- **P2-A. Core 2-stage pipeline (F+X).** Minimal viable split:
  * `pcFetch` register drives imem address (M4K sync-read).
  * `pcExec` register = previous cycle's `pcFetch` (the PC of the
    instruction currently in X).
  * `squashNext` register goes True when X takes a non-sequential
    PC change (branch taken, JAL, JALR, MRET, trap). On the next
    cycle it replaces `imemData` with NOP and suppresses
    writeback / CSR / dmem side effects.
  * Key pitfall hit last time: **`pcS` output of `core` changes
    meaning**. It was "PC of the executing instruction"
    (pipelineless), becomes "PC being fetched" (pipelined) — one
    cycle ahead of execute. Tests that assert specific pcS
    sequences need reworking.

- **P2-B. Test-harness prep — done for the static part.** The
  core's output tuple gained a `pcExec` signal alongside
  `pcFetch`; all four core-facing tests (CoreSpec, CoreSimSpec,
  BramCoreSpec, TrapSpec) now unpack the 7-tuple and pair writeback
  traces with `pcExec`. Today `pcFetch == pcExec` so this is a
  semantic no-op; after pipelining they split automatically.
  Remaining prep that has to land **atomically with** the core
  refactor (since they would break the pipelineless core
  individually):
  * Wrap each test's imem lookup with `CP.register 0x0000_0013`
    so async-Vec lookup gains the 1-cycle delay the pipelined
    core assumes.
  * Bump `cycles = nSteps + 1` → `nSteps + 2` in CoreSimSpec +
    BramCoreSpec for the pipeline-warmup cycle.

- **P2-C. SoC update.** Switch `imemDataS` from `bram` to
  `blockRam` driven by `pcFetch`. This is where the ~7000 LE win
  shows up (imem goes from distributed LUT-RAM to true M4K) —
  which also shortens the PC→imem→decode→regfile→ALU→writeback
  critical path that dominated phase 1C.

- **P2-D. Squash-on-stall interaction.** When SRAM stalls a
  multi-cycle access, the `squashNext` register must ALSO freeze
  (matching PC / CSR freeze). The stall should extend whatever
  squash state we're in, not reset it.

- **P2-E. Two-address SRAM test.** Once core stalls are clean,
  the failed two-address SRAM test (0xBEEF + 0xCAFE across
  addresses) should re-test green — phase-1C hit a back-to-back
  bus-contention issue that the stall should now cover.

- **P2-F. 32-bit SRAM access (T31a) — done 2026-04-21** (in
  phase 1C, not phase 2; see "Done — phase 1C completion" above).

- **P2-G. Re-target PLL.** Once the critical path is shorter,
  walk `Dom40` upward (60, 80, 100 MHz?) via the ALTPLL mult/div
  ratios and re-close timing. The 14% speed-mode win is already
  banked; phase 2 should compound on it.

- **P2-H. ✓ Self-timed HD44780 controller with IRQ.** Done.
  `Riski5.Lcd` now runs its own Vcc-settle (1.5 M cycles) + full
  HD44780 wake sequence (3×0x30, then function-set 0x38, display-
  on 0x0C, entry-mode 0x06, clear 0x01) autonomously at reset,
  and picks the right per-command post-pulse wait (80 k cycles
  for Clear / Return-home; 2 k cycles for everything else). The
  firmware dropped ~30 lines of `delayCycles` + raw 0x30 writes
  and now just spin-waits on the `busy` flag before each write.
  A new IRQ output line asserts on the busy-falling edge when
  `CTRL[0]` is set; `STATUS[1]` is a sticky W1C pending flag so
  the CPU can sleep instead of polling (first concrete peripheral
  following the "don't require CPU polling" rule below).
  `SocOut` now exposes `soLcdIrq` so phase-3's PLIC can wire it
  in without an interface change. 4 new LcdSpec tests (parameter-
  ised over a shrunk startup window so they run in milliseconds)
  cover the boot-sequence byte order, user-write pulse timing,
  IRQ latch, and IRQ enable gating. All 89 tests still green.

- **P2-I. Minimal LCD-only simulation test.** Once P2-H lands,
  add a sim test that writes a single character to the LCD and
  asserts the correct @E@-pulse / @RS@ / @DATA@ sequence appears
  on `LcdPins` — no LED counter, no SRAM, no scrolling. Fast
  (~200 cycles), catches regressions in the LCD controller's
  pulse timing and the core's MMIO-write path end-to-end.

## Linux-friendly design rules (applied phase 3 onwards)

The end goal is running Linux on riski5 with *minimal* custom
driver work. The bus and peripheral decisions below are chosen
so the kernel uses upstream drivers wherever possible; our
custom design only needs a device-tree entry to bind them.

- **Bus: memory-mapped, byte-addressable, simple, no reordering.**
  Linux's `ioremap` + `readl` / `writel` / `readw` / `writeb`
  work on anything matching this — our current `Riski5.Bus` does.
  The specific protocol (custom Clash bus / Avalon-MM / Wishbone
  / AXI4-Lite) is invisible to Linux. Adopt Avalon-MM for our
  next refactor so Altera IP (JTAG UART, SDRAM controller, future
  PCIe on newer boards) drops in without a bridge.

- **Peripherals as platform devices via device tree.** Each
  peripheral gets a DTS node with `compatible`, `reg`,
  `interrupts`. The Linux build loads a matching driver by
  `compatible` string. No bus discovery, no hotplug.

- **Use standard register layouts where upstream drivers exist.**
  For each peripheral pick the cheapest path to "zero new driver
  code":
  * **UART**: 16550 / NS16550A layout → `drivers/tty/serial/8250_of.c`.
  * **Timer**: RISC-V CLINT layout → `drivers/clocksource/timer-riscv.c`.
  * **Interrupt controller**: SiFive PLIC layout →
    `drivers/irqchip/irq-sifive-plic.c`.
  * **GPIO**: `gpio-mmio` supported layouts.
  * **Ethernet (DM9000A on DE2)**:
    `drivers/net/ethernet/davicom/dm9000.c` already works.
    Our job is only to memory-map the chip's two registers
    (INDEX + DATA) through the bus and wire `ENET_INT` into
    the PLIC. No NIC driver to write.
  * **LCD (HD44780)**: no upstream driver matches our MMIO shape
    (the kernel's `drivers/auxdisplay/hd44780.c` is for
    GPIO-bitbanged modules). Plan: small misc or framebuffer
    driver, maybe ~200 lines. Acceptable — the LCD is not on
    the critical path for bringup.

- **Interrupts go through a PLIC.** A per-slave `irq` line gets
  aggregated by a PLIC-compatible block into `mip.meip`; the
  core's trap logic fires on enabled external interrupts. This
  replaces the polling pattern for every peripheral — matches
  the user's general "peripherals signal the CPU, not the other
  way around" principle.

- **Peripheral blocks expose their own completion / busy via
  interrupt.** No firmware busy-polling. See P2-H for the first
  concrete example (LCD generates an IRQ when the write
  completes instead of the CPU polling the busy bit).

### Phase-3 tasks that apply these rules

- **T-LI1. PLIC-compatible interrupt controller.**
  `src/Riski5/Plic.hs` — per-slave interrupt inputs, priority,
  enable/pending register layout compatible with SiFive PLIC.
  DT compatible = `"sifive,plic-1.0.0"`. Core's trap logic
  gains external-interrupt handling (`mip.meip`, `mie.meie`).

- **T-LI2. 16550-compatible UART.** Replace the Altera-specific
  JTAG UART in @Riski5.JtagUart@ with a 16550-layout MMIO block
  (RBR/THR/IER/IIR/FCR/LCR/MCR/LSR/MSR/SCR in the canonical
  byte offsets). Wire its TX / RX to the USB-Blaster via the
  same JTAG UART IP we currently use — only the memory-mapped
  layer becomes 16550. DT compatible = `"ns16550a"`.

- **T-LI3. RISC-V CLINT.** `src/Riski5/Clint.hs` — `mtime`,
  `mtimecmp[0]`, `msip[0]` at the standard layout. Replaces
  firmware's `delayCycles` busy-waits with timer interrupts.
  DT compatible = `"sifive,clint0"`.

- **T-LI4. Avalon-MM bus adapter.** Convert our custom bus to
  Avalon-MM semantics so Altera's JTAG UART IP, SDRAM
  controller, and (eventually) DM9000 bridge plug in without
  a translation layer.

- **T-LI5. DM9000 Ethernet wrap.** The DE2 carries a Davicom
  DM9000A 10/100 MAC+PHY on a parallel 16-bit bus (confirmed
  from `docs/de2/DE2_Schematic.pdf`). Our hardware side: pin
  assignments, memory-mapped INDEX + DATA registers, `ENET_INT`
  pin into the PLIC. Zero Linux driver work —
  `drivers/net/ethernet/davicom/dm9000.c` binds by DT
  `compatible = "davicom,dm9000"`.

- **T-LI6. Device tree.** `docs/dts/riski5.dts` describes the
  full SoC memory map + interrupts + CPU + PLIC + CLINT for
  the Linux kernel to bind against.

**Starting pointer: retry `core` refactor directly on master with
the above test-side fixes prepared first, so the build never goes
red. `pre-autosquash-backup` branch preserves this phase-1 end
state.**

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
