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
    /* BRAM hosts .text + .rodata + .data, baked into the bitstream.
     * The bus port is **read-only** in `Riski5.Soc` (writes silently
     * drop), so anything mutable can't live here.
     */
    BRAM (rx) : ORIGIN = 0x00000000, LENGTH = 16K

    /* On-board 512 KB SRAM (IS61LV25616-class) is the writable
     * scratch region. We park .bss/.sbss here (via NOLOAD) so
     * `_start` can zero them — required because `boot_done`,
     * `boot_kernel_bytes`, `uart_data`, and Copilot's per-step state
     * indices live in .sbss and would otherwise inherit BRAM's
     * bitstream padding (0x00000013 NOP, truthy as bool).
     */
    SRAM (rw) : ORIGIN = 0x20000000, LENGTH = 512K
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

    /* .data + .sdata. Initialised data lives in BRAM (read-only,
     * bitstream-baked). Copilot only emits zero-initialised
     * statics so .data/.sdata are normally empty for this image,
     * but we keep the section in case some const-ish initialiser
     * sneaks in. */
    .data : ALIGN(4) {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > BRAM

    /* .bss + .sbss in SRAM (writable). NOLOAD keeps these out of
     * the flat binary — `_start` zero-fills [__bss_start, __bss_end)
     * over the live SRAM region before tail-calling c_main. */
    .bss (NOLOAD) : ALIGN(4) {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        __bss_end = .;
    } > SRAM

    /DISCARD/ : {
        *(.note*)
        *(.comment)
        *(.eh_frame)
        *(.eh_frame_hdr)
    }
}
