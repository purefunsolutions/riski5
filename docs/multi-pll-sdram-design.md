<!--
SPDX-FileCopyrightText: 2026 Mika Tammi
SPDX-License-Identifier: MIT OR BSD-3-Clause
-->

# Multi-PLL SDRAM clock-domain split — design notes

Tracks task #141. Captures the architectural plan for splitting the
Altera SDRAM Controller IP onto its own slower clock domain via an
async-FIFO Avalon-MM bridge, in case the cheaper `slowClock` Nix
flag (single domain at 30 MHz) doesn't fully resolve the silicon
hang at PC=0x80000108 (compaction notes 2026-04-30) — or in case
we want the architectural cleanliness of independent SDRAM-domain
clocking even when the hang isn't the trigger.

## Motivation

Silicon Linux boot through `boot-linux-master` hangs at
PC=0x80000108 immediately after an `amoadd.w` writes one SDRAM row
and the next IF fetch reads from a different row. The pure-Haskell
SoC simulator (`Riski5.SocSim`) boots the same kernel image
cleanly, so the architectural core is sound; the residual issue is
silicon-specific. Hypothesis: the IP's back-to-back
ACTIVATE → READ/WRITE → PRECHARGE → ACTIVATE sequence hammered at
40 MHz overruns either:

  1. The DRAM chip's per-command recovery time (signal integrity at
     the chip pin), or
  2. The IP's internal FSM at the configured `clockRate=40000000`
     (commit `f4132f2` calibrated this, but margin may be thin), or
  3. Some race in the Avalon-MM slave → SDRAM-chip command issue
     pipeline that only manifests with bus pressure from both fetch
     and data ports.

Slowing the entire design to 30 MHz uniformly tests (1) and (2);
the multi-PLL split tests (3) by giving the IP its own
back-pressure-decoupled clock domain.

## Topology

```
CLOCK_50 (50 MHz off-chip osc, FPGA pin N2)
    │
    ├──► u_altpll      → clk0: clkSys      (40 MHz, 0°)
    │   (existing)
    │
    └──► u_altpll_sdram → clk0: clkSdram    (30 MHz, 0°)
        (new)           → clk1: clkSdramOut (30 MHz, -3 ns) → DRAM_CLK
```

Two independent ALTPLLs (Cyclone II EP2C35 has 4; we use 1 today).
Each has its own VCO, free-runs independently after lock. Phase
relationship between `clkSys` and `clkSdram` is undefined and
drifts; **everything between the domains needs proper CDC.**

`u_altpll_sdram` produces both `clkSdram` (0°, drives the IP) and
`clkSdramOut` (-3 ns, drives DRAM_CLK pin) so the existing
chip-side phase-shift pattern is preserved — chip samples 3 ns
*after* the controller drives, leaving Tco + trace-delay margin.

`rstSdram_n` is a re-synchronised version of `rstSys_n` in the
clkSdram domain (2-FF synchroniser with async-low assert and
sync-high deassert, plus a hold-while-PLL-locking gate from
`u_altpll_sdram`'s own `locked` output).

## Bridge architecture

Place the bridge at the IP-side boundary of `Riski5.Sdram` so the
adapter (32 ↔ 16-bit splitter) keeps living in `clkSys`. Bridge
inputs are the adapter's master-side Avalon-MM signals; bridge
outputs (slave-side) drive the IP's slave port directly.

```
clkSys domain (40 MHz)              clkSdram domain (30 MHz)
┌─────────────────────────┐         ┌──────────────────────────┐
│  Riski5.Sdram adapter   │         │  Altera SDRAM IP         │
│  (Clash, 32 ↔ 16 split) │         │  (riski5_sdram, 16-bit)  │
│                         │         │                          │
│  out: SdramIpBus        ┼──┐  ┌──┼─ in: az_*                 │
│       (cs, addr, wdata, │  │  │  │                           │
│        be, rd, wr)      │  │  │  │  out: za_data, za_valid,  │
│                         │  │  │  │       za_waitrequest      │
│  in:  SdramIpReply      ├──┼──┼──┼                           │
│       (rdata, valid,    │  │  │  │                           │
│        waitrequest)     │  │  │  │                           │
└─────────────────────────┘  ▼  ▲  └──────────────────────────┘
                          ┌────────┐
                          │ Bridge │
                          │ riski5_│
                          │ sdram_ │
                          │ cdc    │
                          └────────┘
```

### Bridge protocol — toggle handshake

Forward path (clkSys → clkSdram):
1. Master-side state `M_IDLE`. When adapter asserts `cs`, latch
   `{addr, wdata, be, rd, wr}` into stable registers and toggle
   `req_sys`. Move to `M_BUSY`.
2. Slave-side 2-FF synchronises `req_sys` → `req_sdram_sync2`.
   Detect rising-edge transition.
3. On edge, slave-side reads the latched signals (set_false_path
   in SDC since they're stable across the request). Drive the IP
   from those signals. Move slave-side state to `S_DRIVE`.
4. Wait for IP's `az_waitrequest=0` (request accepted). For reads,
   transition to `S_AWAIT_VALID`; for writes, jump to `S_DONE`.
5. `S_AWAIT_VALID`: wait for IP's `za_valid=1`, capture `za_data`
   into a stable cross-domain register. Transition to `S_DONE`.
6. `S_DONE`: toggle `done_sdram`. Return to `S_IDLE`.

Reverse path (clkSdram → clkSys):
7. Master-side 2-FF synchronises `done_sdram` → `done_sys_sync2`.
8. On rising-edge transition, master-side captures the cross-domain
   `cap_rdata` into its own register, drops `bridge_waitrequest`
   to 0 for one cycle (so adapter advances from `SReadLoReq` to
   `SReadLoWait`, or from `SWriteLoReq` to `SWriteHiReq` etc.).
9. Following cycle: for reads only, pulse `bridge_valid=1` with
   `cap_rdata` so the adapter (now in `SReadLoWait`) captures the
   data. Master-side returns to `M_IDLE`.

The adapter's per-state Mealy logic naturally handles this:
`SReadLoReq → SReadLoWait` triggered by `waitrequest=0`,
`SReadLoWait → SReadHiReq` triggered by `valid=1`. As long as the
bridge sequences the two signals in adjacent cycles, the FSM
advances correctly.

### Latency budget

- Forward CDC: ~3 cycles in `clkSdram` (req_sync_0 → req_sync_1 →
  edge-detect)
- Slave processing: ~5–10 cycles (varies with IP — ACTIVATE +
  CAS + read = 3+CAS+1, write = 1)
- Reverse CDC: ~3 cycles in `clkSys` (done_sync_0 → done_sync_1 →
  edge-detect)
- Master post-cycle: 2 cycles (drop waitrequest, pulse valid)

At 40 MHz `clkSys` and 30 MHz `clkSdram`:
- 1 `clkSys` cycle = 25 ns
- 1 `clkSdram` cycle = 33.33 ns
- Per IP transaction: ~3·33 + 7·33 + 3·25 + 2·25 = 425 ns ≈ 17
  `clkSys` cycles

Each 32-bit SDRAM access decomposes into 2 IP transactions (lo+hi
half-word), so a 32-bit SDRAM LW or SW costs ~34 `clkSys` cycles
of stall. Reasonable — current design at 40 MHz takes ~6–8 cycles
per half-word.

## SDC constraints

Add to `pkgs/riski5-core/Riski5.sdc`:

```tcl
# Second PLL output drives the SDRAM IP and chip-pin clock.
create_generated_clock -name dram_clk \
    -source [get_pins -compatibility_mode {*altpll_sdram*|clk[1]}] \
    [get_ports DRAM_CLK]

# CDC false-paths for the toggle handshake. The latched request
# registers are sampled by the slave side after a 2-FF sync detects
# the req-edge, so the cross-domain combinational paths see stable
# values and don't need timing.
set_false_path -from [get_registers *|riski5_sdram_cdc:*|lat_*] \
               -to   [get_registers *|riski5_sdram_cdc:*|s_lat_*]
set_false_path -from [get_registers *|riski5_sdram_cdc:*|cap_rdata_sdram] \
               -to   [get_registers *|riski5_sdram_cdc:*|cap_rdata_sync_0]
set_false_path -from [get_registers *|riski5_sdram_cdc:*|req_toggle_sys] \
               -to   [get_registers *|riski5_sdram_cdc:*|req_sync_0_sdr]
set_false_path -from [get_registers *|riski5_sdram_cdc:*|done_toggle_sdram] \
               -to   [get_registers *|riski5_sdram_cdc:*|done_sync_0]
```

## SDRAM IP regeneration

Pass `--component-parameter=clockRate=30000000` to `ip-generate`
so the IP's internal cycle counts (TRCD, TRP, TRFC, TWR,
refreshPeriod, powerUpDelay) calibrate to the new 30 MHz clock.

## Implementation plan

1. Add `multiPllSdram ? false` flag to
   `pkgs/riski5-core/package.nix`. Mutually exclusive with
   `slowClock` (you don't need multi-PLL if you're already
   single-domain at 30 MHz).
2. When true, conditionally:
   - emit a 2nd ALTPLL instance (`u_altpll_sdram`) producing
     `clkSdram` and `clkSdramOut`
   - re-route DRAM_CLK from `u_altpll|clk[1]` (40 MHz) to
     `u_altpll_sdram|clk[1]` (30 MHz)
   - emit the `riski5_sdram_cdc` Verilog module inline
   - wire the bridge between the Sdram adapter signals and the
     SDRAM IP slave port
   - regenerate the SDRAM IP with `clockRate=30000000`
3. Add SDC constraints (see above).
4. Add `riski5-core-multipll`, `riski5-core-linux-master-multipll`,
   `boot-linux-master-multipll` Nix outputs.
5. Build + on-silicon bringup test.

## Test plan

After silicon flash, run the same Linux-boot probe that exposed
the original hang:
1. `nix run .#boot-linux-master-multipll`
2. Watch JTAG-UART for `Booting Linux on hartid 0` →
   `[    0.000000] Linux version` → first kernel printk.
3. If banner appears: hypothesis confirmed, multi-PLL is the fix
   (or a fix). Promote to default; deprecate `slowClock` once
   verified across all variants.
4. If still hangs at PC=0x80000108: the issue is not chip- or
   IP-timing. Re-investigate (likely candidates: residual
   adapter-state race after AMO, sticky-arbiter edge case,
   DRAM_DQ signal integrity at the FPGA-chip boundary).

## Risks

- **CDC bug**: the toggle handshake is straightforward but easy
  to get wrong (edge detection drift, missed valid pulses on read
  reverse path). Mitigation: simulator-test the bridge module in
  isolation before integrating.
- **Latency-sensitive code**: nothing in phase-1 firmware is
  tight-loop SDRAM-bound; CoreMark runs from BRAM. If a future
  feature needs SDRAM bandwidth, the bridge's per-transaction
  ~17-cycle stall becomes the bottleneck and would motivate a
  burst-aware redesign (currently the IP is already 1
  transaction at a time).
- **PLL count**: we use 2 of 4 PLLs. Plenty of headroom but
  follow-up multi-domain designs (e.g. Ethernet PHY at 25 MHz)
  need to track PLL allocation.
