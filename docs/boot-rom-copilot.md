<!--
SPDX-FileCopyrightText: 2026 Mika Tammi
SPDX-License-Identifier: MIT OR BSD-3-Clause
-->

# Boot ROM via Copilot eDSL

Migrating `firmware/phase1/LinuxBoot.hs` (currently written in
the `Riski5.Asm` eDSL — direct RV32I instructions) to a
Haskell-with-[Copilot](https://copilot-language.github.io/)
specification that emits C, which our existing
`pkgsCross.riscv64.buildPackages.gcc` cross-compiles to RV32 with
`-march=rv32ima -mabi=ilp32`.

## Why Copilot

- Boot logic shares the project's primary language (Haskell).
- Copilot's stream model gives compile-time bounded execution —
  no unbounded recursion, all loops are tick-driven, state is
  explicitly named. Useful when this code lives in a 16 KB BRAM
  with no MMU.
- Same Haskell type-level invariants (e.g. SDRAM byte addresses
  are `Word32`, kernel word count is `Word32`) flow into the
  generated C without a manual translation layer.
- Long-term: Copilot has runtime-monitoring sub-libraries
  (`copilot-libraries`, `copilot-theorem`) that fit naturally
  next to a boot ROM if we ever want to assert invariants about
  the kernel image *while* it's loading (CRC32 over received
  bytes, "kernel header magic == 0x..." etc.).

## The challenge — Copilot is stream-oriented, boot ROMs are imperative

Copilot's compute model is "for each tick, update streams +
optionally fire C-extern triggers." That's a great fit for the
poll-loop part of the boot stub (each tick = one UART poll
attempt) but a bad fit for the final step "set up
`a0`/`a1`/`sp`, `jalr` to the kernel" — that's a single
side-effecting ABI handoff, not a stream update.

So the boot ROM is **two layers**:

1. **Copilot-generated C step function** that owns the
   load-from-UART-and-write-to-SDRAM state machine. Each
   `step()` call processes one tick of the state machine. The
   Copilot spec lives in `tools/boot-rom/BootRom.hs`; running
   it produces `boot_rom_step.c` + `boot_rom_step.h`.

2. **A tiny hand-written C `_start`** in
   `firmware/phase2/boot-rom/start.c` (and a one-instruction
   inline-asm `jalr` at the end) that:
   - Sets up the stack pointer (`sp = 0x2008_0000`).
   - Calls `step()` in a loop until the state machine reports
     "done loading."
   - Sets up `a0 = 0`, `a1 = &dtb` per the RISC-V Linux nommu
     boot ABI.
   - `jalr` to `0x8000_0000` (the kernel entry).

   The C-extern trigger functions Copilot calls for MMIO
   (`uart_read_data`, `sdram_write_word`, `uart_write_byte`)
   are implemented in this same C file as direct
   load/store instructions to the JTAG-UART and SDRAM MMIO
   regions.

## Generated C → RV32 pipeline

```
tools/boot-rom/BootRom.hs       (Copilot spec; pure Haskell)
  │  Copilot.Compile.compile
  ▼
boot_rom_step.{c,h}             (auto-generated step + state types)
  │
  │   firmware/phase2/boot-rom/start.c   (hand-written; sets sp,
  │                                       calls step() loop,
  │                                       implements MMIO
  │                                       triggers, final jalr)
  │   firmware/phase2/boot-rom/linker.ld (places .text @ 0x0,
  │                                       no .data/.bss segments
  │                                       — boot ROM is read-only
  │                                       imem-resident)
  ▼
riscv64-unknown-linux-gnu-gcc -march=rv32ima -mabi=ilp32
        -nostartfiles -ffreestanding -nostdlib
        -T linker.ld
        start.c boot_rom_step.c
   → boot_rom.elf
  │
  ▼
riscv64-unknown-linux-gnu-objcopy -O binary -j .text → boot_rom.bin
  │
  ▼
gen-bootrom-hs.py boot_rom.bin → firmware/phase1/LinuxBoot.hs
   (Generated module re-exports `linuxBootFirmwareWords` as a
    `[BitVector 32]` literal — same shape as today, different
    backing data. The riski5-core-linux Nix variant overlays it
    into CoreMark.hs the same way.)
```

The same `pkgs/coremark/gen-coremark-hs.py` pattern handles the
final binary → Haskell-literal conversion; we generalise it
to a shared `pkgs/lib/gen-bin-hs.py` that both the CoreMark and
boot-ROM builds call.

## Sub-tasks

### B-1. Copilot toolchain check

Add `copilot`, `copilot-c99`, `copilot-language`, and
`copilot-prettyprinter` to `riski5-load-stream`'s sibling
`riski5-boot-rom-gen` cabal executable's build-depends. Verify
in devshell:

```
cabal run riski5-boot-rom-gen
  → emits boot_rom_step.c + boot_rom_step.h to a tmp dir
```

A trivial first spec just keeps a tick counter and triggers
a `boot_emit_byte('B')` C-extern every 1000 ticks. The
existing CoreMark machinery confirms the RV32 toolchain still
works post-`copilot` introduction (CoreMark must stay at
44.57 / 1.114).

### B-2. Boot-ROM Copilot spec

Replace LinuxBoot.hs's logic in Copilot. State variables
(modeled as Copilot streams):

```
phase :: Stream Word8       -- 0=read kw[0], 1=read kw[1], …
                             -- 4=read dw[0], …, 8+=loading payload
shift :: Stream Word8       -- byte-shift counter (0/8/16/24)
kWords :: Stream Word32     -- kernel word count, accumulating
dWords :: Stream Word32     -- DTB word count, accumulating
total :: Stream Word32      -- kWords + dWords, computed once
written :: Stream Word32    -- words written so far
sdramPtr :: Stream Word32   -- 0x80000000 + written * 4
done :: Stream Bool         -- written == total
```

Trigger-function externs:

```
extern uint32_t uart_read_data(void);   /* polled DATA register */
extern void     sdram_write(uint32_t addr, uint32_t word);
extern void     uart_write_byte(uint8_t b);
extern void     boot_finish(uint32_t kernel_bytes);
                                        /* called once when done;
                                           start.c uses it to compute
                                           a1 = base + kernel_bytes  */
```

The state machine fires `sdram_write` exactly when a full word
has been assembled, advances `phase`, and fires `boot_finish`
when `done` first goes True. After `boot_finish` returns, the
hand-written C `_start` proceeds to the kernel `jalr`.

### B-3. Hand-written C start.c

About 30 lines. Owns:

- `extern uint32_t boot_kernel_bytes;` (set by `boot_finish`).
- The four trigger-function bodies (each is a 1-2 line MMIO
  read/write).
- `void _start(void)` — the linker entry. Sets `sp` via a tiny
  inline asm, calls `step()` in a `while(!done) {}` loop,
  reads `boot_kernel_bytes`, then issues the final
  `mv a0, zero; addi a1, gp, ...; jalr zero, t0, 0` block in
  inline asm.

### B-4. Nix derivation

`pkgs/boot-rom-rv32-nommu/package.nix` mirrors the
`pkgs/init-rv32-nommu/package.nix` pattern (cross-compile + objcopy,
plus the extra Copilot codegen step at the head). Output:
`$out/boot_rom.bin` + `$out/boot_rom.hs` (the literal-list
Haskell module).

### B-5. LinuxBoot.hs replacement

The existing LinuxBoot.hs becomes a thin re-export:

```haskell
module LinuxBoot (linuxBootFirmware, linuxBootFirmwareWords) where
import LinuxBoot.Generated (linuxBootFirmwareWords)
linuxBootFirmware :: Asm ()
linuxBootFirmware = error "use linuxBootFirmwareWords; \
                           \boot ROM is now Copilot-generated"
```

Or fully removed if no caller still uses the Asm form. The
`riski5-core-linux` Nix variant's CoreMark.hs overlay points
at the same module — no Soc.hs / Top.hs change.

### B-6. CoreMark verify

The CoreMark variant's bitstream is unaffected (different
firmware overlay), but the *recipe machinery* changes when we
introduce Copilot. CoreMark stable at 44.57 / 1.114 confirms
the toolchain plumbing is transparent.

### B-7. Silicon validate

Same workflow as L-9:

```
nix run .#flash-riski5-linux
nix run .#load-linux
# Watch for: 'L' → 'D' → kernel banner
```

Bit-for-bit equivalence between the Asm-eDSL boot stub and the
Copilot-generated one isn't expected (the GCC-emitted code is
larger and slower than the hand-tuned Asm), but the *behaviour*
must match: same UART status bytes, same Linux boot-ABI handoff.

## Out of scope

- Copilot's runtime-monitoring features (assertions, theorem
  prover output). Future work; the boot ROM spec is just the
  control flow today.
- Replacing `firmware/phase1/SdramLoader.hs` (the L-3b loader)
  with Copilot. That's the same shape minus the boot-ABI
  handoff; lift after the Linux boot stub works.
