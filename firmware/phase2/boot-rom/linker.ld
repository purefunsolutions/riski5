/*
 * SPDX-FileCopyrightText: 2026 Mika Tammi
 * SPDX-License-Identifier: MIT OR BSD-3-Clause
 *
 * Linker script for the Boot ROM (B-1). Places .text at 0x0
 * (the riski5 reset PC), no .data / .bss segments — the boot
 * code is read-only imem-resident and small enough to fit in
 * registers + the SRAM stack the start code sets up.
 *
 * The image gets `objcopy -O binary`'d into a flat blob; that
 * blob is then fed through pkgs/coremark/gen-coremark-hs.py
 * (or the upcoming gen-bin-hs.py) into a [BitVector 32]
 * literal that the riski5-core-linux Nix variant overlays into
 * the imem.
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    /* Match the BRAM region in src/Riski5/MemMap.hs — phase-1
     * imem is 16 KB, addressable from PC 0.
     */
    BRAM (rx) : ORIGIN = 0x00000000, LENGTH = 16K
}

SECTIONS
{
    .text : ALIGN(4) {
        *(.text .text.*)
        *(.rodata .rodata.*)
    } > BRAM

    /* No .data / .bss — boot ROM is fully in registers + SRAM
     * stack. If a future Copilot spec needs persistent state
     * across step() calls, copilot-c99 emits it as static-storage
     * uint*_t arrays in .bss; we'd add a .bss section here that
     * also lives in BRAM (read-only after init — Copilot's state
     * arrays are written by step() which is OK because BRAM is
     * read-write from the core's perspective, just imem-loaded
     * via the bitstream).
     */

    /DISCARD/ : {
        *(.note*)
        *(.comment)
        *(.eh_frame)
        *(.eh_frame_hdr)
    }
}
