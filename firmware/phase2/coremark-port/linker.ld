/* SPDX-FileCopyrightText: 2026 Mika Tammi */
/* SPDX-License-Identifier: MIT OR BSD-3-Clause */

/*
 * riski5 CoreMark linker script — RV32IM bare-metal, two memory
 * regions.
 *
 * Layout:
 *   IMEM  0x0000_0000  16 KB    R / fetch + bus-read (CM-3 makes
 *                               imem a bus slave so .rodata loads
 *                               hit it)
 *   SRAM  0x2000_0000  512 KB   R / W   — .bss + stack + .data
 *                               runtime (.data LMA lives in IMEM)
 *
 * Reset PC is 0x0000_0000 → first byte of IMEM → _start (defined
 * in start.S, placed in .text.init which KEEP()s it at the head
 * of .text).
 *
 * Stack grows down from _stack_top at the very top of SRAM.
 * riski5's SP on entry = 0x2008_0000; leaves the full 512 KB
 * SRAM available, which is generous for CoreMark's on-stack
 * heap (MEM_METHOD_STACK, ~2 KB).
 *
 * .data is deliberately placed with LMA in IMEM and VMA in SRAM.
 * The crt0 in start.S copies LMA → VMA at boot so CoreMark sees
 * correct initial values in writable RAM. CoreMark itself doesn't
 * emit much .data (most initialized data is .rodata const), so
 * the copy loop is usually a no-op at link time — but it's correct
 * by construction for any .data that does appear.
 */

OUTPUT_ARCH("riscv")
OUTPUT_FORMAT("elf32-littleriscv")
ENTRY(_start)

MEMORY
{
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
    SRAM (rwx) : ORIGIN = 0x20000000, LENGTH = 512K
}

SECTIONS
{
    /* Reset vector + rest of .text. .text.init holds _start, KEEP()
       so --gc-sections doesn't strip it despite no direct reference. */
    .text : ALIGN(4)
    {
        KEEP(*(.text.init))
        *(.text .text.*)
        . = ALIGN(4);
    } > IMEM

    /* Read-only data (string literals, const arrays, CoreMark's
       `list_known_crc[]` / `matrix_known_crc[]` / `state_known_crc[]`
       reference tables). Landing in IMEM means .rodata loads at
       runtime hit imem's bus port — which CM-3 wires up. */
    .rodata : ALIGN(4)
    {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(4);
    } > IMEM

    /* .data: VMA in SRAM, LMA in IMEM. crt0 copies at boot. */
    .data : ALIGN(4)
    {
        _sdata = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4);
        _edata = .;
    } > SRAM AT > IMEM
    _sidata = LOADADDR(.data);

    /* .bss: zero-init region. crt0 clears _sbss .. _ebss. */
    .bss (NOLOAD) : ALIGN(4)
    {
        _sbss = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > SRAM

    /* Stack occupies whatever SRAM remains above .bss, up to the
       top of the SRAM region. Stack pointer initialised by crt0
       to _stack_top. */
    . = ORIGIN(SRAM) + LENGTH(SRAM);
    _stack_top = .;

    /* Discard the usual freestanding-unused sections so
       --gc-sections has a clear scope and the ELF stays small. */
    /DISCARD/ :
    {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame.*)
        *(.eh_frame_hdr)
        *(.riscv.attributes)
    }
}
