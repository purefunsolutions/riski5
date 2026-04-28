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
        /* _start MUST land at offset 0 of .text (= address 0,
         * the riski5 reset PC). GCC, with -Os and naked
         * functions, freely reorders functions within a single
         * .o; without an explicit input-section spec, _start
         * commonly ends up at the end of start.o's .text and
         * the FPGA crashes on cycle 0. The codegen tags
         * _start with `__attribute__((section(".text.entry")))`
         * so we can pull it out here and place it first.
         */
        KEEP(*(.text.entry))
        *(.text .text.*)
        *(.rodata .rodata.*)
    } > BRAM

    /* .data + .sdata. Catch both regular and "small" data
     * (RV32 GCC puts static initialisers ≤ -G threshold in
     * .sdata for gp-relative addressing). objcopy -j .text
     * -j .data -j .sdata pulls all three into the flat
     * binary so non-zero static initialisers reach BRAM. */
    .data : ALIGN(4) {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > BRAM

    /* .bss + .sbss. _start zeros [__bss_start, __bss_end)
     * before tail-calling c_main — Copilot's per-step state
     * indices (s0_idx etc.) and our boot_done / uart_data
     * statics live here. Without zeroing they'd inherit
     * the bitstream padding (0x00000013 NOP) and the state
     * machine starts mid-tick on reset. */
    .bss : ALIGN(4) {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        __bss_end = .;
    } > BRAM

    /DISCARD/ : {
        *(.note*)
        *(.comment)
        *(.eh_frame)
        *(.eh_frame_hdr)
    }
}
