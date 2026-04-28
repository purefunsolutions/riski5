<!--
SPDX-FileCopyrightText: 2026 Mika Tammi
SPDX-License-Identifier: MIT OR BSD-3-Clause
-->

# Booting Linux on riski5 — the M-mode roadmap (v2)

**Strategy decisions (from 2026-04-28 planning Q&A):**

  * **Path A first** (`CONFIG_RISCV_M_MODE=y`, no MMU, no
    OpenSBI), then Path B (S-mode + Sv32 + OpenSBI) as its own
    dedicated phase.
  * **Reuse riski5cuda's recipe** as the build template:
    `nommu_virt_defconfig + 32-bit.config + a riski5-specific
    overlay`, cross-compiled via `pkgsCross.riscv64.buildPackages.gcc`,
    output `vmlinux + Image + vmlinux.bin`. Pin the kernel to whatever
    nixpkgs's `pkgsCross.riscv64.linux` ships (currently 6.18 — fine).
  * **UART**: keep the Altera JTAG-UART IP and use upstream
    Linux's `altera_jtaguart` driver
    (`drivers/tty/serial/altera_jtaguart.c`, DT-compatible
    `"altr,juart-1.0"`, kernel since 2.6.36). No 16550 shim.
  * **CLINT memory-map refactor**: move CLINT from the packed
    custom slot at `0x1000_0060` to the SiFive-standard
    `0x0200_0000` with the SiFive register layout
    (`msip` @ 0x0000, `mtimecmp[hart]` @ 0x4000, `mtime`
    @ 0xBFF8) so upstream `sifive,clint0` driver binds without
    custom kernel work.
  * **Aggressive size-cut**: 8 MB SDRAM is the hard ceiling.
    Strip every kernel feature not needed for "kernel banner +
    /init prints + exit" (no networking, no FS but initramfs,
    no debug info, no kallsyms, etc.). Add features back as
    needed.
  * **`/init`**: hand-crafted RV32 asm, BFLT-wrapped, prints
    a banner via MMIO + syscall write(1) + exit(0). Real
    busybox shell deferred (needs an FDPIC-capable toolchain
    which `pkgsCross.riscv32-embedded` doesn't ship today).
  * **Load mechanism**: JTAG-load the kernel image into SDRAM
    via `quartus_stp`'s Avalon-MM master Tcl primitives.
    SD-card support deferred.

## Where we are (2026-04-28)

The phase-2A silicon delivers everything Linux needs for a
nommu-M-mode boot **except** UART RX irqs at the silicon
boundary and the CLINT memory-map refactor:

| Piece | Status | Where |
|---|---|---|
| RV32IMA core (5-stage pipelined) | ✓ silicon | `Riski5.Core` |
| 64-bit `mtime` / `mtimecmp` | ✓ silicon | `Riski5.Clint` (compact layout) |
| Machine-timer trap (MTI) | ✓ silicon | `Riski5.CSR.interruptPending` |
| SiFive-PLIC-1.0.0 | ✓ silicon-ready | `Riski5.Plic` at `0x4000_0000` |
| Machine-external trap (MEI) | ✓ silicon-ready | `PlicSocSpec` |
| JTAG-UART (Altera IP) | ✓ silicon | `Riski5.JtagUart` at `0x1000_0000` |
| 8 MB SDRAM (Altera IP) | ✓ silicon | `Riski5.Sdram` at `0x8000_0000` |
| 512 KB SRAM | ✓ silicon | `Riski5.Sram` at `0x2000_0000` |
| SDRAM execution from PC | ✓ silicon | `HelloSdramExec` |
| **CLINT at SiFive-standard `0x0200_0000`** | ✗ | refactor needed (see L-0) |
| **JTAG-UART av_irq through wrapper** | ✗ | wire missing (see L-1) |

## Memory map (post-refactor)

```
0x0000_0000 .. 0x0000_3FFF   BRAM       (16-32 KB; phase L-2 bumps from 4 KB)
0x0200_0000 .. 0x0200_FFFF   CLINT      (SiFive layout, 64 KB window — phase L-0)
0x1000_0000 .. 0x1000_000F   JTAG-UART  (Altera IP, 16 B)
0x1000_0020 .. 0x1000_003F   GPIO       (32 B, unused by Linux but harmless)
0x1000_0040 .. 0x1000_005F   LCD        (32 B, unused by Linux but harmless)
0x2000_0000 .. 0x2007_FFFF   SRAM       (512 KB, kernel may use as scratch later)
0x4000_0000 .. 0x403F_FFFF   PLIC       (SiFive-1.0.0 layout, 4 MB)
0x8000_0000 .. 0x807F_FFFF   SDRAM      (8 MB, kernel + initramfs land here)
```

Decoder updates (`Riski5.MemMap.slaveOf`):

  * `top4 = 0x0`: sub-decode bits[27:24] —
    `0x0` → BRAM, `0x2` → SlaveClint, otherwise SlaveNone.
  * `top4 = 0x1`: peripheral cluster (unchanged).
  * `top4 = 0x2`: SRAM.
  * `top4 = 0x4`: PLIC.
  * `top4 = 0x8`: SDRAM.

## Sub-task plan (Path A)

Each L-x is a self-contained commit (or short series). Order
minimises cross-dependencies; some pairs run in parallel.

### L-0. CLINT refactor: SiFive-standard layout @ `0x0200_0000`

Today's `Riski5.Clint` packs `mtime` / `mtimecmp` / `msip` into
a 64-byte window with custom offsets. Upstream Linux's
`drivers/clocksource/timer-riscv.c` + `timer-clint.c` expect the
SiFive layout exactly. Refactor:

  - **`Riski5.Clint`**: register layout becomes
    `msip[hart]@0x0000` (4 B per hart), `mtimecmp[hart]@0x4000`
    (8 B per hart), `mtime@0xBFF8` (8 B).
  - **`Riski5.MemMap.clintBase`**: `0x1000_0060` → `0x0200_0000`.
    Decoder grows a sub-decode for `top4=0x0`.
  - **`Riski5.Soc`**: rebind `clintSelS` against the new base.
  - **`firmware/phase1/HelloTimerIrq.hs`**: change CLINT base
    + use new offsets (`mtimecmp[0]` at 0x4000 instead of 0x08).
  - **`test/ClintSpec.hs`** + **`test/TimerIrqSpec.hs`**: update
    addresses + register layout.
  - **CoreMark verify** — should be transparent (the firmware
    doesn't touch CLINT during the timed loop).

Outcome: upstream `sifive,clint0` driver binds via DTS without
patching.

### L-1. JTAG-UART IRQ pin reaches `siUartIrq` on silicon

Same as the original L-1 plan. Today `app/Top.hs` ties
`siUartIrq = False` because the Altera JTAG-UART IP's
`av_irq` output isn't routed through `riski5_top.v`. Change:

  - `pkgs/riski5-core/altera-ip/jtag_uart/`: confirm the
    generated Verilog instance exposes `av_irq` (it does by
    default).
  - `pkgs/riski5-core/Riski5.qsf` + `riski5_top.v`: thread the
    IP's IRQ output through to a top-level wire.
  - `app/Top.hs`: replace `siUartIrq = False` with the live
    pin.

Validated by a small firmware that enables `CONTROL.RE`, types
into `nios2-terminal`, watches a sentinel byte from a
PLIC-driven handler.

### L-2. BRAM size — deferred (current 16 KB is already enough)

The plan title's "4 KB → 16-32 KB" was based on a misreading of
`ProgSize`. The current value is `ProgSize = 4096` *words* =
**16 KB BRAM** (`Vec 4096 (BitVector 32)` = 4096 × 4 bytes).
That's already comfortably above the boot-stub footprint
(< 1 KB of asm to set up SP, jump-into-SDRAM, and let the
JTAG-loaded kernel take over).

A bump attempt to `ProgSize = 8192` (32 KB) was made and
**reverted**: Quartus II 13.0sp1 hard-caps Verilog elaboration
loops at 5000 iterations (`Error 10106: loop must terminate
within 5000 iterations`), and Clash emits the imem
initialiser as one big `for (i=0; i < ProgSize; ...)`
unroll. The QSF assignment that lifts this limit in newer
Quartus versions doesn't exist in 13.0sp1.

**Two paths if we need >16 KB BRAM later** (neither needed for
phase-2 Linux bring-up):

1. **MIF-backed init.** Generate a `.mif` (Memory Initialization
   File) at build time from the firmware bytes, attribute the
   `blockRam` with `RAMSTYLE = "M4K"` and a MIF reference. No
   Verilog `for`-loop needed; Quartus loads the MIF directly.
2. **Split into multiple smaller blockRams.** Each below the 5000
   loop cap. Software pretends it's one bigger array via
   address-bit selection.

For phase-2 Linux, BRAM is only the small boot stub — kernel +
initramfs land in SDRAM via L-3's JTAG-load path. So we keep the
current 16 KB and proceed straight to L-3.

### L-3. JTAG-loadable SDRAM via `quartus_stp` Tcl + altsource_probe

Use the same `quartus_stp` + altsource_probe runtime that already
hosts our PCFE / DBGF / FRZP / FRZF / CAPR / OFFS / CMTC / ITRC
probes (see `pkgs/riski5-core/package.nix` and
`scripts/freeze-trigger-probe.tcl`). No new IP needed — the JTAG
hub on the FPGA reads/writes altsource_probe instances directly.

**Sub-tasks (each its own commit):**

#### L-3a. SoC-internal JTAG-load mux + Top.hs ports

Inside `Riski5.Soc`, mux the SDRAM-IP-bound bus signals between
the riski5 core's existing master and a JTAG-driven master, gated
by a 1-bit `siJtagLoadMode` field on `SocIn`. New SocIn fields:

```haskell
, siJtagLoadMode  :: Bool          -- 1 = JTAG owns SDRAM
, siJtagLoadAddr  :: BitVector 32  -- byte address
, siJtagLoadWdata :: BitVector 32  -- 32-bit word
, siJtagLoadWe    :: Bool          -- pulse to write
, siJtagLoadRd    :: Bool          -- pulse to read
```

New SocOut fields (probe-readable by JTAG):

```haskell
, soJtagLoadRdata :: BitVector 32  -- last read result
, soJtagLoadBusy  :: Bool          -- = waitrequest from SDRAM IP
```

Internally the mux sits *before* the existing `Riski5.Sdram`
adapter — so the adapter's 32→16 conversion still applies, and
the SDRAM IP sees clean 16-bit transactions on its slave port
either way. When `siJtagLoadMode=False` (i.e. CoreMark and every
other phase-1 / phase-2 firmware path), the mux reduces to
identity and Quartus dead-codes the JTAG-load arms — CoreMark
hot path stays bit-identical.

Top.hs grows matching input/output ports
(`JTAG_LOAD_MODE`, `JTAG_LOAD_ADDR`, `JTAG_LOAD_WDATA`,
`JTAG_LOAD_WE`, `JTAG_LOAD_RD`, `JTAG_LOAD_RDATA`,
`JTAG_LOAD_BUSY`). The wrapper does NOT yet drive these — they
get tied to constants for now (the riski5_top.v wrapper change
lands in L-3b).

Tests: a new `JtagLoadSpec` writes a known pattern via the
`siJtagLoad*` inputs to the simulated SDRAM model, then reads
it back via the regular core path, asserts equality.

#### L-3b. Wrapper-side altsource_probe instances

Extend `riski5_top.v` (in `pkgs/riski5-core/package.nix`) with
new altsource_probe instances:

| Instance ID | Width | Direction       | Maps to                |
|-------------|------:|-----------------|------------------------|
| `JLMD`      | 1     | source → fabric | `JTAG_LOAD_MODE`       |
| `JLAD`      | 32    | source → fabric | `JTAG_LOAD_ADDR`       |
| `JLDW`      | 32    | source → fabric | `JTAG_LOAD_WDATA`      |
| `JLWE`      | 1     | source → fabric | `JTAG_LOAD_WE`         |
| `JLRD`      | 1     | source → fabric | `JTAG_LOAD_RD`         |
| `JLRR`      | 32    | probe → JTAG    | `JTAG_LOAD_RDATA`      |
| `JLBS`      | 1     | probe → JTAG    | `JTAG_LOAD_BUSY`       |

Each wrapper-side source uses `clk30` as `source_clk` so the
write is synchronous to the SoC. The Tcl script's
`write_source_data -instance_id <ID> -value <hex>` then drives
the corresponding `siJtagLoad*` input on the next core clock
edge.

Cost: ~10 LEs per source (storage register) + a few muxes. Total
< 100 LEs — small enough that CoreMark should stay at the
44.57 / 1.114 baseline.

#### L-3c. `scripts/load-sdram-jtag.tcl`

Tcl script matching the shape of `freeze-trigger-probe.tcl`:

```tcl
set ids [find_probe_instances]
write_source_data -instance_id [dict get $ids JLMD] -value 1
foreach {addr word} $payload {
  write_source_data -instance_id [dict get $ids JLAD] -value $addr
  write_source_data -instance_id [dict get $ids JLDW] -value $word
  write_source_data -instance_id [dict get $ids JLWE] -value 1
  write_source_data -instance_id [dict get $ids JLWE] -value 0
  while {[read_probe_data -instance_id [dict get $ids JLBS]] eq "1"} {}
}
write_source_data -instance_id [dict get $ids JLMD] -value 0
```

Argument shape: `quartus_stp -t scripts/load-sdram-jtag.tcl
<bin-path> <base-addr>`. Reads `<bin-path>` as little-endian
32-bit words and writes them starting at `<base-addr>`.

Sanity-check: read-back at the end via `JLRD`/`JLRR` for the
first and last words — abort with a clear error if they don't
match what was written.

**Throughput estimate.** quartus_stp's JTAG hub commits sources
at ~1k transactions/s on USB-Blaster (slow JTAG TCK). Each
SDRAM word is 4 source writes + 1 probe read = 5 transactions =
~5 ms per word = ~200 KB/s for an 8 MB kernel. ~40 s per load
— acceptable for development. Compare against the firmware-
driven JTAG-UART loader which would be ~10 s/MB at the IP's
~100 KB/s, so similar order of magnitude either way.

**Why this approach over a JTAG-to-Avalon Master IP.** Quartus II
13.0sp1 ships an `altera_avalon_jtag_to_avalon_mm_master_bridge`
IP, but it (a) requires Qsys-generated Verilog plus our wrapper
adapter, (b) eats more LEs than a small altsource_probe set,
(c) gives the same ~200 KB/s throughput in practice (the JTAG
hub is the bottleneck, not the master port). Reusing
altsource_probe matches the existing debug toolchain and keeps
the wrapper a single source of truth.

### L-4. DTS + DTB

New `firmware/phase2/dts/riski5.dts` describing our SoC after
the L-0 refactor:

```dts
/dts-v1/;
/ {
    #address-cells = <1>;
    #size-cells = <1>;
    compatible = "riski5,nommu";
    model = "riski5-de2";

    chosen {
        bootargs = "console=ttyJ0,115200n8 earlycon=jtag-uart,mmio,0x10000000 keep_bootcon rdinit=/init";
        // initrd window — our loader places the cpio at
        // 0x8040_0000 (= base + 4 MB) and sizes to fit the
        // remaining 4 MB.
        linux,initrd-start = <0x80400000>;
        linux,initrd-end   = <0x80800000>;
    };

    cpus {
        #address-cells = <1>;
        #size-cells = <0>;
        timebase-frequency = <40000000>;  // 40 MHz core clock

        cpu@0 {
            device_type = "cpu";
            reg = <0>;
            compatible = "riscv";
            riscv,isa = "rv32ima_zicsr_zifencei";
            mmu-type = "riscv,none";
            status = "okay";

            cpu0_intc: interrupt-controller {
                #address-cells = <0>;
                #interrupt-cells = <1>;
                interrupt-controller;
                compatible = "riscv,cpu-intc";
            };
        };
    };

    memory@80000000 {
        device_type = "memory";
        reg = <0x80000000 0x800000>;  // 8 MB
    };

    soc {
        #address-cells = <1>;
        #size-cells = <1>;
        compatible = "simple-bus";
        ranges;

        clint@2000000 {
            compatible = "sifive,clint0\0riscv,clint0";
            reg = <0x2000000 0x10000>;
            interrupts-extended = <&cpu0_intc 3 &cpu0_intc 7>;
        };

        plic: plic@40000000 {
            compatible = "sifive,plic-1.0.0";
            reg = <0x40000000 0x400000>;  // 4 MB
            interrupt-controller;
            #interrupt-cells = <1>;
            #address-cells = <0>;
            interrupts-extended = <&cpu0_intc 11>;
            riscv,ndev = <8>;  // 8 sources max in our PLIC
        };

        uart@10000000 {
            compatible = "altr,juart-1.0";
            reg = <0x10000000 0x10>;
            interrupt-parent = <&plic>;
            interrupts = <1>;
        };
    };
};
```

Compile via `pkgs/riski5-dtb/package.nix` running `dtc -O dtb`.

### L-5. `riscv32-linux` cross-toolchain

`nix/devshell.nix`: add `pkgs.pkgsCross.riscv64.buildPackages.gcc`
(handles 32-bit via `-march=rv32ima -mabi=ilp32` per
riski5cuda's recipe — no separate `riscv32-linux` GCC needed).
Confirm `riscv64-unknown-linux-gnu-gcc -march=rv32ima -mabi=ilp32 --version` works.

### L-6. Linux kernel build via Nix

`pkgs/linux-rv32-nommu/package.nix` lifted from riski5cuda's
recipe with riski5-specific overlay:

```nix
# Overlay on top of nommu_virt_defconfig + 32-bit.config:
{
  echo 'CONFIG_CMDLINE_EXTEND=y'
  echo '# CONFIG_CMDLINE_FORCE is not set'
  echo 'CONFIG_CMDLINE="console=ttyJ0 earlycon=jtag-uart,mmio,0x10000000 rdinit=/init"'
  echo '# CONFIG_RISCV_ISA_C is not set'

  # === Q1: Altera JTAG-UART driver (in kernel since 2.6.36)
  echo 'CONFIG_SERIAL_ALTERA_JTAGUART=y'
  echo 'CONFIG_SERIAL_ALTERA_JTAGUART_CONSOLE=y'

  # === Q2: aggressive size cuts ===
  echo '# CONFIG_DEBUG_INFO is not set'
  echo '# CONFIG_DEBUG_KERNEL is not set'
  echo '# CONFIG_KALLSYMS is not set'
  echo '# CONFIG_NET is not set'                    # add later when needed
  echo '# CONFIG_SOUND is not set'
  echo '# CONFIG_USB_SUPPORT is not set'
  echo '# CONFIG_MMC is not set'
  echo '# CONFIG_INPUT is not set'
  echo '# CONFIG_VT is not set'
  echo '# CONFIG_DRM is not set'
  echo '# CONFIG_FB is not set'
  echo '# CONFIG_BLOCK is not set'                  # we don't need block layer
  echo '# CONFIG_VIRTIO_BLK is not set'
  echo '# CONFIG_VIRTIO_NET is not set'
  echo '# CONFIG_VIRTIO_MMIO is not set'
  echo 'CONFIG_CC_OPTIMIZE_FOR_SIZE=y'

  # === PLIC + CLINT bind ===
  echo 'CONFIG_SIFIVE_PLIC=y'
  echo 'CONFIG_RISCV_TIMER=y'                       # uses CLINT
}
```

First milestone: it builds. Second milestone: `vmlinux.bin`
size + a 1-2 MB initramfs fits comfortably in 8 MB. Third
milestone: it boots in Spike against the riski5 DTB with the
CLINT layout matching our hardware.

### L-7. Hello-world `/init` (BFLT)

`firmware/phase2/init-rv32-nommu/init.S` — riski5cuda's pattern,
ported to use our UART base:

```asm
.equ MSGLEN, 38
.equ UART_DATA, 0x10000000   # Altera JTAG-UART DATA reg

_start:
    # Stage 1: direct MMIO write (works pre-tty-init)
    la    t0, msg
    li    t1, MSGLEN
    li    t2, UART_DATA
1:  beqz  t1, 2f
    lbu   t3, 0(t0)
    sw    t3, 0(t2)         # JTAG-UART DATA: word-write of byte
    addi  t0, t0, 1
    addi  t1, t1, -1
    j     1b
2:
    # Stage 2: syscall write(1, ...) — proves syscall + user→kernel transition
    li    a7, 64
    li    a0, 1
    la    a1, msg
    li    a2, MSGLEN
    ecall
    # exit(0)
    li    a7, 93
    li    a0, 0
    ecall
3:  j     3b

msg:
    .ascii "[init] hello from riski5 nommu Linux!\n"
```

Build pipeline: `riscv32-none-elf-gcc → init.elf → init.bin`,
then a Python script wraps it in a 64-byte BFLT header
(riski5cuda's `build_init_bflt.py` works as-is).

`pkgs/init-rv32-nommu/package.nix` produces `$out/init` (BFLT).

### L-8. Initramfs

Lift riski5cuda's `pkgs/initramfs-rv32-nommu/package.nix`
verbatim — a tiny cpio.gz with `/init` (the BFLT from L-7) plus
empty `/proc /sys /dev` mount-point dirs.

### L-9. `riski5-core-linux` Nix variant + `flash-` + `load-sdram-` apps

`pkgs/default.nix` adds:

  - `riski5-core-linux`: same `pkgs/riski5-core/package.nix`
    machinery as `riski5-core-coremark`, but the firmware overlay
    bakes in the **boot-stub** — a small Asm-eDSL stub that:
      - sets up `sp = top of SRAM` (stack lives in SRAM, not
        SDRAM, so the boot stub's stack doesn't collide with
        the kernel image),
      - configures `mtvec` to a trap shim,
      - puts `a0 = 0` (hartid), `a1 = &dtb` per RISC-V Linux
        boot ABI,
      - jumps to the kernel entry (`0x8000_0000`).
    The DTB is concatenated at a fixed BRAM offset (e.g.
    `0x800` = word 512) and `&dtb` points there.
  - `flash-riski5-linux`: shells out to `quartus_pgm` + the
    `riski5-core-linux` `.sof`.
  - `load-linux`: shells out to `scripts/load-sdram-jtag.tcl`
    with the `linux-rv32-nommu`'s `Image` + an offset
    parameter for the initramfs.
  - `console`: existing `nios2-terminal` wrapper.

### L-10. Silicon bring-up

Sequence:

  1. `nix run .#flash-riski5-linux` — flash bitstream + boot stub.
  2. `nix run .#load-linux` — JTAG-load kernel into SDRAM at
     `0x8000_0000`, initramfs at `0x8040_0000`.
  3. `nix run .#console` — opens nios2-terminal.
  4. Watch the JTAG-UART for:
     - boot stub's `B` byte (already implemented by the
       sramexec / sdramexec firmwares; reuse pattern).
     - kernel's `[    0.000000] Linux version ...` banner.
     - device-tree probe messages.
     - `[init] hello from riski5 nommu Linux!` from `/init`.
     - kernel panic (PID-1 exit) — expected, validates the
       full chain.

## Dependency graph

```
L-0 (CLINT refactor) ──┐
                        ├─→ L-4 (DTS) ─┐
L-1 (UART IRQ wire) ────┤               │
                        │               ├─→ L-9 (Nix variant) ─→ L-10 (silicon)
L-2 (BRAM bump) ────────┤               │
                        │               │
L-3 (JTAG-load SDRAM) ──┘               │
                                         │
L-5 (toolchain) ──┐                      │
                   ├─→ L-6 (kernel build) ┤
                   ├─→ L-7 (init BFLT) ──┤
                   └─→ L-8 (initramfs) ──┘
```

L-0, L-1, L-2, L-3, L-5 run in parallel. L-4 needs L-0 (for the
new CLINT base). L-6/L-7/L-8 need L-5. L-9 needs everything; L-10
is the silicon validation.

## Open follow-ups (not blocking Path A)

  - **Real busybox shell**. Needs an FDPIC-capable toolchain
    or a flat-binary userspace build. Defer to Phase B (full
    S-mode Linux) where standard toolchains apply.
  - **Networking**. Phase B; needs ethernet MAC (DM9000 wrap
    per `TODO.md` T-LI5) plus kernel net subsystem
    re-enabled.
  - **Block storage / FS**. Phase B; needs SD-card or NOR
    flash controller plus kernel block + FS subsystems.
  - **Path B**: S-mode + Sv32 MMU + OpenSBI + full distro.
    Its own dedicated phase plan in
    `docs/core-family.md`.
