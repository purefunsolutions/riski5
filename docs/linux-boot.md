<!--
SPDX-FileCopyrightText: 2026 Mika Tammi
SPDX-License-Identifier: MIT OR BSD-3-Clause
-->

# Booting Linux on riski5 — the M-mode roadmap

## Where we are (2026-04-28)

The riski5 silicon has the architectural pieces a no-MMU
(`CONFIG_RISCV_M_MODE=y` + `CONFIG_MMU=n`) Linux kernel needs:

| Piece | Status | Where |
|---|---|---|
| RV32IMA core (5-stage pipelined) | ✓ silicon-validated | `Riski5.Core` |
| 64-bit `mtime` / `mtimecmp` (CLINT) | ✓ silicon | `Riski5.Clint` at `0x1000_0060` |
| Machine-timer trap path (MTI) | ✓ silicon | `Riski5.CSR.interruptPending`, `TimerIrqSpec` |
| SiFive-PLIC-1.0.0 (8 sources) | ✓ silicon-ready | `Riski5.Plic` at `0x4000_0000` |
| Machine-external trap path (MEI) | ✓ silicon-ready | `Riski5.CSR.interruptPending`, `ExtIrqSpec`, `PlicSocSpec` |
| JTAG-UART (Altera IP, polite Avalon adapter) | ✓ silicon | `Riski5.JtagUart` at `0x1000_0000` |
| 8 MB SDRAM (Altera IP) | ✓ silicon | `Riski5.Sdram` at `0x8000_0000` |
| 512 KB SRAM | ✓ silicon | `Riski5.Sram` at `0x2000_0000` |
| SDRAM execution from PC | ✓ silicon | `HelloSdramExec` |

What's **missing** for M-mode Linux:

  1. A way to **load** a kernel image into SDRAM at boot.
  2. A **kernel image** — i.e. a working
     RV32IMA `vmlinux.bin` cross-compiled for our SoC's memory
     map and peripheral set.
  3. A **device tree blob** describing the SoC so the kernel's
     irqchip / timer / serial drivers bind correctly.
  4. A **boot stub** in BRAM that hands control to the kernel
     entry in SDRAM with `a1 = dtb` per the SBI/Linux RISC-V ABI.
  5. **Driver coverage** in the kernel for the JTAG-UART (or a
     16550-shim adapter — see T-LI2 in `TODO.md`).

A working **PLIC + UART RX** path on real silicon needs
the Altera JTAG-UART IP's `av_irq` output threaded through
`riski5_top.v`'s wrapper. Today `app/Top.hs` ties
`siUartIrq = False`; a follow-up commit will route the IP's
interrupt pin to a top-level input and forward it through.

## Strategic decision: `CONFIG_RISCV_M_MODE=y` first, S-mode later

There are two paths to Linux on a custom RV32 SoC:

  - **Path A — nommu Linux in M-mode.** Skip OpenSBI; the kernel
    runs at the highest privilege level. No MMU, no privilege
    separation, no virtual memory. Drivers map peripherals
    directly. Process isolation is by convention. Faster bring-up;
    sufficient for embedded use cases (telemetry, control loops,
    busybox shell).
  - **Path B — full Linux with S-mode + Sv32 MMU + OpenSBI.**
    M-mode runs OpenSBI as the SBI provider; S-mode runs Linux;
    user processes get the full virtual-memory experience. The
    "real" Linux deployment.

riski5 commits to **Path A first**, then **Path B as a follow-on
phase**. Reasoning:

  - Our 8 MB SDRAM is the binding constraint. A `CONFIG_NOMMU=y`
    rootfs on Initramfs fits in ~3-4 MB; the kernel itself
    typically ≤ 1.5 MB. Comfortable. A full S-mode + Sv32 +
    page-cached userspace + OpenSBI starts to crowd 8 MB.
  - We don't yet have an MMU or privilege-mode logic in the
    core. Adding S-mode + Sv32 is its own multi-week phase
    (`docs/core-family.md` sketches the shape: new CSRs
    `sscratch`/`sepc`/`scause`/`stval`/`satp`, mode-aware
    decode, the TLB lookup machinery in load/store + IF). Doing
    nommu first lets us validate the rest of the stack
    (driver bring-up, kernel build, boot mechanism) against a
    simpler core.
  - Linux's nommu RISC-V port is mature
    (`arch/riscv/configs/nommu_*_defconfig` upstream).
    `CONFIG_RISCV_M_MODE=y` skips the SBI calls entirely, so we
    don't need to write or port a SBI provider before getting
    a shell.

After Path A is silicon-validated, Path B is its own dedicated
arc with its own milestones.

## Sub-task plan (Path A)

The chunks below land **incrementally** — each is a
self-contained commit (or short series) that ships a green
silicon validation of its piece. The order minimises blocking
work: each task's deliverable enables the next without depending
on later ones being ready.

### L-1. JTAG-UART IRQ pin reaches `siUartIrq` on silicon

Today the IP's `av_irq` output isn't connected to anything; the
wrapper drops it. `app/Top.hs` ties `siUartIrq = False`
unconditionally. Both endpoints exist (the Altera IP exposes
`av_irq`; `Riski5.Soc` consumes `siUartIrq` and routes it into
PLIC source 1) — the wire just needs threading through:

  - `pkgs/riski5-core/altera-ip/jtag_uart/`: confirm the
    generated Verilog instance exposes `av_irq` (the default
    Qsys generation does; if not, regenerate with the IRQ pin
    enabled).
  - `pkgs/riski5-core/Riski5.qsf`: add a top-level input pin for
    the IRQ if the wrapper currently drops it; otherwise just a
    wire.
  - `app/Top.hs`: add a `uartIrqS` input alongside `uartRdataS` /
    `uartReadyS`; pass through to `SocIn.siUartIrq`.

Outcome: a firmware that enables `CONTROL.RE` on the IP sees
`mip.MEIP` rise on RX FIFO non-empty. Validated by typing into
`nios2-terminal` and watching a sentinel byte from a small
handler firmware. Same shape as `HelloTimerIrq` but driven by
RX rather than `mtime`.

### L-2. Bigger BRAM

The kernel itself lives in SDRAM, but the **boot stub** plus
device-tree blob plus initial stack lives in BRAM. Today's 4 KB
(4096 × 32-bit) is tight for that. Bumping to 16 KB or 32 KB
gives breathing room without crowding the M4K pool too much
(Cyclone II EP2C35 has 105 M4Ks total = ~59 KB; a 32 KB BRAM
costs ~57 M4Ks, just over the 50 % phase-1 cap from `CLAUDE.md`).

  - `app/Top.hs`: bump `ProgSize` from 4096 to 8192 (32 KB) or
    16384 (64 KB).
  - `pkgs/riski5-core/Riski5.qsf` SDC: confirm timing still
    closes at 40 MHz with the larger M4K cone.
  - Watch the fit report's "Total memory bits" — `CLAUDE.md`
    reserves ~50 M4Ks for future I$/D$ caches, so we shouldn't
    exceed ~50 M4Ks total today. A 32 KB BRAM × 32-bit typically
    fits in ~32 M4Ks (using 256×18 mode + dual-port),
    leaving ~20 M4Ks for the regfile-on-M4K refactor + caches.

Outcome: room for a ≥ 1 KB DTB + a small loader stub + ample
stack.

### L-3. JTAG-loadable SDRAM

To put a kernel image in SDRAM we need an out-of-band path. The
DE2 has no NOR Flash interface wired in our SoC yet (phase-1F
work) and SD-card support is also future. The most expedient
path uses the existing JTAG hub:

  - Expose the SDRAM Avalon-MM master through Quartus's System
    Console / `quartus_stp`'s `master_write_*` /
    `master_read_*` Tcl primitives. This is the Avalon-MM
    JTAG-master pattern most Altera reference designs use.
  - Tcl script that reads a `kernel.bin` blob, breaks it into
    32-bit words, and writes them into SDRAM at the kernel
    base address (e.g., `0x8000_0000`).

  Concrete deliverable: `scripts/load-sdram-jtag.tcl` that
  takes `<bin-path>` and writes it via JTAG to a fixed SDRAM
  base. Reuses the existing `quartus_stp` runtime our
  altsource_probe debug already depends on (per the
  freeze-trigger probe story in `1bd7a41`).

Alternative if the JTAG-master path turns out flaky: bake the
kernel into BRAM as Asm-eDSL bytes (the `sdramExec` /
`coremarkExec` overlay pattern), have the boot stub copy
BRAM → SDRAM at startup. Limited by BRAM size (so kernel must
be < 32 KB compressed, then decompressed). Probably too small
for real Linux but useful for testing the boot mechanism.

### L-4. Boot stub + DTB

A small Asm-eDSL stub in BRAM that:

  - Sets up the M-mode trap vector (`mtvec`).
  - Configures the stack (`sp = top of SRAM` or `top of SDRAM`).
  - Loads `a0 = hartid = 0` and `a1 = &dtb` per the RISC-V
    Linux boot ABI.
  - Jumps to the kernel entry in SDRAM.

The DTB is a binary blob describing the SoC, generated from a
DTS file under `firmware/phase2/dts/riski5.dts`. Compiles with
`dtc`. Embedded in BRAM at a known offset.

  Deliverables:
    - `firmware/phase2/dts/riski5.dts` — node tree describing
      `cpus`, `clint@10000060`, `plic@40000000`, `jtag-uart@10000000`,
      `memory@80000000` (8 MB), `sram@20000000` (512 KB).
    - Nix derivation `pkgs/riski5-dtb/package.nix` running
      `dtc -O dtb -o riski5.dtb riski5.dts`.
    - `firmware/phase2/boot-stub.S` (or its Asm-eDSL twin) with
      the boot ABI sequence.

### L-5. Cross-toolchain for kernel build

We have `pkgsCross.riscv32-embedded.buildPackages.binutils` in
the devshell. For kernel builds we also want
`pkgsCross.riscv32-unknown-linux-musl.buildPackages.gcc` (or
`riscv32-unknown-linux-gnu` with the kernel's standard toolchain
expectations). nixpkgs has `riscv32-unknown-linux-musl-binutils`
in the store today; check whether GCC is also pre-built or
whether we need to wire it via `pkgsCross.riscv32-linux-musl`.

  Deliverable: `nix/devshell.nix` adds the `riscv32-linux` GCC
  alongside `riscv32-embedded.binutils`. Confirm via
  `riscv32-unknown-linux-musl-gcc --version` in the devshell.

### L-6. Linux kernel build derivation

Nix derivation `pkgs/linux-rv32-nommu/package.nix` that:

  - Fetches a pinned Linux kernel release (start with 6.6 LTS
    or whatever has stable RV32 nommu support — verify against
    `arch/riscv/configs/nommu_*_defconfig`).
  - Applies a tiny patch (or `make`-overrides) for our specific
    SoC: clock frequency, peripheral base addresses, etc., if
    the device-tree alone isn't sufficient.
  - Configures via `nommu_virt_defconfig` as a starting point;
    customises with our peripheral choices
    (`CONFIG_RISCV_M_MODE=y`, `CONFIG_OF=y`,
    `CONFIG_SIFIVE_PLIC=y`,
    `CONFIG_SERIAL_8250_OF=y` if we go 16550-shim, or
    `CONFIG_HVC_RISCV_SBI=n` since no SBI).
  - Cross-compiles to `arch/riscv/boot/Image` (or `vmlinux.bin`)
    + DTB.
  - Output: `$out/Image`, `$out/vmlinux`, `$out/riski5.dtb`.

  Deliverable: `nix build .#linux-rv32-nommu` produces a
  bootable kernel image of size < 8 MB. First milestone:
  it builds. Second milestone: it boots in Spike against
  a stub DTB matching our SoC.

### L-7. Initramfs

A minimal initramfs with `busybox-mini` (or `toybox`) + a
shell + a couple of test utilities (`echo`, `cat`, `ls`).
Total size budget: ≤ 4 MB so kernel + initramfs + heap +
stack fits in 8 MB.

  Deliverable: `pkgs/riski5-initramfs/package.nix` building
  a `cpio.gz` initramfs of the right size, embeddable into
  the kernel via `CONFIG_INITRAMFS_SOURCE=...`.

### L-8. `riski5-core-linux` Nix variant

Same overlay pattern as the `riski5-core-coremark` /
`riski5-core-sramexec` etc. variants:

  - `pkgs/default.nix` adds a `riski5-core-linux` derivation
    that overlays `firmware/phase1/CoreMark.hs` with the
    boot-stub-words byte stream.
  - `flash-riski5-linux` app flashes the bitstream;
    `console` opens nios2-terminal.
  - Out-of-band: `nix run .#load-sdram-jtag --
    result-of-linux-kernel/Image` writes the kernel into
    SDRAM via JTAG.

### L-9. Silicon bring-up

Run on the DE2:

  1. `nix build .#riski5-core-linux && nix run .#flash-riski5-linux`.
  2. `nix run .#load-sdram-jtag -- $(nix build --print-out-paths .#linux-rv32-nommu)/Image`.
  3. `nix run .#console`.
  4. Watch for the kernel banner ("Linux version …") to land
     on the JTAG-UART.

  Expected first observable output: the kernel boot banner.
  After that: device-tree probe messages, init=/init invocation,
  the busybox shell prompt.

## Open questions / known unknowns

  - **JTAG-UART vs 16550 shim**: the existing JTAG-UART IP
    doesn't match any upstream Linux driver layout. Options:
    (a) write a small custom kernel driver (~100 LOC of
    `drivers/tty/serial/riski5_uart.c`); (b) implement a
    16550-layout adapter in Clash that wraps the JTAG-UART
    Avalon master (T-LI2 in `TODO.md`). (b) means zero new
    kernel driver code at the cost of more Clash hardware.
    Prefer (b) once T-LI2 lands; (a) as a quick-and-dirty
    fallback to get to the boot banner.

  - **SDRAM controller exposed to the kernel**: the Altera IP
    is opaque, but the kernel only needs to know the RAM is
    there. DTS `memory@80000000` covers it; no driver bind
    needed.

  - **Cache coherence**: we have no caches today, so no
    coherence question. When phase-2C/D adds L1 I$ + D$, the
    RV32 nommu kernel needs `dma_alloc_coherent` to do the
    right thing — typically routed through a noncoherent DMA
    pool, which is fine for our hardware (no DMA engines yet).

  - **Clock frequency**: kernel needs to know the timer
    frequency so `mtime` ticks count correctly. DTS exposes it
    as `timebase-frequency`. Today our PLL gives 40 MHz; the
    DTS will declare `40000000`.

## Dependencies between sub-tasks

```
L-1 (UART IRQ silicon) ─────────────┐
                                     ├── L-9 (silicon Linux bring-up)
L-2 (bigger BRAM) ───────────────────┤
                                     │
L-3 (JTAG-load SDRAM) ───────────────┤
                                     │
L-4 (boot stub + DTB) ───┐           │
                          │           │
L-5 (toolchain) ──┐       │           │
                   │       │           │
L-6 (kernel build) ┼───────┤           │
                   │       │           │
L-7 (initramfs) ───┘       │           │
                            │           │
L-8 (Nix variant) ──────────┴───────────┘
```

Roughly: L-1 / L-2 / L-3 in parallel (independent infrastructure
work), then L-4 / L-5 (toolchain + boot ABI), then L-6 / L-7
(actual kernel + rootfs), then L-8 packages everything, and L-9
is the silicon validation.

## When to start

Path A's foundation is **silicon-ready today** — every piece in
the "Where we are" table above is silicon-validated and held
green at CoreMark 44.57 / 1.114 across the entire phase-2A arc.
The path forward is incremental, with each L-x task landing as
its own commit (or short series). No big-bang refactor required.
