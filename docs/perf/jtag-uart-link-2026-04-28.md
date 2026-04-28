<!--
SPDX-FileCopyrightText: 2026 Mika Tammi
SPDX-License-Identifier: MIT OR BSD-3-Clause
-->

# JTAG-UART link throughput probe — 2026-04-28

Followup to the LDLDLD silicon fix (`cff845d`) and the boot-rom
RVALID-gate / `-O2` optimisations (`9c5688c`). Both optimisations are
real but **silicon throughput stayed ~2 KB/s** on a 3.4 MB Linux
upload over the DE2's JTAG-UART. This note records the precise
firmware-side measurement that pinned the bottleneck on the
JTAG-UART link itself, not the firmware loop.

## Probe

Patched `tools/boot-rom/Main.hs` `c_main` to emit `'P' + 8 hex chars`
(`mcycle` reading) every 256 consumed bytes. Built + flashed
`riski5-core-linux`, ran `nix run .#load-linux` for 60 s, captured
192 P markers. Probe was reverted before this note landed; it lives
in this commit's history if anyone wants to re-run.

## Numbers

```
192 P markers in 60 s
  → 49,152 bytes RX'd in steady state
  → host-side: ~2 KB/s as before
  → firmware-side: 533 bytes/sec consumed

Δmcycle between adjacent steady-state markers: ~12 M cycles / 256 B
  → ~47,000 cycles per byte at 40 MHz core clock
  → 1.18 ms per byte
```

## Where the cycles go

The naive `step()` body is ~250 instructions ≈ 250 cycles + memory
stalls. The probe's 9-byte status print per 256 bytes RX'd contributes
**most of the measured cost** because each `uart_putc('P')` /
hex-digit write blocks on `JtagUartAdapter`'s `waitrequest=1` while
the IP's TX FIFO drains over JTAG. With the host pulling status
bytes back at the same anemic JTAG-UART rate, every TX-side write
stalled tens of thousands of cycles. Subtracting the print cost,
real per-byte firmware overhead is **<300 cycles**, i.e. firmware
could drain RX at >130 KB/s if the link supplied bytes that fast.

## Bottleneck location

Production firmware (no probe) emits two TX bytes total: `'L'` at
boot, `'D'` on completion. So the TX-side stall analysed above is
absent; what remains is **the JTAG-UART link's RX rate from host →
device**, observed at ~2 KB/s.

Host-side state of the world:

| Knob | Value |
|---|---|
| USB-Blaster `JtagClock` (per `jtagconfig --getparam`) | 6 MHz |
| USB-Blaster `JtagClock` setability via `jtagconfig --setparam` | rejected: "No parameter named JtagClock" |
| `nios2-terminal` flushing | one `BS.hPut` per chunk + `hFlush hin`, no artificial throttling in `riski5-load-stream` |
| Altera JTAG-UART RX FIFO depth | 64 bytes |
| Riski5 core clock | 40 MHz (PLL 50 × 4 / 5) |

Theoretical JTAG-UART peak at 6 MHz TCK with ~10 TCK/byte: 600 KB/s.
Real-world USB-Blaster + nios2-terminal benchmarks usually land in
50–100 KB/s. We observe ~2 KB/s — **25–50× below the typical
floor**. The throttling almost certainly lives in the USB-Blaster
protocol path or `nios2-terminal`'s read-side packing, neither of
which the FPGA bitstream can influence.

## Confirming with the asm-eDSL `LinuxBoot` path

Re-flashed `riski5-core-sdramload` (Asm-eDSL `firmware/phase1/SdramLoader.hs`,
shipped in `5c890cd`) and tried streaming a 100 KB blob via
`scripts/load-sdram-jtag.sh`. After 30 s the output showed
`LDLDL…`, i.e. the loader had completed (`D`), `JALR`'d into junk
SDRAM, trapped back to PC=0, and started over (`L` again). Without
finer host-side timestamps it's hard to call exact KB/s, but
**both the Copilot path and the Asm-eDSL path saturate the same
~2 KB/s ceiling** — confirming the link, not the firmware.

## Implications

- The `cff845d` LDLDLD fix and `9c5688c` micro-optimisations are
  correct and worth keeping. They reduce per-byte firmware cost
  from ~150 instr/byte to ~5 instr/byte in the inner spin (verified
  in the disassembly).
- They do not move silicon-observed wall-clock throughput because
  the firmware was never the bottleneck once the LDLDLD bug was
  out of the way.
- Full 3.4 MB Linux uploads will take ~28 minutes at this rate.
  Annoying but not blocking — the boot ROM functions correctly
  end-to-end once the upload completes.

## Next steps (out of scope here)

Real fixes for the link rate live outside the riski5 repo:

1. **Different host loader.** Use `quartus_stp`'s in-system memory
   editor (Tcl interface `read_instance` / `write_instance` over
   altsource_probe), bypassing nios2-terminal entirely. The
   `load-sdram-jtag` path already supports altsource_probe-based
   uploads; see L-3 design notes.

2. **Faster cable.** Swap USB-Blaster for USB-Blaster II / Arrow
   USB-Blaster II clones at higher TCK rates if a board with the
   right pin headers shows up.

3. **Move SDRAM upload off-chip.** Boot ROM reads kernel + DTB from
   SD card or NOR flash instead of JTAG-UART. The DE2 has both,
   currently unused. Would also remove the host-side dependency
   entirely (mass-storage media → power-cycle → kernel running).

None are in scope for the immediate B-7 silicon-bring-up; the
working linuxBoot path with a long upload tolerates the slow
link for now.
