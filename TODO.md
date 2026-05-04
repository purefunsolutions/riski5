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

- **Multi-PLL three-domain SoC split.** Plan at
  [`.claude/plans/glistening-skipping-thacker.md`](./.claude/plans/glistening-skipping-thacker.md).
  Goal: replace the single 40 MHz domain with three separate PLLs
  driving DomBus / DomCore / DomSdram, each tunable to its own
  rate. Two CDC bridges (DomBus↔DomSdram, DomCore↔DomBus) carry
  Avalon-MM-shaped traffic across the boundaries via toggle
  handshakes. Architectural goal: SDRAM controller at the chip's
  rated 133 MHz spec without dragging the bus + core up; CPU at
  whatever Quartus closes timing on independently. Tracked
  sub-tasks #40 (Phase A), #41 (Phase B), #42+#45 (Phase C),
  #43 (Phase D), #44 (Phase E).
  - **Phase A ✓ Riski5.Domains module + import refactor**
    (**LANDED 2026-05-03**, commit `062b53e`). Three new domain
    aliases — `DomBus` (default 25_000 ps = 40 MHz), `DomCore`
    (default identical to DomBus, splits in Phase D), `DomSdram`
    (default 7500 ps = 133.33 MHz nominal, dropped to 50 MHz on
    silicon for Phase C — see below). Each period is
    CPP-overrideable via `-DSOC_BUS_PERIOD_PS=...` /
    `SOC_CORE_PERIOD_PS=...` / `SOC_SDRAM_PERIOD_PS=...`. Pure
    type-level scaffolding — no behaviour change.
  - **Phase B ✓ CDC bridge libraries** (**LANDED 2026-05-03**,
    commits `57a346a` + `d21a0dc`). Three new modules:
    - `Riski5.Cdc` — `syncBit`, `syncBitVector`, `edgeDetect`
      primitives wrapping `Clash.Explicit.Synchronizer`'s
      `dualFlipFlopSynchronizer`.
    - `Riski5.SdramCdcBridge` — toggle-handshake bridge
      between DomBus-side `Riski5.Sdram.sdram` adapter and
      DomSdram-side `Riski5.SdrController`. Master FSM
      (M_IDLE → M_BUSY → M_DONE_R/W → M_IDLE), slave FSM
      (S_IDLE → S_REQ → S_AWAIT_VALID → S_DONE → S_IDLE),
      43-bit packed quasi-static payload, 16-bit captured
      rdata. Reference: `sim/riski5_sdram_cdc_bridge.v`.
    - `Riski5.CoreCdcBridge` — analogous bridge for
      DomCore↔DomBus carrying combined `CoreBusReq` (101
      bits) / `CoreBusReply` (69 bits) records covering both
      ifetch + data ports + stall flags. Used in Phase D.
    Both bridges include `*CdcBridgeTied` zero-overhead
    passthroughs for the case where source and destination
    are electrically the same clock (sim helpers, initial
    multi-PLL silicon where one rate matches another).
  - **Phase C ✓ SDRAM domain split — silicon validated**
    (**LANDED 2026-05-03**, commits `15968fd` `a3f1e6c`
    `1cc057f` `6d7a1b2` `727a5a9` `13cdd2a`). Six commits
    iterating on:
    1. **Initial three-PLL wiring** (`15968fd`) — `app/Top.hs`
       gains CLOCK_SDRAM/RESET_SDRAM_N input ports;
       SDRAM_DQ_IN + all SDRAM_*_OUT ports re-typed to
       `Signal DomSdram`. SdrController call wrapped in
       `withClockResetEnable clkSdram rstSdram enableGen`
       and fed by the bridge instead of by sdramBusS directly.
       package.nix grows `pllSdramMultBy` / `pllSdramDivBy`
       parameters and a second `u_altpll_sdram` Verilog
       instance with two outputs (clkSdram + clkDramOut +90°).
       Riski5.qsf wires DRAM_CLK to clkDramOut. New
       `sdramClockHz :: Int` constant in Top.hs CPP-controlled
       via `-DSOC_SDRAM_CLOCK_HZ=...` so the SdrController's
       refresh + init NOPs scale to the actual SDRAM rate.
    2. **SDC false-paths working** (`a3f1e6c`) — first silicon
       build hit two issues: Quartus's PLL allocator merged
       both PLLs into a single physical Cyclone II PLL block
       under the name `u_altpll_sdram`, breaking the original
       `u_altpll_bus|pll|clk[0]` SDC patterns; and the chip-
       input timing on DRAM_DQ couldn't close at 133 MHz.
       Switched the SDC to a `foreach_in_collection [all_clocks]`
       runtime classifier by period, added explicit dram_clk
       false-paths for the wrapper Verilog's bus-domain debug
       captures, tightened DRAM_DQ input_delay from 6.0/2.0 to
       5.4/2.0 ns (matches IS42S16400-7TL's t_AC spec without
       the DE2-overconservative 0.5 ns trace allowance), and
       dropped pllSdramMultBy from 8 to 5 (133 → 50 MHz). Result:
       all three clocks meet timing — clkBus +3.166 ns, clkSdram
       +0.040 ns, dram_clk +8.112 ns.
    3. **Silicon CoreMark on multi-PLL** (`1cc057f`) — flashed
       riski5-core-coremark variant: 46 iter/sec, 1.15 CMs/MHz,
       "Correct operation validated". Slightly **better** than
       the prior single-PLL baseline of 44.57 / 1.114 because
       SDRAM is now 1.25× the prior rate (50 vs 40 MHz). This
       proves the CDC bridge works correctly under the real
       SDRAM traffic CoreMark generates.
    4. **Silicon Linux DTB upload corrupted** (`6d7a1b2`) —
       boot-linux-master uploaded the DTB through
       JTAG-Avalon-Master and the verify failed: upper 16 bits
       of every 32-bit DTB word came back as 0xffff (chip's
       POR state for unwritten cells), lower 16 intact. The
       SECOND of every back-to-back chip half-word write was
       being silently dropped by my CDC bridge.
    5. **CDC bridge back-to-back fix** (`727a5a9`) — root cause:
       the master FSM's MDoneR/MDoneW → MIdle transition
       didn't check for a fresh `sibCs` even though Avalon-MM
       lets the master assert a new request the same cycle
       waitrequest first goes low (which is the MDoneR/W
       cycle in this FSM). Riski5.Sdram's 32→16 splitter
       does exactly that for the second half-word. Fix:
       extend MDoneR/W to accept new cs and re-enter MBusy
       directly. Also moved the `mValid=True` pulse from the
       MDoneR→MIdle transition to the MBusy→MDoneR transition
       so valid+!waitrequest fire on the same cycle per
       Avalon spec. Same bug exists in the now-vestigial
       Verilog reference at `sim/riski5_sdram_cdc_bridge.v`.
    6. **Silicon Linux upload + boot success** (`13cdd2a`) —
       re-flashed multi-PLL linux-master with the fix:
         verify-all dtb:    379 / 379 words OK
         verify-all kernel: 796215 / 796215 words OK
         Trigger written, kernel JRs to 0x80000000
       Kernel printk reaches the **same point as 30 MHz
       slowClock baseline** (sched_clock setup) — but with
       CPU at full 40 MHz instead of 30 MHz. Multi-PLL
       infrastructure has matched the slowClock improvement
       without slowing the CPU. The remaining post-sched_clock
       hang is the pre-existing tasks #35 / #36 issue,
       unrelated to multi-PLL. Log:
       [`docs/perf/linux-multipll-cdcfix-2026-05-03.log`](./docs/perf/linux-multipll-cdcfix-2026-05-03.log).
  - **Phase D-1 ✓ u_altpll_core PLL infrastructure**
    (**LANDED 2026-05-03**, commit `c71b8d9`). Third PLL
    instance, currently produces clkCore at the same rate as
    clkBus.
  - **Phase D-2 ✓ Soc.hs core/bus split via socWithExternalCore**
    (**LANDED 2026-05-03**, commit `5ccde32`). New
    `socWithExternalCore` function exposes `CoreBusReq` /
    `CoreBusReply` at the boundary; `app/Top.hs` instantiates
    `coreWith` in DomCore and bridges to DomBus via
    `coreCdcBridge`.
  - **Phase D-3 ✓ silicon bridge-corruption RESOLVED**
    (commit `0c1b195`, 2026-05-04). The 12-clean-then-corrupted
    aexttest pattern was caused by the prior `a73ec47` `cbrDBe=0
    in SServe` "fix" that ran SRAM/SDRAM adapters' multi-cycle
    transactions short. Reverted: bridge holds the FULL request
    through SDrive+SServe; sim's apparent UART doubling
    (`jtagUartSim` doesn't model the IP's waitrequest-pulse
    serialisation) is a sim-only artefact, real silicon
    naturally serialises commits. Verified silicon: aexttest
    produces **294,950 clean BLSAX iterations in 10 s** with
    zero corruption. Bridge IS rock-solid for atomics + UART.

  - **Phase D-3a ✓ silicon SDRAM-via-chained-bridges RESOLVED for
    amostress** (2026-05-04). Root cause was NOT
    `SdramCdcBridge` reqEdge loss (that hypothesis disproved by
    the `sPendingEdge` fix landing zero silicon improvement) — it
    was `Riski5.CoreCdcBridge` slave holding the FULL latched
    `sLatReq` through SServe while waiting for both `cbrStall`
    and `cbrDataStall` to drop simultaneously. When IF and DATA
    both target SDRAM (amostress inner loop runs from SDRAM with
    cross-row data SWs), `Riski5.Sdram.sdram`'s data-priority
    arbiter kept re-issuing the held data SW indefinitely → IF
    starved → `cbrStall` stayed True forever → bridge deadlocked.
    Two-part fix in `src/Riski5/CoreCdcBridge.hs`:
    - **Slave: per-port done tracking + data-port mask.** New
      `sDataDone` / `sImemDone` / `sImemRdata` / `sDmemRdata`
      fields latch each port's first-completion edge and the
      response payload at that cycle. Once `sDataDone` latches,
      `reqOutB` masks `cbrDBe`/`cbrDRen`/`cbrDWdata` to 0 so
      `Riski5.Sdram.sdram` sees `dataSel=False` and finally
      serves the IF stage. Final `sCapReply` carries the merged
      response (correct imem rdata + dmem rdata regardless of
      completion order).
    - **Master: `cbrDBe`/`cbrDRen` rising-edge re-fire.** AMO FU
      holds the same PC across `AmoRead` (cbrDRen=True, cbrDBe=0)
      and `AmoWrite` (cbrDRen=False, cbrDBe=0xF) — only the dBe
      transition signals the new bus operation. New `mLastDBe` /
      `mLastDRen` master-state fields make `reqIsLive` fire on
      `(lastDBe==0 && currentDBe/=0)` or `(not lastDRen && currentDRen)`
      in addition to the PC-change check. Without this, AMO's
      write phase silently never commits to memory.
    Both halves needed: without the slave mask, IF starves;
    without the master edge, AMO writes are silently dropped.
    Silicon verified: `riski5-core-amostress` produces continuous
    `..............DB...........DB...` (64 dots per inner-loop
    iteration + 'D' end-of-loop + 'B' BRAM-bootstrap restart),
    indefinitely with zero failures. aexttest, hello, sdramexec
    all still work.
  - **Phase D-3b — CoreMark variant silicon hang persists**
    (NEW sub-task). With the Phase D-3a fix landed, all SDRAM-
    touching variants work, but `riski5-core-coremark` still
    produces zero UART output within 60 s. CoreMark uses BRAM
    (text + rodata + .data LMA) and SRAM (.bss + stack + .data
    VMA) only — never touches SDRAM — so the Phase D-3a fix
    doesn't help. The hang predates the Phase D-3a fix (was
    visible from commit `0c1b195` onwards). Same root-cause
    pattern as Phase D-3a is unlikely (no SDRAM contention),
    suggesting either (a) the BSS zero loop in `start.S`
    triggers a different bridge corner case under the bridge's
    CDC latency × 2500-iteration scale, (b) a Quartus place-
    and-route issue specific to the CoreMark bitstream's
    larger .text section, or (c) the C-runtime `_start` /
    `main()` path interacts with the bridge differently than
    the handwritten Asm firmwares do (e.g. function-call
    sequence, prologue/epilogue stack ops). Concrete next
    steps:
    - Add a single putchar('X') very early in `start.S` (before
      BSS zero, before any SRAM touch) to confirm the bridge
      delivers BRAM-IF-only fetches at the C-runtime path.
    - If putchar fires: bisect by inserting putchar between BSS
      zero, .data copy, and `jal main` to localise which step
      hangs.
    - If putchar doesn't fire: investigate Quartus place-and-
      route differences (`reports/Riski5.fit.rpt` LE/M4K vs
      working variants).
  - **Phase E — multi-domain test + hwsim updates**
    (queued as task #44). New `test/CoreCdcSpec.hs` +
    `test/SdramCdcSpec.hs` with non-equal clock periods using
    `Clash.Explicit.Prelude.tbClockGen`. Verilator hwsim
    wrapper at `pkgs/riski5-sim/verilog/riski5_sim_top.v`
    grows `clk_core` + `clk_sdram` input ports alongside the
    existing `clk` for true multi-clock simulation; the
    harness in `tools/linux-hwsim/Main.hs` ticks each at its
    own configured period.

- **Linux-on-riski5 — Path A (nommu, M-mode).** Plan in
  [`docs/linux-boot.md`](./docs/linux-boot.md) v2. Goal: boot a
  minimal upstream Linux kernel + initramfs via JTAG-load to SDRAM,
  print a banner over the JTAG UART. Tracked sub-tasks L-0..L-9.
  - **L-0. ✓ CLINT to SiFive layout @ 0x0200_0000**
    (**LANDED 2026-04-28**, commit `5937d3f`). `Riski5.MemMap.clintBase`
    moves to the upstream-recognised slot; `Riski5.Clint` register
    layout matches the SiFive CLINT v0 (msip @ 0x0000, mtimecmp @
    0x4000, mtime @ 0xBFF8); decoder grows a `classifyLowMem`
    sub-decode (top4=0x0 splits BRAM vs CLINT on bits[27:24]).
    `firmware/phase1/HelloTimerIrq.hs` updated. CoreMark stable at
    44.57 / 1.114 (CoreMark firmware never touches CLINT).
    261/261 cabal tests green. Foundation for the DT
    `compatible = "sifive,clint0"` binding the Linux clocksource
    driver expects.
  - **L-1. ✓ JTAG-UART IRQ end-to-end + sync-register fix**
    (**LANDED 2026-04-28**, commit `dd24486`). New `UART_IRQ`
    input port on `app/Top.hs::topEntity`; `riski5_top.v` connects
    the IP's `av_irq` output to that port. **Hardware fix
    landed alongside the wiring**: a one-cycle synchronizer
    register `uartIrqRegS = register False (siUartIrq <$> inS)`
    sits between the IP's IRQ output and the PLIC's pending
    vector. Without it, feeding `av_irq` (which is asserted
    at boot whenever the IP's TX FIFO has space — default
    behaviour) directly into the PLIC's combinational
    pending-and-arbitrate cone produced a Quartus place-and-route
    shift (10,136 LE → 10,258 LE) that broke BRAM fetches —
    silicon hung at boot before printing any UART output across
    three confirmed builds. The synchronizer cuts IP-IRQ fan-out
    to one register input; CoreMark recovers to 44.57 / 1.114,
    identical baseline. Standing rule for future peripheral
    IRQs joining `plicExtIrqsS`: register at the SoC boundary,
    never combinationally feed an IP signal into the PLIC tree.
  - **L-2. ✓ deferred** — the plan's "4 KB → 16-32 KB" title was
    based on a misreading of `ProgSize`. Current `ProgSize = 4096`
    words = 16 KB BRAM, already enough for any reasonable boot
    stub (< 1 KB). A bump attempt to 8192 hit Quartus II 13.0sp1's
    hard-coded 5000-iteration loop limit on the imem initialiser
    (`Error 10106`); the assignment that lifts this in later
    Quartus versions doesn't exist in 13.0sp1. If we ever need
    >16 KB BRAM, the path is MIF-backed init (`.mif` file +
    `RAMSTYLE = "M4K"` attribute) — but phase-2 Linux only needs
    the boot stub in BRAM, so this stays deferred. See
    [docs/linux-boot.md](./docs/linux-boot.md) §L-2 for the
    full reasoning.
  - **L-3a. ✓ SoC-internal JTAG-load mux + Top.hs ports**
    (**LANDED 2026-04-28**, commit `61f7c22`). New
    `siJtagLoad{Mode,Addr,Wdata,We,Rd}` fields on `SocIn`;
    `jtagMuxedSdram` overrides the riski5 core's bus signals
    into `Riski5.Sdram.sdram` when `siJtagLoadMode = True`.
    Future-ready integration point for option A
    (Altera JTAG-Avalon-Master IP) — see
    [docs/linux-boot.md](./docs/linux-boot.md) §L-3.
    CoreMark stable.
  - **L-3b. ✓ JTAG-UART → SDRAM firmware loader (option B)**
    (**LANDED 2026-04-28**, commit `5c890cd`). New
    `firmware/phase1/SdramLoader.hs` (39 words): polls JTAG-UART
    RX, assembles 4 bytes → word, writes to SDRAM, JALRs.
    `riski5-core-sdramload` Nix variant + `flash-riski5-sdramload`
    app + `scripts/load-sdram-jtag.sh`. ~100 KB/s throughput
    over JTAG-UART (~80 s for 8 MB Linux). Multi-bit
    altsource_probe sources don't work on Quartus 13.0sp1
    (option A blocker), so option B firmware loader is the
    working baseline.
  - **L-4. ✓ Device tree + DTB build**
    (**LANDED 2026-04-28**, commit `91219a2`). New
    `firmware/phase2/dts/riski5.dts` — declares CLINT @
    0x02000000, PLIC @ 0x40000000 (riscv,ndev=8), Altera
    JTAG-UART @ 0x10000000 routed to PLIC source 1, 8 MB SDRAM
    @ 0x80000000, 40 MHz timebase. earlycon points at the same
    JTAG-UART tap nios2-terminal listens on. New
    `pkgs/riski5-dtb/package.nix` invokes `dtc` to produce a
    1.5 KB DTB.
  - **L-5. ✓ riscv32-linux cross-toolchain in devshell**
    (**LANDED 2026-04-28**, commit `865f9d8`). Added
    `pkgsCross.riscv64.buildPackages.gcc` — single toolchain
    builds rv32 binaries with `-march=rv32ima -mabi=ilp32`.
    Verified: `int main(){return 0;}` → elf32-littleriscv with
    canonical RV32I prologue.
  - **L-6. ✓ Linux 6.18.22 kernel build**
    (**LANDED 2026-04-28**, commit `e18e242`). New
    `pkgs/linux-rv32-nommu/{package.nix,riski5-overlay.config}`.
    Layers nommu_virt_defconfig + 32-bit.config + riski5
    overlay (Altera JTAG-UART driver, SiFive PLIC + RISC-V
    timer bindings, aggressive size cuts). Recipe-only commit;
    actual kernel build is slow (~5 min) and on-demand.
  - **L-7 + L-8. ✓ BFLT /init + minimal cpio initramfs**
    (**LANDED 2026-04-28**, commit `6776352`). New
    `firmware/phase2/init-rv32-nommu/init.S` — two-stage
    hello (direct MMIO write + write(1, ...) syscall + exit).
    `pkgs/init-rv32-nommu/` cross-compiles + wraps in a
    64-byte BFLT v4 header (Python script
    `build_init_bflt.py`). `pkgs/initramfs-rv32-nommu/`
    builds a 1024-byte newc cpio with `/init` + empty
    `/proc /sys /dev`.
  - **L-9. ✓ Linux silicon-bring-up bitstream + apps**
    (**LANDED 2026-04-28**, commit `443ab4a`). New
    `firmware/phase1/LinuxBoot.hs` (58 words) — combined
    SDRAM-loader + RISC-V Linux boot-protocol jumper. Reads
    kernel + DTB blobs from JTAG-UART, writes to SDRAM,
    sets up `a0=0`, `a1=&dtb`, `sp=top of SRAM`, JALRs to
    `0x80000000`. `riski5-core-linux` Nix variant +
    `flash-riski5-linux` app + `scripts/load-linux.sh`.
    CoreMark stable at 44.57 / 1.114.
  - **Path-A stack feature-complete.** Silicon validation is
    now a workflow:
    1. `nix build .#riski5-dtb`
    2. `nix build .#linux-rv32-nommu` (slow, ~5 min)
    3. `nix run .#flash-riski5-linux`
    4. `scripts/load-linux.sh result/Image result-dtb/riski5.dtb`
    5. Watch nios2-terminal for: `'L'` → `'D'` → kernel banner.

- **#133. JTAG-Avalon-Master — Clash bridge replacing the buggy
  Altera state machine.** [started 2026-04-29] The Altera
  `altera_avalon_packets_to_master` component inside
  `altera_jtag_avalon_master` silently drops 50–75 % of master
  writes during high-rate JTAG bursts (silicon-verified by the
  L-3b sentinel test in `firmware/phase1/LinuxBootMaster.hs`;
  see [`memory/project_avalon_master_state.md`](./.claude/projects/-home-mika-riski5/memory/project_avalon_master_state.md)).
  Per CLAUDE.md "fix at hardware layer" policy, replace the
  state machine in Clash, keeping the surrounding glue
  (`altera_jtag_dc_streaming`, `sc_fifo`, `bytes_to_packets`,
  `channel_adapter`, `packets_to_bytes`) stock-Altera.
  - First cut: `src/Riski5/JtagAvalonMaster.hs` (Clash module
    `riski5_jtag_avalon_master`) — re-implements the FAST_VER=0
    "slow path" packet-to-master state machine in 16 phases.
    Domain-polymorphic Moore FSM; outputs registered. Compiles
    cleanly through `cabal build` and `clash --verilog`.
  - Verilog shim
    `pkgs/riski5-core/altera-ip/jtag-master-shim/altera_avalon_packets_to_master.v`
    re-exports our Clash module under the original Altera name
    + parameter list so the IP composition wrapper from
    `ip-generate altera_jtag_avalon_master` instantiates it
    transparently.
  - `pkgs/riski5-core/package.nix` runs a second `clash --verilog`
    pass on `Riski5.JtagAvalonMaster` and excludes the original
    `altera_avalon_packets_to_master.v` from the QSF
    `VERILOG_FILE` list.
  - Validation 2026-04-29: bridge counters confirm the FSM
    accepts every byte and commits every write at the master
    interface (bytes_in_cnt = 10,509,860, writes_commit_cnt =
    873,541 ≈ expected 873,533). Yet silicon SDRAM cells still
    held the pre-upload sentinel at ~85 % of sample addresses
    — the bridge replacement alone did NOT fix the bug. The
    `nix run .#jam-counter-probe` app + the diagnostic
    altsource_probe wiring inside the shim are the load-bearing
    diagnostic that pinpointed the residual path.
  - **Sticky-arbiter fix (2026-04-30)** — task #133's
    bridge-side work is correct; the residual writes were
    being corrupted downstream at the SoC bus mux. New
    `JtagMuxOwner` enum + `nextJtagMuxOwner` register in
    `Riski5.Soc` (`jtagMuxOwnerS`) only re-picks ownership on
    `sdramRawReadyS` edges, so the JTAG-Master mux can't flip
    mid-transaction. Silicon dump now shows **8 / 8** sample
    addresses match the actual kernel bytes (vs 1 / 7 before).
    Build cost +152 LE (11,602 / 33,216), Fmax 53.1 MHz at
    40 MHz. 261 / 261 cabal tests green. **Linux boot post-
    JR-to-kernel still hangs silently** (separate debug —
    likely residual partial-write at some unsampled cell or
    DTB-related; see
    [`memory/project_avalon_master_state.md`](./.claude/projects/-home-mika-riski5/memory/project_avalon_master_state.md)
    for next-action notes).
  - **SDRAM IP timing investigation (task #141, started 2026-04-30,
    in progress)** — the silicon Linux hang at PC=0x80000108
    immediately after an `amoadd.w` writes one SDRAM row and the
    next IF fetch reads from a different row points at the
    Altera SDRAM Controller IP's back-to-back ACTIVATE /
    PRECHARGE / ACTIVATE sequence not getting enough wall-clock
    time per command. Two layers of work:
    1. **Naming + clockRate fix (LANDED commit `f4132f2`,
       2026-04-30).** Renamed `Dom30 → DomSys`, `clk30 → clkSys`,
       `clk30_dram → clkSdramOut`, `rst30_n → rstSys_n`, port
       `CLOCK_30 → CLOCK_SYS`, `RESET_30_N → RESET_SYS_N`. Fixed
       the dangling `clockRate=30000000` on the SDRAM IP (it had
       been left over from before the phase-2 PLL retarget — the
       IP was computing its internal cycle counts as if it were
       running at 30 MHz while actually running at 40 MHz, which
       made @powerUpDelay@ undershoot 100 µs by 25 µs and ran
       refresh every 11.7 µs instead of the spec's 15.625 µs).
       Rename only — no behaviour change beyond the SDRAM-IP
       parameter recalibration. 261/261 cabal tests green.
    2. **slowClock Nix flag (LANDED commit `1456737`,
       2026-04-30).** New `slowClock ? false` parameter on
       `pkgs/riski5-core/package.nix` that drops the entire
       design from 40 MHz to 30 MHz uniformly (PLL ratio
       50×4/5 → 50×3/5) and regenerates the SDRAM IP with
       `clockRate=30000000`. Single domain, no CDC, no second
       PLL. Cheapest experiment for the timing hypothesis.
       Build verified: 24.4 ns slack at 30 MHz vs 16.5 ns at
       40 MHz, plenty of margin either way.
    3. **Silicon test of slowClock — RESULT NEGATIVE (2026-04-30).**
       Ran `nix run .#boot-linux-master-slow` end-to-end. Boot
       stub printed its full diagnostic-marker sequence
       (M / J / K / 4-cell dump) exactly like the 40 MHz
       baseline, then JR'd to 0x80000000, then **no kernel
       earlycon output ever appeared** — identical hang
       signature to the 40 MHz path. SDRAM-IP-timing hypothesis
       falsified.
    4. **Multi-PLL with async-FIFO Avalon-MM bridge — DROPPED
       FROM CRITICAL PATH.** Since the slow-clock proxy
       (which gives the IP a strict superset of the timing
       relaxation a multi-PLL split would provide) didn't
       unstick the hang, the multi-PLL bridge wouldn't help
       either. Architectural design captured in
       [`docs/multi-pll-sdram-design.md`](./docs/multi-pll-sdram-design.md)
       for future reference; not implemented now.
    5. **Next: SDRAM hang diagnostics (task #142 created).**
       altsource_probe SLD nodes for SDRAM IP signals
       (waitrequest, za_valid, za_data) + Sdram adapter state
       + sticky-arbiter ownership at the freeze-on-hang
       trigger, so we can read via quartus_stp whether the
       IP itself is hung or the adapter / arbiter is stuck
       waiting for it.

- **A-extension (RV32A) — phase-2 opener.** First arc of phase 2.
  Landed **2026-04-27** in 4 commits (`3cd088d`, `fa34d9e`,
  `229e6a2`, `4bfb809`): ISA + encode + decode + Asm builders +
  Reference executor (with `reservation :: Maybe Addr`) +
  `Riski5.Core.FU.Amo` (4-state mealy FSM with reservation as
  internal state) + bus muxing in `Riski5.Core` + 12 differential
  CoreSpec cases vs the Reference oracle, all green.
  - **T-A-ext-5. ✓** Silicon firmware demo
    (**LANDED 2026-04-27**). `firmware/phase1/HelloAExt.hs` +
    `riski5-core-aexttest` Nix variant + `flash-riski5-aexttest`
    app. JTAG-UART stream on real DE2: `BLSAXBLSAX…` repeating
    cleanly — boot / LR.W / SC.W success / AMOSWAP / AMOADD all
    retiring against the SRAM controller. Forced a `slaveReadyS`
    refinement on `Riski5.Core.FU.Amo` (gates Read / Write phase
    transitions on `not <$> stallS`) so the FU's multi-cycle FSM
    works against multi-cycle SRAM accesses; without this gate the
    FU would advance on every clock and capture stale rdata mid-
    SRAM-transaction.

- **CLINT — phase-2 timer-interrupt source.** Slot reserved at
  `0x1000_0060..0x1000_009F` per `Riski5.MemMap`. Two pieces, both
  landed **2026-04-27** in `229e6a2` and `4bfb809`:
  - **T-CLINT-1. ✓** `src/Riski5/Clint.hs` — 64-bit free-running
    `mtime`, 64-bit `mtimecmp`, 32-bit reserved `msip`. Memory-
    mapped at `clintBase` with one-cycle synchronous-write +
    combinational-read semantics. `mtipS` strobe flows out of
    `SocOut.soMtip`. Three `ClintSpec` sim tests pin
    increment / write / threshold-crossing.
  - **T-CLINT-2. ✓** `Riski5.CSR` grew `cMie` + `cMip` fields, an
    `applyMret` that restores `MIE` from `MPIE`, and an
    `interruptPending` predicate gating on `MIE && MTIE && MTIP`.
    `applyTrap` now does the priv-spec MIE → MPIE save. `core`
    takes a new `mtipS` parameter that gets folded into
    `cMip.MTIP` each cycle; `handleInstr` consults
    `interruptPending` before dispatch and traps to `mtvec.base`
    with cause `0x8000_0007` when pending. New `TimerIrqSpec`
    integration test demonstrates handler entry. CoreMark stable
    at 44.57 / 1.114 — pre-emption check is dead logic on the hot
    loop because firmware never enables `MIE`.
  - **T-CLINT-3. ✓** Silicon firmware demo
    (**LANDED 2026-04-27**). `firmware/phase1/HelloTimerIrq.hs` +
    `riski5-core-timerirqtest` Nix variant +
    `flash-riski5-timerirqtest` app. JTAG-UART stream on real DE2:
    `B…………T…………T…………T…` — boot byte then `.`-runs separated by
    handler-emitted `T`s, exactly the cadence the
    `mtimecmpIncrement = 4_000_000` (≈100 ms at 40 MHz) buys.
    Demonstrates the full `mtipS → mip.MTIP → interruptPending →
    trap → handler → mtimecmp re-arm → mret → main` chain on real
    hardware; no surprises vs sim.

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
  - **CM-5. ✓ UART back-to-back-write regression test
    (2026-04-24).** New `Riski5.JtagUart.jtagUartAlteraSim` models
    the Altera IP's 64-byte FIFO + drain-gap contract: writes
    only accept while FIFO has space, and drain only advances on
    cycles without an active write transaction. New
    `Riski5.Soc.socSimAlteraUart` plumbs the model's waitrequest
    back through `siUartReady` so the core stalls naturally on
    back-pressure. Two cases in
    [`test/UartBackpressureSpec.hs`](./test/UartBackpressureSpec.hs):
    80 unrolled `sw` writes without a WSPACE poll stall at byte
    64 (deadlock reproduces); 80 writes with a WSPACE poll all
    land (fix demonstrably fixes it). 149 / 149 `cabal test`
    green.

## Next up

- **SDRAM-execution — silicon multi-byte residual (FIXED
  2026-04-27, commit `1bd7a41`).** The visible "multi-byte"
  pattern was __FIFO overflow drops biased by timing__, not a
  master-side multi-commit bug. Root cause: the firmware loops
  at ~2.2 MB/s but nios2-terminal drains at ~36 KB/s, so ~96 %
  of bytes overflow the JTAG-UART IP's 64-byte FIFO; @S@ writes
  happen ~150 cycles after @B@ within an iteration, so the
  FIFO has time to drain one byte and @S@ writes are slightly
  more likely to find space than @B@ writes — producing the
  1.66:1 visible @S@:@B@ ratio.

  __How we got there__ (full picture in commit message of
  `1bd7a41`): added a SignalTap-equivalent freeze-on-trigger
  capture FSM in @Riski5.Soc@, exposed via wide
  altsource_probes (`FRZP` 128-bit, `FRZF` 32-bit, `CAPR`
  re-arm). The 4-cycle waveform confirmed the master-side
  @uartAcceptedS@ latch engages exactly 1 cycle after the
  trigger as designed. Wrapper-side IP-commit (`CMTC`) and
  iteration (`ITRC`) counters then nailed the answer:
  @CMTC@:@ITRC@ ratio is __exactly 2.000__ — the IP commits 1
  @B@ + 1 @S@ per iteration, architecturally correct. The
  multi-byte was post-IP, in FIFO drop bias.

  __Fix__: WSPACE polling before each @sw@ to UART, same
  pattern CoreMark applies (CM-4). Implemented for both the
  BRAM-resident @B@ side (using `Riski5.Asm`) and the
  SDRAM-resident @S@ side (hand-encoded). Silicon now shows a
  clean `BSBSBSBS…` byte stream over 12-second captures —
  217,154 / 217,219 = 99.97 % length-1 @B@ runs, 217,217 /
  217,219 = 99.999 % length-1 @S@ runs, ratio 1:1.0003. SDRAM
  execution working end-to-end.

  __Tooling left in place__: the freeze-on-trigger FSM, the
  `FRZP` / `FRZF` / `CAPR` probes, the `CMTC` / `ITRC`
  counters, and `scripts/freeze-trigger-probe.tcl` are kept in
  every bitstream variant for future debugging. The
  source-driven `OFFS` mux probe is kept for completeness but
  unused — multi-bit altsource_probe sources don't propagate
  reliably through Quartus 13.0sp1's JTAG hub on this design,
  so the wide-probe approach (read all 4 captured cycles in
  one transaction) is the working pattern.

- **Hardware-side WSPACE polling — `Riski5.JtagUartAdapter` (LANDED
  2026-04-27, commit `6098f76`).** The firmware-side WSPACE poll
  in `1bd7a41` worked but was a workaround at the wrong level —
  every UART-using firmware variant had to know about the IP's
  bug and burn 3+ instructions per byte polling the CONTROL
  register. New `Riski5.JtagUartAdapter` Clash module wraps the
  Altera IP with a "polite" Avalon-MM proxy: tracks a 7-bit
  @freeBytes@ counter (init 64), holds the master with
  @waitrequest=1@ when @freeBytes==0@, polls the IP at the bus
  rate while held to detect drain, releases the master when a
  slot opens. Master-side firmware now sees standard Avalon-MM
  semantics — back-to-back @sw@s to the UART data register just
  work.

  Implementation notes:
   - Per-byte commit detection uses the falling edge of
     @mIsDataWriteS@ (the cycle after @uartAcceptedS@ engages),
     which is reliable across both the Altera-IP-faithful sim
     (combinational @ipReady@) and silicon (toggle protocol).
     CMTC=2.000/iter on silicon (verified pre-adapter via the
     freeze-trigger probes) confirms the SoC's existing
     @uartAcceptedS@ gate produces exactly one IP commit per
     master assertion, so the falling edge is a lossless event
     stream.
   - @JaIdle@-with-@masterHeld=True@ also gates the @ipBus@ to
     idle (not just signals @waitrequest=1@ to the master) — the
     master's combinational bus signals would otherwise still
     reach the IP for one cycle before the @JaPoll@ transition,
     producing a "phantom" commit the adapter doesn't track.
   - WSPACE-validity in @JaPoll@ uses a level + cycle-count gate
     (@ipReady && pollCnt >= 1@) rather than an
     @ipAcceptS@-rising-edge: the rising-edge approach works
     against silicon but not against the combinational
     @jtagUartAlteraSim@ (which never toggles @ipReady@).

  Silicon verification (12-second JTAG-UART capture of
  `riski5-core-sdramexec` post-adapter): __1.19 M bytes at
  594,911 length-1 B-runs / 594,913 length-1 S-runs__ — 3
  multi-byte anomalies total (1 BB, 1 BBB, 1 SS, all clustered
  near startup). 0.00025 % anomaly rate vs 1bd7a41's 0.03 %
  with firmware-side polling. Adapter is strictly tighter on
  silicon than the firmware-side workaround.

  `firmware/phase1/HelloSdramExec.hs` simplified accordingly:
  the hand-encoded WSPACE-poll preamble in the SDRAM-resident
  routine is gone, the BRAM-side @B@-write loses its 3-instr
  poll, and the firmware reads as the architectural intent
  (just @sw@s, no MMIO-protocol kludges). CoreMark unchanged
  (44.57 / 1.114 — adapter doesn't sit on the CoreMark hot
  loop). UartBackpressureSpec polled-FIFO test passes through
  the adapter in CI.

## Next up

- *(currently nothing pending — phase 1 SDRAM-exec arc is
  silicon-clean; phase 2 work is broad and lives in
  [docs/core-family.md](./docs/core-family.md))*

- **SDRAM-execution architectural gap — FIXED in sim
  (2026-04-26).** Phase 1D closed end-to-end SDRAM data access
  (T39: SW + LW round-trip through the off-chip IS42S16400 via
  the Altera @altera_avalon_new_sdram_controller@ IP, validated
  on silicon with `0xCAFEBABE`). The fetch path was missing —
  `JALR`s to `0x8000_0000+` previously fell back to the BRAM-
  default path via `addrToImemIdx`'s `mod ProgSize` wraparound,
  i.e., garbage instructions. Required for Linux: the kernel
  image lives in SDRAM.

  All six SX sub-tasks landed (commit pending) modelled on the
  SRAM-exec arc:

  - **SX-1. ✓** New `enableSdramFetch :: Bool` constant in
    [`firmware/phase1/FetchPolicy.hs`](./firmware/phase1/FetchPolicy.hs)
    (default `False`); parallel to `enableSramFetch`.
    Compile-time toggle, same Quartus-placement-stability
    rationale.
  - **SX-2. / SX-3. ✓** [`Riski5.Soc.soc`](./src/Riski5/Soc.hs)
    refactored to take both flags. The SRAM block now exposes
    five outputs (rdata + pins + dataReady + fetchData +
    fetchReady) instead of merging the imem mux inline; an
    identically-shaped SDRAM block sits parallel and gates on
    `enableSdramFetch`. A new fetch-mux block at the end is a
    case-of on @(enableSramFetch, enableSdramFetch)@; the
    @(False, False)@ arm is a literal pass-through to the BRAM
    fetch source so Quartus's CoreMark placement is preserved
    bit-identically. The arbiter mirrors the SRAM one's
    stateless data-priority pattern (`SramOwner` reused).
  - **SX-4. ✓ / NOOP.** The `Riski5.Sdram` adapter already
    encapsulates the IP's @az_waitrequest@ behaviour inside its
    own FSM, so the JTAG-UART-style `accepted` latch isn't
    structurally required for the data side — `dataStallS`'s
    `SlaveSdram` case stays as `not sdramDataReadyS`. Comment
    on the SDRAM block flags the latent
    "stateless-arbiter-on-multi-cycle-FSM" race for future
    firmware that overlaps data + fetch on SDRAM (the probe
    avoids it by construction); a registered owner-locked
    arbiter is the right next step there.
  - **SX-5. ✓** New
    [`firmware/phase1/HelloSdramExec.hs`](./firmware/phase1/HelloSdramExec.hs)
    (parallels `HelloSramExec`, but writes encoded
    `sw x14, 0(x10)` + `ebreak` into SDRAM and JALRs there) +
    new [`test/SdramExecSpec.hs`](./test/SdramExecSpec.hs)
    asserting 1 B + 1 S per iteration over 6000 cycles via
    `socSimFullWith False True` (which now takes two flags
    instead of one — argument order:
    `enableSramFetch enableSdramFetch`). 161 / 161 sim tests
    green.
  - **SX-6. ✓** New `riski5-core-sdramexec` Nix variant in
    [`pkgs/default.nix`](./pkgs/default.nix) with parallel
    `flash-riski5-sdramexec` app. The `sdramExec = true`
    parameter to `pkgs/riski5-core/package.nix` overlays
    `CoreMark.hs` to re-export `HelloSdramExec`'s firmware
    bytes and rewrites `FetchPolicy.hs` with
    `enableSdramFetch = True`. `nix eval .#riski5-core-sdramexec`
    produces a valid derivation; full Quartus build (and DE2
    silicon flash) tracked under "Next up" above.

- **SRAM-execution architectural gap — FIXED (2026-04-24).**
  Core's IF stage previously hardwired to a 1-cycle BRAM sync-read;
  jumps into SRAM range wrapped back into BRAM. Now:

  - Core-side IF-stage refactor (commit `c29b776`): new
    `imemReady` input + `pendingS`/`pcFetchHoldS`/`effective*S`
    scheme. Preserves 1-cycle BRAM semantics (CoreMark silicon
    stayed at 44.57 / 1.114 after the refactor alone) while
    unblocking multi-cycle fetch.
  - SoC-side arbiter + fetch-side bus decoder (commit
    `2ba45ac`): stateless data-priority arbiter muxes the
    shared SRAM controller between fetch and data; fetch-side
    bus decoder routes based on pcFetch region.

  __Silicon observed__: `riski5-core-sramexec` runs SRAM-
  resident code; firmware's `sw` at SRAM[0x2000_0000] prints
  'S' through the UART. `riski5-core-coremark` restored to the
  pre-arbiter baseline (44.57 / 1.114 @ 40 MHz) via the
  parameterisation below.

  - Core-side IF-stage refactor (commit `c29b776`, see above).
  - SoC-side arbiter + fetch-side bus decoder (commit `2ba45ac`).
  - **Per-bitstream fetch-policy toggle (commit pending).** New
    `firmware/phase1/FetchPolicy.hs` module exports
    `enableSramFetch :: Bool` (default `False`). `Riski5.Soc.soc`
    now takes it as its first parameter; the SRAM + fetch wiring
    sits inside a compile-time `if enableSramFetch` so the CoreMark
    branch (flag `False`) structurally reduces to the pre-arbiter
    data-only controller inputs — Clash emits identical Verilog
    and Quartus reproduces the CoreMark-validated placement
    exactly. The sramexec bitstream's Nix overlay flips
    `enableSramFetch = True` to turn the arbiter on. CoreMark
    LE count drops from 8,217 → 8,130 (the arbiter muxes are
    truly gone in the disabled branch). Silicon verified:
    CoreMark 44.57 / 1.114 restored; sramexec UART still shows
    `B`+`S` byte interleave confirming SRAM execution.

  __Follow-ups__:

  - **1:3 B:S ratio in `sramexec` — root cause confirmed, fix
    architecturally validated in sim, silicon halt remains
    open.** Investigated 2026-04-25. The extra `S` bytes are
    __not__ a trap-flow issue — they're spurious UART transactions
    caused by the Avalon-MM master holding `dBeOutS` asserted while
    the SW at `SRAM[0]` is stuck in X-stage during the multi-cycle
    SRAM ebreak fetch at `SRAM[4]`. The existing `jtagUartAlteraSim`
    model already commits a byte per cycle the master holds
    `wr=True` with FIFO not full — and once a sim test
    ([`test/SramExecSpec.hs`](./test/SramExecSpec.hs)) loaded
    `HelloSramExec` into `socSimFullWith True`, the bug
    reproduced exactly: 114 iterations of `(1B, 3S)` over 4000
    cycles, mirroring silicon.

    Fix: `dmemAcceptedS` latch in `Riski5.Soc` that flips True
    the cycle after the data slave accepts (=
    `stallS=True && dataStallS=False && memReq=True`) and gates
    `dBeS` / `dRenS` to 0 for the rest of the X-stage tenure,
    with reset on `stallS=False`. Sim test passes (1:1 across
    all iterations). All 160 cabal tests green. CoreMark silicon
    44.57 / 1.114 unchanged.

    **Silicon halt remains, despite three independent fix
    variants on 2026-04-25.** With either the global `dBeS` /
    `dRenS` gating, a wrapper-side mirror in
    `pkgs/riski5-core/package.nix`'s `riski5_top.v`, or the
    surgical UART-only `uartAcceptedS` latch at the bus tap
    (current commit), sramexec silicon prints exactly `BS` and
    halts. Sim loops forever in all three cases. The pattern
    isolates the trigger to "master deasserts wr promptly after
    acceptance" — without any gating the master holds wr through
    the fetch-stall window and the firmware loops with the
    cosmetic 3-S bug.

    **Hang location pinpointed (2026-04-25, late session).** The
    firmware was instrumented with five UART checkpoints:
    @B@ (BRAM-startup byte), @a@ (after the BRAM SW for B),
    @b@ (after the SRAM[0] write), @c@ (after the SRAM[4] write),
    @d@ (just before the JALR-to-SRAM), then @S@ (from SRAM[0]'s
    SW), then ebreak.

    * __Without the fix__ silicon prints `BabcdSSSBabcdSSS…`
      cleanly looping through ~8 iterations before noise sets in.
    * __With the fix__ silicon prints exactly `BabcdS` once and
      halts.

    So **iter 1 completes fully** with the gating in place — every
    BRAM checkpoint commits, the JALR to SRAM works, the
    SRAM-resident SW commits its single `'S'`. The hang is
    strictly in the window __between iter 1's `ebreak` (or
    JALR-to-0; same halt) at SRAM[4] and iter 2's first
    BRAM-resident SW for `'B'`__. Specifically one of:

      1. Trap CSR update (mepc / mcause / mtvec base) in
         response to ebreak.
      2. PC redirect from SRAM[8] (last in-flight fetch) to
         `mtvec.base = 0`.
      3. SRAM controller transitioning back to idle while pcFetch
         leaves the SRAM range.
      4. BRAM blockRam read at idx 0 after the SRAM-to-BRAM fetch
         transition.
      5. IF/ID picking up the captured BRAM[0] instruction.
      6. Pipeline progressing through iter 2's `lui` / `addi` to
         the SW for `'B'`.

    **Resolved 2026-04-26** via ALTSOURCE_PROBE on-chip
    diagnostics. Two `altsource_probe` megafunctions added to
    `riski5_top.v` (32-bit `pcFetchS` + 8-bit packed flags),
    sampled via `quartus_stp`'s `read_probe_data` over JTAG.
    With the BE-only gating still active, the probe showed:

    * `pcFetch = 0x20000008` (= SRAM[8]) **stuck**.
    * `dataStallS = 1`, `fetchStallS` toggling normally.
    * `uartReadyS = 0` — JTAG-UART IP's `av_waitrequest`
      pinned high, even with `chipselect=0` after gating.

    Root cause: when `uartAcceptedS=True` gates `ambSel=0` /
    `ambBe=0`, the Altera IP's `av_waitrequest` defaults to high
    (the output isn't meaningful when chipselect=0), but the
    SoC's `dataStallS` checks `not uartReadyS` regardless of
    whether the master is even requesting → infinite stall on
    a non-existent transaction. The pipeline stays stuck with
    `pcFetch` registered at SRAM[8] forever because the SW for
    `'S'` never retires (stall=True forever), so iter 1's
    ebreak never gets to X-stage.

    Fix: also gate `dataStallS` on `uartAcceptedS` — the SoC
    ignores `!uartReadyS` while the gate is engaged. Two-line
    change to `dataStallS` plus the existing CS+BE gating in
    `uartBusS`.

    Silicon now loops: `BSBSBSBS×N` clean. CoreMark unchanged
    at 44.57 / 1.114. 160 sim tests still green. Both
    altsource_probe instances (`PCFE` for pcFetch, `DBGF` for
    flags) ship in every variant for future diagnostic use.

    Slack at sramexec is +5.587 ns at 40 MHz on the global
    variant and +7.842 ns on the wrapper variant — not a
    setup-timing miss. CoreMark stays clean across all variants
    because the `enableSramFetch=False` branch dead-code-
    eliminates the gating logic entirely on the production
    bitstream.

    Investigation paused. Next attempt requires SignalTap (or
    equivalent on-chip observability) to capture the actual
    cycle-by-cycle behaviour of the second iteration: in
    particular, whether `pcFetch` redirects to `0` after the
    ebreak / JALR-to-0 (we tested both — same halt), and whether
    the BRAM `'B'` SW in iteration 2 issues at all, or issues
    but its byte is suppressed somewhere along the bus → IP
    path. The architectural fix is real and sim-validated
    end-to-end. Only the silicon iteration-loop continuation is
    unsolved. Cosmetic only — the production CoreMark bitstream
    is unaffected.

  (Original probe writeup below, kept as the historical trail.)

  **2026-04-24 fix attempt — reverted.** Tried to implement
  fetch-side arbitration in `Riski5.Soc` alone (`SramOwner`
  state register, muxed controller inputs, `fetchSramRegS`
  holding register, combined `fetchStallS` into the existing
  `stallS`). All 159 cabal tests stayed green but __neither__
  the sramexec nor the CoreMark bitstreams ran on silicon:

    * sramexec still produced `BBBB...` because
      `Riski5.Core`'s `imemHeldS` latches 0 on the first
      fetch-stall cycle (where `cachedSram = 0`), handing
      that 0 back as the "captured" instruction when the
      fetch actually completes. Stale data → illegal-inst
      trap → restart → loop.
    * CoreMark hung too, despite never fetching from SRAM:
      restructuring the `imemDataS` mux + split-then-recombined
      `stallS` was enough to produce a Quartus placement
      Quartus couldn't drive correctly on Cyclone II. Same
      class of silicon gotcha as the earlier CPP-line-shift
      one.

  Root cause of the non-fix: the core's IF stage assumes 1-cycle
  fetch latency end-to-end. `pcFetchPrevS` is stall-gated
  (freezes before fetch-stall updates it to the new SRAM pc)
  and `imemHeldS` captures on the wrong cycle (pre-stall, not
  fetch-complete). Neither works for multi-cycle fetch.

  Full writeup + refactor plan at
  [`docs/perf/sram-exec-probe-2026-04-24.md`](./docs/perf/sram-exec-probe-2026-04-24.md).
  Next session needs to:
    1. Core-side: add `imemReady` input, redefine
       `pcFetchPrevS` / `imemHeldS` / IF-capture gating.
       ~15 lines of `Riski5.Core`; interface break that flows
       through every test.
    2. Sim coverage: `test/SramExecSpec.hs` against
       `socSimFull` so the next attempt can iterate without a
       Quartus round-trip.
    3. SoC-side: re-do the arbiter / mux pointing at the new
       `imemReady`.
    4. CoreMark baseline verify on silicon before declaring
       the refactor done.

  Separate from the phase-2B silicon hang (CoreMark's `.text`
  lives in BRAM too), but worth closing: long-term any firmware
  larger than the 16 KB ProgSize will need SRAM execution.

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

  Diagnostic progress:
  - **Sim reproduction attempts (2026-04-24) — all pass with
    P2-B applied.** Re-applied the phase-2B patch and ran 156
    tests across three coverage increments: 149 baseline +
    `UartBackpressureSpec` (Altera-UART-faithful FIFO / drain-gap
    contract) + `BramStallForwardSpec` (BRAM-stall + forwarding,
    mcycle CSR read, BRAM → mcycle → UART chain) +
    `SramStallForwardSpec` (multi-cycle SRAM SW / LW,
    BRAM-load → SRAM-store .data-init pattern, BSS-zero-init
    loop with taken-branch + SRAM store). All green with P2-B
    applied. Bug still does not manifest in sim.
  - **Fmax regresses 10 % with P2-B applied (2026-04-24).**
    Baseline regfileAsync CoreMark bitstream closes at Fmax
    **56.31 MHz**. Applying P2-B's regfileSync drops it to
    **50.87 MHz** — still closes the 40 MHz target with +5 ns
    slack, but going the __wrong direction__ for a change meant
    to shorten the X cone. Critical path: from the M4K's
    `portb_address_reg` through the regfile output + 4-tier
    forwardRs + handleInstr dispatch + exMemS setup, 19.962 ns
    total data delay (vs baseline's ~14 ns at the regfileAsync
    + forwardRs + handleInstr path). The Cyclone II M4K's read
    access time is apparently slower here than a 32:1 LUT-mux
    over 1024 FFs. Hold slack identical on both (0.391 slow /
    0.215 fast). This finding flips part of P2-B's original
    motivation: the only remaining win is ~300 LEs saved, with
    no Fmax gain.
  - **Dropping the clock to 30 MHz doesn't help (2026-04-24).**
    Hypothesis: maybe the silicon hang is a physical-timing
    issue the STA slow-85 °C corner doesn't model accurately.
    Test: re-applied P2-B + changed PLL from 50×4/5=40 MHz to
    50×3/5=30 MHz. Fmax closed at 46.76 MHz with +11.9 ns
    slack (huge margin). Silicon result: __CoreMark still
    hangs, zero UART output in 45 s__. MemTest at the same
    P2-B + 30 MHz config runs cleanly end-to-end. Rules out
    all timing-related explanations. The bug is purely
    functional — there's something P2-B changes that CoreMark
    triggers and MemTest doesn't, at any clock frequency.
  - **JAL / JALR + stack push-pop pattern sim-test passes
    (2026-04-24).** Big MemTest ↔ CoreMark asymmetry: MemTest
    has __zero__ JAL uses (all inline), while CoreMark is GCC-
    compiled C and uses JAL + JALR for every function call.
    The standard RISC-V function epilogue — @lw ra, 0(sp);
    jalr x0, ra, 0@ — has an RAW dependency through a
    multi-cycle SRAM stall that seemed a plausible P2-B
    failure mode. New `JalrStackSpec` covers this pattern
    with three cases (simple JAL/JALR; one call with stack
    push/pop + JALR-return; two back-to-back calls). All pass
    with P2-B applied. Pattern is not the culprit in sim.
  - Coverage-gap rationale: after this sweep the sim exercises
    every pattern from CoreMark's startup I can enumerate — the
    BSS zero-init loop, the .data-init loop, mcycle-read paths,
    UART polling — through both the stall (single-cycle BRAM,
    multi-cycle SRAM, UART back-pressure) and forwarding
    (EX→X, MEM→X, W-1→X, stall-held address gate) plumbing.
  - What this narrows down: the silicon bug is either (a) a
    physical-timing / M4K-synthesis / reset-timing issue that
    Clash-level sim cannot model, or (b) a pattern in the
    real CoreMark firmware we haven't synthesised in sim yet.
    Given how many synthetic patterns pass, (a) is increasingly
    likely.

  Diagnostic next steps when resumed:
  1. Baked the CoreMark image into a sim test (new
     `test/CoreMarkRealBytes.hs` + `test/CoreMarkSimSpec.hs`)
     and ran it through `socSimFull`. __Found a sim-harness
     bug, not the silicon bug__: even baseline (regfileAsync)
     produces zero UART output in 50k cycles, while the real
     bitstream prints the banner within milliseconds. Tests
     are kept in-tree (for future debugging) but unregistered
     from `Spec.hs`'s `defaultMain` so `cabal test` stays
     green. Full write-up in the module header at
     [`test/CoreMarkSimSpec.hs`](./test/CoreMarkSimSpec.hs).
     Once the harness matches silicon baseline, re-register and
     flip on the P2-B patch.
  2. Likely culprits in the harness (per the module header):
     (a) 'jtagUartAlteraSim' drain-gap model too strict for
     CoreMark's specific poll pattern; (b) 'sramChipSim' 512 KB
     timing nuance; (c) SoC-level init state the sim wrapper
     doesn't reproduce. The module header lists the three
     first experiments to run.
  3. If, after the harness is fixed, with-P2-B produces no
     output and without-P2-B produces the banner, we've
     reproduced the silicon hang in sim. Debug from there.
  4. If sim still doesn't reproduce, silicon instrumentation
     via Quartus SignalTap: tap `idExS.idPc`, `idExS.idRs1`,
     `rs1FwdS`, `stallInternalS`, `effectiveRs1AddrS` into a
     16-sample-deep buffer triggered on "pc stable for > 1000
     cycles" — tells us where the hang pc sits and what
     forwarding is giving the stalling instruction.
  5. Suspects to rule out: (i) regfileSync's Verilog inference
     mode on Cyclone II (Quartus may default to "Don't care" for
     read-during-write on simple dual-port M4K, vs Clash sim's
     read-first); (ii) the read-address gating adding a hold-time
     issue on the effective-rs pins (slow-corner +5 ns setup
     slack, but only +0.215 ns hold slack per the STA report —
     this margin is suspiciously thin and worth re-checking);
     (iii) wbHoldS capturing `Nothing` during sustained stalls
     losing a forward that's needed at stall-release.
  6. Mitigation candidates if the bug resists isolation:
     (i) drop the regfile-output bypass to M4K and keep the
     async regfile for one more phase — given the Fmax
     regression finding above, this may be the right call
     regardless of the silicon bug outcome; the 300-LE
     savings aren't worth the 10 % Fmax penalty on a
     Cyclone-II-class part where M4K read access competes
     poorly with LUT-mux-over-FFs.
     (ii) add a synthesis-attribute on the regfile write-mode
     to force "NEW_DATA" or "OLD_DATA" explicitly on Cyclone II.
     (iii) rewrite the regfile as a __distributed-LUT-RAM__
     variant via `asyncRam` (sync write + async read, ~200 LEs
     per port) — keeps the async-read timing of regfileAsync
     without the 1024 FFs. Same sim/silicon risk as M4K but
     shifts the inference target from M4K primitives to LUT
     RAM (which has saner same-cycle read/write semantics on
     Cyclone II per Altera docs).
     (iv) rework the pipeline to ACCEPT regfileSync's 1-cycle
     latency as a proper D-stage read and retire the need for
     same-cycle forwarding of "just-wrote-this-cycle"
     producers — but this is a phase-2 pipelining redesign,
     not a P2-B variant.

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

- **🎉 LINUX KERNEL BOOTED ON SILICON — 2026-05-02.** First time Linux
  6.18.22 actually executes on the riski5 EP2C35 hardware. Previously
  the kernel never printed anything — boot died inside the early
  SDRAM fetch+data race the architectural fix below resolves.
  Captured boot log: [`docs/perf/linux-first-boot-2026-05-02.log`](./docs/perf/linux-first-boot-2026-05-02.log).
  Kernel makes it through:
  ```
  [    0.000000] Linux version 6.18.22 #1-riski5
  [    0.000000] Machine model: riski5-de2
  [    0.000000] earlycon: juart0 at MMIO 0x10000000
  [    0.000000] clint: clint@2000000: timer running at 40000000 Hz
  [    0.000606] sched_clock: 64 bits at 40MHz
  ```
  ...then panics at ~0.24 s with `stack-protector: Kernel stack is
  corrupted in: 0x8002cd98`.

  **PC 0x8002cd98 disassembled (vmlinux 6.18.22 build).** That
  function is `task_work_add`, branch label `.L15`. Code at
  `0x8002cd5c`–`0x8002cd9c`:
  ```
   2cd68: 1008272f          lr.w    a4,(a6)         # cmpxchg loop
   2cd6c: 00f71663          bne     a4,a5,.L1^B2
   2cd70: 1ab8252f          sc.w.rl a0,a1,(a6)      # store cond w/ release
   2cd74: fe051ae3          bnez    a0,2cd68        # retry on SC fail
   2cd78: 02f71463          bne     a4,a5,.L28      # post-CAS branch
   2cd7c: 00400793          li      a5,4            # jump-table dispatch
   2cd80: 06c7ee63          bltu    a5,a2,2cdfc
   2cd84: 00207717          auipc   a4,0x207
   2cd88: f7c70713          addi    a4,a4,-132 # 233d00 <.L20>
   2cd8c: 00261613          slli    a2,a2,0x2
   2cd90: 00e60633          add     a2,a2,a4
   2cd94: 00062783          lw      a5,0(a2)
   2cd98: 00e787b3          add     a5,a5,a4        # PANIC HERE
   2cd9c: 00078067          jr      a5
  ```
  The panic site is **inside an LR/SC cmpxchg retry loop** plus a
  computed-jump-table dispatch on the result. If the LR/SC pair
  doesn't behave correctly (reservation lost prematurely, SC.W
  spuriously failing or succeeding, etc.), the cmpxchg either
  loops forever or stores the wrong value, and the jump-table
  index `a2` derived from the post-CAS state is bad — `jr a5`
  jumps off the rails. Stack canary check at the function's
  epilogue then reports corruption.

  This is significant: our existing AMO sim coverage exercises
  the AMO* family (Read+Write Mealy, multi-bank stress) but does
  NOT test the LR/SC cmpxchg retry-loop pattern under
  fetch-contended SDRAM. The next firmware variant (HelloLrScStress)
  should mirror this kernel pattern: lr.w → bne → sc.w.rl → bnez
  retry, on SDRAM, under fetch contention.

  Investigation 2026-05-02 (continued):

  **Timing margin ruled out.** SDC over-constraint sweep at 2.0,
  3.0, 4.0 ns all produce the IDENTICAL panic (same PC, same call
  trace, same wall time within ±1 ms). Reverted SDC to 2.0 ns.
  Bug is software/silicon-side, not marginal placement.

  **Stack-protector tripwire test.** Disabled CONFIG_STACKPROTECTOR
  and rebuilt. Kernel boots much further (past mount-cache,
  pid_max, BogoMIPS calibration) but hits a NEW failure:
  ```
  [    0.000000] clint: clint@2000000: ipi/timer irq not found
  [    0.000000] Failed to initialize '/soc/clint@2000000': -19
  [    0.000000] sched_clock: 32 bits at 250 Hz
  [    0.000000] bad: scheduling from the idle thread!
  ```
  Boot log: [`docs/perf/linux-boot-no-stackprotector-2026-05-02.log`](./docs/perf/linux-boot-no-stackprotector-2026-05-02.log).

  **The CLINT-init outcome differs between the two builds** —
  same DT, same hardware, but with stack-protector ON the CLINT
  driver succeeds ("timer running at 40000000 Hz"); with it OFF
  the CLINT driver fails ("ipi/timer irq not found"). That points
  to memory corruption affecting the device-tree FDT data
  structure (or the kernel's parsed copy of it) differently in
  the two layouts — i.e. there's still some silicon-side memory
  glitch the SDRAM two-port fix didn't fully cover.

  Re-enabled stack-protector for now. Next investigation paths:
  1. Capture the FDT bytes the kernel sees vs the DTB we upload,
     diff them. The boot stub stages the DTB into SDRAM right
     after the kernel; a corrupted byte there would explain the
     CLINT init divergence.
  2. Check whether AMO instructions (the newest bring-up,
     task #144) are involved in the CLINT init path — atomic
     refcounts inside the irq-domain registration in particular.
     **2026-05-02: sim coverage added.** Three layers of AMO+SDRAM
     stress now in the test suite (commit `3d45950`):
     * `SdramTwoPortSpec.case_amoShapeReadWriteRead` —
       bus-level AMO-shape (read X → write X back-to-back, fetch
       held in parallel). PASS.
     * `firmware/phase1/HelloAmoStress.hs` — BRAM bootstrap stages
       SDRAM-resident inner loop, `amoswap.w` + verify-`lw` across
       4 SDRAM banks per iteration.
     * `SocChainIntegrationSpec.case_amoStressClean` — end-to-end
       run of HelloAmoStress through the full SoC. PASS in 16 k
       cycles.
     All three green ⇒ the simplest hypothesis ("AMO breaks the
     two-port SDRAM") is **ruled out** in sim. Silicon-side
     reproduction with `riski5-core-amostress` bitstream is the
     next discriminator. If silicon fails clean (per-bank 'F'
     marker), we have repro and the bug is timing-only or covers
     an AMO sub-path the test doesn't exercise.
     **2026-05-02 silicon result: AMO is NOT the bug.** The
     `riski5-core-amostress` bitstream ran for 35 s on real
     hardware: **B count 13,261, D count 13,257, dots count
     848,438, F count = 0** (full log:
     [`docs/perf/amostress-silicon-2026-05-02.log`](./docs/perf/amostress-silicon-2026-05-02.log)).
     ~848 k clean amoswap.w + verify-lw operations across 4 SDRAM
     banks under fetch contention with zero failure markers.
     **AMOSWAP path is solid on silicon.**

     **2026-05-02 LR/SC silicon result: ALSO clean.** The
     `riski5-core-lrscstress` bitstream ran for 35 s: **B count
     11,575, D count 11,571, dots count 740,523, F count = 0**
     (full log:
     [`docs/perf/lrscstress-silicon-2026-05-02.log`](./docs/perf/lrscstress-silicon-2026-05-02.log)).
     ~740 k clean lr.w + sc.w.rl cmpxchg retry loops + verify-lw
     across 4 SDRAM banks under fetch contention with zero
     failure markers. The exact bus shape used by the kernel at
     the panic site (task_work_add's cmpxchg loop) works
     correctly on our silicon.

     **Conclusion: AMO + LR/SC are RULED OUT as the root cause of
     the Linux stack-protector panic at PC=0x8002cd98.**

     **2026-05-02 stack-stress silicon result: ALSO clean.** The
     `riski5-core-stackstress` bitstream ran for 35 s on real
     hardware: **B count 17,451, D count 17,447, dots count
     1,116,600, F count = 0** (full log:
     [`docs/perf/stackstress-silicon-2026-05-02.log`](./docs/perf/stackstress-silicon-2026-05-02.log)).
     ~1.1 M clean 4-register prologue/epilogue (sw/lw of ra,
     s0, s1, t0) on SDRAM-resident stack under fetch contention.
     Mirrors task_work_add's exact prologue/epilogue shape.
     **Three basic instruction patterns now ruled out on silicon:
     amoswap (848 k ops), lr/sc cmpxchg (740 k ops), multi-reg
     stack save/restore (1.1 M ops).**

     **2026-05-03 trap-during-stress silicon result: ALSO clean.**
     The `riski5-core-trapstress` bitstream ran for 35 s on real
     hardware: **B count 10,508, D count 10,504, dots count
     672,201, F count = 0** (full log:
     [`docs/perf/trapstress-silicon-2026-05-03.log`](./docs/perf/trapstress-silicon-2026-05-03.log)).
     Same task_work_add prologue/epilogue inner loop as stack-stress
     but with timer IRQs firing every ~256 cycles — at ~20 cycles
     per inner-loop iteration, that's an IRQ landing roughly every
     ~13 iterations, so essentially every pass has multiple IRQs
     fall inside the prologue / function body / epilogue. The trap
     handler uses mscratch + SRAM-scratch (3-word save area at
     0x2000_0000) for register preservation, not SDRAM. ~672 k
     clean iterations with active IRQ traffic, zero failure
     markers. **The trap entry / save / re-arm-mtimecmp / restore
     / mret path does NOT corrupt the live register set or the
     SDRAM stack frame.**

     **Conclusion: AMO + LR/SC + bare-stack + trap-mid-stack are
     ALL ruled out as the root cause of the Linux stack-protector
     panic at PC=0x8002cd98.** Four targeted bus-shape probes have
     confirmed each individual instruction pattern works correctly
     on our silicon under SDRAM fetch contention.

     **2026-05-03 SIMULATOR vs SILICON DIVERGENCE — bug is
     silicon-only.** Pure-Haskell sim (`riski5-linux-sim --full
     KERNEL DTB 20000000`) runs 20 M instructions = simulated
     time 0.16 s, no panic. Sim kernel cleanly reaches "Serial:
     8250/16550 driver" at `[ 0.162788]`, well past every silicon
     hang point. Silicon at 40 MHz hangs at SLUB init (last printk
     `[ 0.000000] SLUB: HWalign=64...` — timer subsystem hasn't
     started yet, every line reads `[ 0.000000]`). Logs:
     [`docs/perf/linux-40mhz-2026-05-03.log`](./docs/perf/linux-40mhz-2026-05-03.log)
     (silicon, hangs at SLUB).

     **2026-05-03 task #35 — slowClock=true (30 MHz) gets
     CLOSER to a full boot.** With the entire single-clock-domain
     design re-built at 30 MHz instead of 40 MHz (same `slowClock`
     mechanism that re-targets the PLL multiplier 4→3 and
     regenerates the SDRAM IP at clockRate=30000000), Linux now
     reaches FIVE more printks past the 40 MHz stop:

         40 MHz: SLUB: HWalign=64...   ← stop
         30 MHz: SLUB: HWalign=64...
                 NR_IRQS: 64...
                 riscv-intc: 32 local interrupts mapped
                 clint: timer running at 40000000 Hz
                 clocksource: clint_clocksource: ...
                 sched_clock: 64 bits at 40MHz, ... [    0.000606]   ← stop

     Hang point now lands AFTER timer subsystem is registered
     (`sched_clock` ts is 0.000606 s — first non-zero printk
     timestamp ever observed). Full log:
     [`docs/perf/linux-slowclock-30mhz-2026-05-03.log`](./docs/perf/linux-slowclock-30mhz-2026-05-03.log).

     **Timing-margin hypothesis is partially confirmed.** Slowing
     the clock 33 % buys the kernel through init_IRQ + time_init
     but not through the next phase (would expect "Calibrating
     delay loop" + "Memory: ..." + "devtmpfs: initialized" before
     the first driver init).

     **2026-05-03 task #36 — verySlowClock=true (20 MHz) reveals
     a DIFFERENT failure mode.** With pllBusMultBy=2 (50 × 2 / 5
     = 20 MHz) the kernel runs much further than at 30 MHz:

         20 MHz: ... [all the 30 MHz progress] ...
                 Dentry cache hash table entries: 8192   (← jump!
                                                          was 1024
                                                          at 40/30 MHz)
                 Inode-cache hash table entries: 8192    (was 1024)
                 Built 1 zonelists, mobility grouping off.
                 mem auto-init: stack:all(zero)
                 swapper[0]: unhandled signal 4 code 0x1
                            at 0x802033f0
                 cause: 00000002  (illegal instruction)
                 Code: Unable to access instruction at 0x802033ec
                 BUG: scheduling while atomic: ...

     Two distinct symptoms:
     1. **Hash table sizes doubled to 8192 entries** vs 1024 at
        30/40 MHz. Same kernel + same DTB should give same sizes
        — different size implies the kernel saw different values
        when reading memblock metadata, i.e. SDRAM read-back
        corruption.
     2. **Illegal-instruction traps with "Unable to access
        instruction at ..."** — the kernel's own trap handler
        can't refetch the instruction at the trap site. SDRAM
        instruction-fetch corruption.

     Most likely cause: hardcoded `sdrRefreshIntervalCycles = 600`
     in `Riski5.SdrController.defaultDe2Config`. At:
       40 MHz: 600 × 25 ns  = 15.0 µs   (just under JEDEC 15.625 µs avg)
       30 MHz: 600 × 33.3 ns = 20.0 µs  (over JEDEC, but worked for the short test window)
       20 MHz: 600 × 50 ns   = 30.0 µs  (~2× JEDEC; SDRAM bits decay before refresh)

     Full log:
     [`docs/perf/linux-veryslow-20mhz-2026-05-03.log`](./docs/perf/linux-veryslow-20mhz-2026-05-03.log).
     20 MHz silicon is NOT a clean test of timing margin alone —
     the refresh-period violation muddies the result. To do a clean
     20 MHz test we'd need to scale `sdrRefreshIntervalCycles`
     with clock rate (e.g. 300 cycles at 20 MHz = 15 µs).

     This invalidates the "AMO/LR/SC/stack/trap" suspect chain
     for THIS panic — not for hardware in general (those bare-
     metal probes are still correct silicon-clean tests). The
     next focus should be: (a) Verilator hwsim Linux boot to see
     if it reproduces the silicon hang (if not → bug is RTL-
     synthesis or IP-vs-RTL mismatch only).

     **2026-05-03 task #37 — Verilator hwsim infrastructure
     LANDED but Linux hwsim boot does not yet progress past the
     boot stub.** Significant work in this commit chain:
     - `pkgs/riski5-sim/verilog/riski5_sim_top.v` rebuilt to
       match current Top.hs port surface (was 28 PINMISSING).
     - New `sim_sdram_chip` Verilog module models the IS42S16400
       at command-protocol level: ACTIVATE / READ / WRITE /
       PRECHARGE / AUTO REFRESH / LMR with CL=2 read pipeline,
       DQM byte mask, per-bank active-row tracking, 8 MB unpacked
       array backing storage. Pre-loaded by harness via `MEM_INIT_*`
       pins.
     - New `firmware/phase1/LinuxBootSim.hs` minimal sim-only
       boot stub: print 'M', delay for SDRAM init, diagnostic LW
       from 0x80000000, print 'J', JALR to kernel.
     - `pkgs/riski5-sim/package.nix` overlay swaps CoreMark.hs to
       export LinuxBootSim's firmware (-DFIRMWARE_COREMARK path).
     - New `tools/linux-hwsim/Main.hs` runner that loads kernel +
       DTB into the simulated SDRAM via init pins, releases reset,
       captures UART. Mirrors `tools/linux-sim` interface.

     Status: SDRAM read of kernel byte at 0x80000000 returns
     the correct expected bytes (`6f 00 c0 05`, the head.S JAL).
     Boot stub successfully JALRs to the kernel. But after 5M
     hwsim cycles (vs 555k in pure-Haskell sim where "Linux
     version" appears), no further UART output. The kernel is
     either hanging in early head.S init or hitting a model
     bug on multi-row / multi-bank SDRAM accesses that the
     single-cell diagnostic LW didn't exercise. Further hwsim
     SDRAM-model debug is task #38; for now the diagnostic value
     is 30 / 40 MHz silicon hang reproduction is undetermined
     because the hwsim path doesn't yet execute long enough.

     Effective "Linux boots in pure-Haskell sim but not in
     silicon" finding is unchanged. The hwsim layer remains a
     valuable target — once the SDRAM-model debug lands, we'll
     have the third verification layer (Layer 1.75 in
     [docs/verification.md](./docs/verification.md)) actually
     working for whole-Linux-boot scope, not just the Hello
     firmware originally targeted.

     **2026-05-03 task #38 — SDRAM model basic ops VALIDATED,
     but kernel still hangs.** Extended LinuxBootSim diagnostic
     proved at the byte level:
     - Bank switching works (probe of 0x80000000/200/400/600 in
       all 4 banks returns the correct expected kernel bytes).
     - Cross-row reads work (probe of 0x80000800 = bank 0, row 1).
     - WRITE → row-flush → READ cycle works (wrote 0xCAFEBABE
       to SDRAM[0x80700000], read back `BE BA FE CA`).

     None of these single-cell patterns reproduce the sustained
     instruction-fetch stream the kernel needs. The hang is
     somewhere in the kernel's continuous SDRAM access pattern
     (likely interaction between the two-port adapter, the
     SdrController FSM, and my chip model's CL=2 + I/O register
     pipeline). Further debug requires VCD-trace analysis (hours
     of waveform inspection) or more elaborate diagnostic
     firmware that matches the kernel's actual fetch shape.

     **Status: hwsim SDRAM model is correct at the unit-op
     level. Whole-Linux-boot through hwsim remains blocked on
     the deeper debug above.** Logged for future return.
  3. Compare the two boot logs cycle-by-cycle to find exactly
     where the divergence in code path begins.

- **task #17 / #21 / #22 — SDRAM-stress concurrent fetch+data corruption — FIXED 2026-05-02.**
  Silicon `sdramstress` bitstream now prints `B................[256 dots]D`
  cleanly across multiple iterations — zero `F` failure markers in a
  30-second capture (1.6 MB log, 0 occurrences of `F`).
  Architectural fix in `Riski5.Sdram.sdram` + `Riski5.Sram.sram`:
  per-port last-result registers (`fetchRdataLastS`, `dataRdataLastS`)
  latched at the per-port ready pulse, held until the next transaction
  on that port. Without these, the Mealy `dataRdata` evaporates as
  soon as the FSM leaves the terminal-read state — and the core's
  `quenchDataS`-driven stall loop can keep the value in flight across
  a fetch transaction that wins arbitration next cycle, by which time
  `servingPortS` has flipped to SrvFetch and the data port reads 0.
  Same root cause was reproducing on silicon as `BAF actual=0`
  (Bank-A fail, expected 0x12340000). The whole-chain integration
  test (`test/SocChainIntegrationSpec.hs`) caught the bug in sim
  before silicon validation. Commits: `b08d3d7` (two-port refactor),
  `4daa6a7` (integration test), `7af49b2` (per-port last-result fix).

- **task #146 — Pure-Clash SdrController silicon write/read corruption — FIXED 2026-05-02.**
  - ✅ **JTAG-Master pattern test:** `nix run .#sdram-write-pattern-test`
    reports `summary: 29 passed, 0 failed of 29 total` against the
    `riski5-core-coremark` variant. The col=0 drop / BL=2 INTERLEAVED
    chip-mode bug is FIXED in commit dda25b2 (`sdrCasLatency = 2`).
    Reproduces across power-cycles.
  - ✅ **Sustained back-to-back hang:** `master_read_32 256` after
    `master_write_32 256` no longer wedges. 20/20 trials of
    write-then-read-256-words pass cleanly (mismatches=0). The
    16-chunk big-write + 256-word verify-read cycle (was the
    original kernel-upload reproducer) now runs end-to-end.
  - ✅ **Linux boot via JTAG-Master upload:** `nix run .#boot-linux-master`
    streams the full 3.2 MB kernel + 1.5 KB DTB to SDRAM, with the
    in-line `verify kernel: 0 / 1024 words bulk-dropped, 0 recovered`
    check coming back clean. Boot-stub then JALRs to the loaded image
    (the kernel itself produces garbled UART output, but that's a
    firmware/UART-stack issue, not SDRAM).

  Both layered bugs in task #146 are now resolved. First was the
  BL=2 INTERLEAVED chip-mode bug (chip ignored the BL=1 LMR field
  when CL=3 was programmed) — fixed by `sdrCasLatency = 2`. Second
  was a refresh-vs-request race in `Riski5.SdrController` — the
  `waitrequest` signal incorrectly dropped to False on the PhIdle
  cycle that transitioned to PhRefresh, so `Riski5.Sdram` latched
  that as "request accepted" and entered a wait-for-valid state
  that never resolved. Fixed by gating `waitrequest=False` on
  "PhIdle and NOT preempting with refresh". Regression test in
  `test/SdrControllerSpec.hs` (refresh-vs-request race group).

  ### Root cause of the second bug (refresh-vs-request race)

  Pinpointed 2026-05-02 by bisecting on `master_read_32 N` after a
  256-word seed write: N=128 OK, N=129 OK, N=130 hung. But running
  the same N=130 again after a re-flash sometimes worked. The
  intermittency tracked refresh: at `sdrRefreshIntervalCycles = 600`,
  refresh fires roughly every 50 chip-side reads = every 25 Avalon
  reads, giving ~2 % chance of misalignment per read. Once aligned,
  the wedge was permanent — `master_read_32` of any size hung
  forever on the next attempt. 256 single-word `master_read_32 1`
  calls in sequence ALL succeeded, ruling out anything per-cell
  and pointing at the multi-word burst path.

  The bug was in `sdrController`'s `PhIdle` handler:
  `waitrequest=False` was dropped on EVERY `PhIdle` cycle (the
  trivial `case PhIdle -> False` formula), including the cycle
  where the handler picked refresh over the master's pending
  request and transitioned to `PhRefresh`. The 32 ↔ 16
  `Riski5.Sdram` adapter saw `waitrequest=False` and advanced its
  FSM (`SReadLoReq` → `SReadLoWait` etc.) — but the controller had
  gone off to refresh instead of starting the read, so no `valid`
  pulse ever came back, and the adapter wedged in its wait state
  forever.

  The fix swaps the priority inside `PhIdle`: master requests are
  now serviced FIRST, refresh fires only when the master is idle.
  The `waitrequest` formula stays exactly as it was pre-fix
  (anything wider perturbs Quartus's place-and-route enough to
  break the CoreMark variant — see "CoreMark regression below").
  Refresh is sticky (`sdrRefreshPending` stays True until
  serviced), so deferring refresh across a master burst is safe:
  the chip's per-row refresh budget (~32 ms cumulative) is huge
  compared to the longest plausible un-broken request burst
  (a 256-word kernel chunk = ~6 ms, well inside budget).

  Regression test in `test/SdrControllerSpec.hs` —
  `case_continuousReadsUnderRefreshComplete` and
  `case_burstReadsSurviveRefresh` — both use a tightened
  `sdrRefreshIntervalCycles = 25` to provoke the race in
  bounded-cycle simulation.

  ### CoreMark variant regression (separate work item)

  The PhIdle-handler restructure perturbs Quartus's place-and-route
  for the `riski5-core-coremark` variant: the 13 s validated run
  no longer prints anything on JTAG-UART (silent boot hang).
  CoreMark doesn't access SDRAM during the timed loop, so the
  controller change should be dead code on the hot path; verified
  by bisecting that even a one-bit change to the `wr` formula
  (BISECT v1: read `sdrRefreshPending st` instead of the constant
  `False`) reproduces the same silent hang. STA closes (worst
  setup slack 2.434 ns, hold 0.391 ns — identical to baseline),
  but the silicon BRAM/SRAM access path silently corrupts after
  ~one CoreMark iteration of warm-up. Linux upload + 16-chunk
  big-write SDRAM tests (the actual user-visible workflows for
  task #146) all pass on the same bitstream — the bug is fixed
  end-to-end for SDRAM, just at the cost of the CoreMark variant
  no longer measuring. Next investigation should look at locking
  the CoreMark hot-path placement via QSF location assignments
  or pinning a Quartus seed so place-and-route stops being
  sensitive to upstream-of-bus changes.

  ### What landed
  - Altera SDRAM Controller IP + CDC bridge + second PLL all
    dropped. Pure-Clash `Riski5.SdrController` runs single-domain
    on `clkBus` (40 MHz), drives DRAM_* chip pins directly.
    Commits: `9b73726` (SoC integration), `8b0eda6` (BL=1 +
    refresh interval + init NOP scaled for 40 MHz), `5d8a9fe`
    (FAST_OUTPUT_REGISTER negative-result note), `dcfa067` (this
    TODO), **`5ec5829`** (durable timing infrastructure: SDC
    source-sync constraints + FAST_*_REGISTER on every DRAM_*
    output + `+90°` DRAM_CLK from PLL clk2 + new
    `sdrControllerAsAlteraIpRegistered` wrapper that gives
    Quartus a clean FF directly feeding each pad), **`3d3dcb2`**
    (LSWP altsource_probe — 64-bit pin-capture probe on chip-
    bound DRAM_* edges + JTAG-Master byteenable bug fix —
    `jtagMuxedSdram` no longer hardcodes `sibBe=0xF` when JTAG
    owns the SDRAM bus), **`04635b6`** (regression test for the
    byteenable fix in `test/JtagLoadByteEnableSpec.hs`).
  - 268/268 cabal tests green (sim is clean for both even and
    odd columns, both round-trip and integration tests).
  - **Pattern test now reports 8/29 PASSED** (was 4/29) — every
    "16-bit LO write" sub-test passes after the byteenable fix.

  ### Root cause hypothesis: chip is in BL=2 INTERLEAVED mode

  Confirmed 2026-05-01 via the LSWP probe + a targeted
  three-step Tcl experiment (`/tmp/sc-bl2-test.tcl`):

  1. Issue ONE 16-bit LO write of `0xAAAA` via the JTAG-Master
     IP (with the be-fix, this is exactly **one chip WRITE
     command**: addr=0x480, dq=0xAAAA, dqm=0; LSWP confirmed
     `write_count` advances by exactly 1, not 2).
  2. Read back the full 32-bit word: returns `0xAAAAAAAA` —
     i.e. **both** the targeted halfword cell (col=0x80) and
     the adjacent halfword cell (col=0x81) hold `0xAAAA`.
  3. Issue ONE 16-bit HI write of `0xBBBB` (single chip WRITE
     to col=0x81). Read back: full = `0xBBBBBBBB`. Critically,
     col=0x80 (the cell at A0=0) flipped to `0xBBBB` even
     though we wrote at col=0x81 (A0=1) — that's the
     **interleaved** burst order (`col, col XOR 1`), not
     sequential (`col, col+1`).

  This is exactly **BL=2 INTERLEAVED**. The IS42S16400 chip is
  bursting two cells per WRITE command, in interleaved address
  order. Our LMR programs A9=1 (single-write override) +
  A2:A0=000 (BL=1) + A3=0 (sequential) — none of which are
  taking effect. Either (a) the chip isn't receiving our LMR
  command at all, or (b) the LMR command bits are arriving
  garbled.

  The original `wrote 0xdeadbeef → read 0xdeaddead` failure
  for 32-bit writes is a direct consequence: the Sdram adapter
  splits a 32-bit write into two chip WRITEs (lo at col=N,
  then hi at col=N+1). Under BL=2 INT each WRITE bursts both
  cells — first chip WRITE writes lo to col=N + col=N+1, second
  chip WRITE then writes hi to col=N+1 + col=N (interleave from
  col=N+1 wraps to col=N). Last write wins → both cells = hi.

  ### Next step

  Determine whether the chip is *receiving* our LMR at all:
  - Change `sdrLoadModeRegCmd` to set CL=2 (= A6:A4=010)
    instead of CL=3 (=011), keeping the controller's `PhCl`
    wait at the same number of cycles. If LMR is honored,
    chip will drive READ data 1 cycle earlier than our wait
    state expects → reads return wrong data (probably garbage
    or BL=2 INT's second beat).
  - If reads break in this CL=2 build → LMR is honored, then
    chase why our intended A9 / BL / burst-type values aren't
    being latched (signal-integrity on LMR-only address bits?
    BA pin? T_MRD violated?).
  - If reads do NOT change → LMR isn't being received at all.
    Investigate init sequence: bump `sdrInitNopCycles` from
    4100 (= 102 µs at 40 MHz) to 8000 (= 200 µs); double
    `sdrTmrdCycles`; try issuing the LMR twice; experiment
    with the BA pins during LMR (datasheet says BA=00 is
    reserved for MRS — try BA=01 to see if chip rejects it).

  ### What the bug looks like on silicon
  - **Both JTAG-Master path *and* core path show the same SDRAM
    corruption** — confirmed by running both
    `nix run .#sdram-write-pattern-test` (JTAG-Master) and
    `nix run .#flash-riski5` + `nix run .#console` (MemTest
    firmware running on the core).
  - Pattern test (single-word writes, 4/29 partial pass on the
    "lucky" bitstream `r0s549995qp1zcss47fphlk5wpg4pdkx`):
    `wrote 0xdeadbeef → read 0xdeaddead` — even-column writes
    drop, odd-column writes commit, reads of even cols return
    the corresponding odd-col data.
  - MemTest first failure (this rules out JTAG-Master entirely):
    `F@80000000  G=807F807F  E=80000000` — addr-as-data verify
    finds the first SDRAM cell holds `0x807F807F` instead of
    `0x80000000` after a region-wide write pass. The 0x807F807F
    pattern doesn't match my JTAG-test "lo-reads-return-odd-col"
    model and is currently unexplained — almost certainly a
    different state of the chip's row-buffer under the wider
    core-driven write traffic.

  ### What's been ruled out
  - Not JTAG-Master / not the SoC's JTAG-load mux (MemTest
    confirms the bug is below those layers).
  - Not the bus mux's address bit handling (Riski5.Sdram's
    32→16 split round-trips correctly in sim).
  - Not pin-assignment (the OLD Altera IP using the SAME .qsf
    pin map handled even-col writes correctly).

  ### What's been tried + reverted
  - Manual PRECHARGE-ALL between transactions (no auto-precharge
    on R/W) → first write hung. Reverted.
  - `FAST_OUTPUT_REGISTER ON` on `DRAM_DQ[*]` → I/O-cell flop
    delays write data 1 cycle vs the WRITE command latched on
    the same edge → chip captures stale DQ → first write hung.
    Reverted (negative result documented in `5d8a9fe`).
  - FPGA-side `register 0 dqInS` → no observed change in silicon
    behaviour. Reverted.

  ### What's been tried + landed
  - **BL=1 in LMR** (was `A2:A0=001 = BL=2`). The chip was
    driving 2 beats per READ; controller sampled only the first;
    the chip then sat in the second-beat / auto-precharge window
    during cycles the controller assumed were idle. Manifested
    on silicon as a hang after a few master_read_32 calls. Fix
    in commit `8b0eda6`.
  - **Refresh interval scaled for 40 MHz**: `843 → 600` cycles.
    The original 843 was correct at 108 MHz (7.81 µs); at 40 MHz
    it works out to 21 µs > 15.625 µs spec.
  - **Init NOP delay scaled for 40 MHz**: `21600 → 4100` cycles
    (= 102.5 µs at 40 MHz, just over the chip's 100 µs spec).

  ### Quartus non-determinism (silicon-side surprise)
  - Quartus 13.0sp1 produces *different* bitstreams for
    *byte-identical* Verilog. `r0s549995qp1zcss47fphlk5wpg4pdkx`
    has 11473 LEs and gives the deterministic `0xdeaddead`
    pattern (4/29 partial pass). A later rebuild with same
    source produces 11434 LEs and hangs every transaction. The
    Verilog diff between the two is ONLY source-comment line
    numbers — actual logic identical. Lottery on placement +
    timing margin. Without proper SDC `set_input_delay` /
    `set_output_delay` constraints on DRAM_*, the fitter is
    free to pick layouts where even-col writes happen to win or
    lose the chip's setup/hold race.

  ### What landed 2026-05-01 — durable timing infrastructure (b done, lottery removed)

  Three changes that have to land together — the corruption is
  unchanged on silicon (see "Hardware-fault hypothesis" below),
  but the lottery is gone and STA now reports +2.4 ns setup
  slack on `dram_clk` so subsequent builds are deterministic.

  - **PLL `u_altpll` clk2 = +90° (+6250 ps) on DRAM_CLK output.**
    `pkgs/riski5-core/package.nix` adds a third PLL counter,
    routed straight to the `DRAM_CLK` pin (no fabric clock comes
    from it). Chip's clock edge now falls in the middle of the
    FPGA's stable DQ / command window after the I/O-cell Tco.
  - **Riski5.qsf — `FAST_OUTPUT_REGISTER ON` on every chip-bound
    `DRAM_*` output, `FAST_OUTPUT_ENABLE_REGISTER` + `FAST_INPUT_REGISTER`
    on DRAM_DQ.** Earlier attempt (commit `5d8a9fe`) only set
    this on DRAM_DQ — broke writes because the I/O-cell flop
    delayed DQ by one cycle vs the still-combinational WRITE
    command. The fix is uniform registration across DQ + every
    command/address pin (DRAM_CLK is *not* registered — it's a
    direct PLL → pad combinational path).
  - **`Riski5.SdrController.sdrControllerAsAlteraIpRegistered`** —
    new wrapper that registers chip-side outputs with
    `register sdrIdleCmd` and the DQ input with `register 0`,
    giving Quartus a clean FF directly feeding each `DRAM_*` port
    (which `FAST_OUTPUT_REGISTER` requires to actually pack).
    New `SdrConfig.sdrPipelineLatency :: Unsigned 4` field (= 2
    in `defaultDe2Config`, = 0 in `testCfg`) accounts for the
    1 cycle output-reg delay + 1 cycle input-reg delay; PhCl now
    waits `CL + sdrPipelineLatency - 1` cycles. `Riski5.sdc`
    declares `dram_clk` as a generated clock from PLL clk2 and
    constrains every chip-bound output (`set_output_delay -clock
    dram_clk -max 2.0 / -min -1.3`) and DRAM_DQ input
    (`set_input_delay -clock dram_clk -max 6.0 / -min 2.0`)
    against IS42S16400-7TL's t_DS / t_DH / t_AC / t_OH.

  After this commit, Quartus's STA `Slow Model Setup` reports:
  - `dram_clk`: +2.434 ns slack ✓ (was -6.256 ns)
  - `clk[0]`:   +5.072 ns slack ✓
  Hold: dram_clk +19.2 ns, clk[0] +0.391 ns — both pass.
  Fitter packs **68 registers into Cyclone II I/O cells** (was 32).
  LE rises 11,463 → 11,701 (the new register-stage flops).

  ### Hardware-fault hypothesis (next step — see investigation menu below)

  Even with all three fixes engaging cleanly:
  `nix run .#sdram-write-pattern-test` against the
  `riski5-core-coremark` variant (no SDRAM use from firmware,
  so the JTAG-Master always wins arbitration immediately) reports
  exactly the same 4/29 partial-pass + `wrote 0xdeadbeef → read
  0xdeaddead` lo-half-drop pattern as the lucky darkfort build
  before any of these changes landed. Detail:

  - Every `col=odd` (A0=1) write commits.
  - Every `col=even` (A0=0) write drops.
  - The col-even cell ends up holding the col-odd cell's
    last-written value.

  This is consistent with `DRAM_ADDR[0]` (PIN_T6) effectively
  stuck at 1 at the chip — board-level fault on the trace, bad
  solder joint, or chip-side stuck-at-1. NOT anything the
  controller can fix in logic. Confirming this is now the
  blocker for SDRAM bring-up.

  Note: `riski5-core-linux-master` variant *hangs* the
  pattern-test entirely (60 s timeout per transaction), not
  because the SDRAM controller is broken but because the
  Linux boot stub polls `SDRAM[0x807F_FFF4]` in a tight loop —
  the corruption returns wrong data and the constant SDRAM
  bus traffic prevents JTAG-Master from ever winning bus
  ownership. CoreMark variant is the right test target while
  the hardware fault is open.

  ### Where to pick up (next session)

  1. Power-cycle the DE2 board (`hermit-switcher` MCP /
     `hermit-switcher off|on --device ShellyPlugSG3-8CBFEAA058B0`).
  2. `nix run .#flash-riski5-coremark` (CoreMark variant — its
     firmware never accesses SDRAM, so the JTAG-Master path is
     never blocked by core-side polling).
  3. `nix run .#sdram-write-pattern-test` should now reliably
     give the **deterministic** 4/29 partial-pass with the
     `0xdeaddead` lo-half-drop pattern. If you get hangs, it's
     not the lottery — investigate whether the bitstream is
     actually flashed and the board is powered.
  4. Hardware-fault investigation (in order):
     - **c)** SignalTap II block on `DRAM_ADDR[0]`, `DRAM_DQ[15:0]`,
       `DRAM_DQ_OE`, `DRAM_RAS_N`, `DRAM_CAS_N`, `DRAM_WE_N`,
       `DRAM_CS_N`. Trigger on the WRITE-command edge for an
       even-col vs odd-col write and inspect the captured A0 trace.
       If A0 is FPGA-driven correctly (toggles 0/1) but the chip
       still stores the col-1 cell on both writes → chip-side
       fault (internal A0 logic or stuck cell). If A0 looks stuck
       at 1 even when FPGA drives 0 → board fault (open trace,
       bad solder joint).
     - **e)** Pin-swap test — temporarily swap the QSF assignment
       for `DRAM_ADDR[0]` (PIN_T6) with `DRAM_ADDR[1]` (PIN_V4),
       rebuild, re-test. If the failure pattern shifts to the
       new physical pin → board-level fault localised to PIN_T6.
       If the failure stays on the same logical address bit → the
       fault is in the chip's A0 input or internal logic.
     - **d)** verilambda full-SoC sim (#140) — Verilator with a
       behavioural SDRAM chip model would let us reproduce the
       silicon failure cycle-by-cycle in the host. Doesn't help
       with hardware faults but rules in/out controller-side
       contributions.

  Investigation step **a)** (bump T_RCD/T_RP/T_WR ~3×) is no
  longer the cheapest test — STA now confirms the existing
  timings have +2.4 ns of slack; bumping them further wouldn't
  change anything the chip sees.
  Investigation step **b)** (SDC constraints) — done in the
  commit above.

  ### Don't re-try
  - Manual PRECHARGE-ALL.
  - FAST_OUTPUT_REGISTER on DRAM_DQ alone (must be uniform across
    every DRAM_* output — already landed correctly in this commit).
  - The `PhRead → PhCl direct` shortcut (broke chip-model sim;
    a sim-friendly version requires also adjusting CL counter
    and the chip model in lockstep, which the test catches).

## Open questions

- (collected here between sessions so they're not lost)
