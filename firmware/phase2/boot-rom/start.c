/*
 * SPDX-FileCopyrightText: 2026 Mika Tammi
 * SPDX-License-Identifier: MIT OR BSD-3-Clause
 *
 * Hand-written boot stub that wraps the Copilot-generated state
 * machine in `boot_rom_step.c`.
 *
 * Responsibilities:
 *
 *   1. Set up the stack pointer (sp = 0x2008_0000, top of the
 *      DE2's 512 KB on-board SRAM — kernel-zeroed pages don't
 *      reach here while the kernel is running on the SDRAM-resident
 *      image).
 *   2. Implement the four MMIO trigger functions Copilot calls
 *      from step():
 *        - boot_emit_tick      — UART byte write of '.', tick alive
 *        - uart_read_data      — JTAG-UART DATA register poll
 *        - sdram_write         — store one 32-bit word into SDRAM
 *        - boot_finish         — captures the kernel byte count
 *   3. Drive step() in a loop until the state machine is done,
 *      then transfer control to the kernel via the standard
 *      RISC-V Linux nommu boot ABI:
 *        a0 = 0                       hartid
 *        a1 = 0x8000_0000 + kbytes    &dtb (just past kernel image)
 *        sp = 0x2008_0000             top of SRAM
 *        pc = 0x8000_0000             kernel entry
 *
 * B-1 status: minimal — only `boot_emit_tick` is wired; the
 * step loop runs N ticks then jalrs into a no-op spin (the
 * full state-machine handoff lands in B-2 + B-3).
 */

#include <stdint.h>
#include <stdbool.h>

#include "boot_rom_step.h"

/* ------------------------------------------------------------------
 * MMIO addresses — kept in sync with src/Riski5/MemMap.hs.
 * ------------------------------------------------------------------ */

#define UART_DATA_ADDR   0x10000000U
#define UART_CTRL_ADDR   0x10000004U
#define SDRAM_BASE       0x80000000U
#define SRAM_TOP         0x20080000U

/* ------------------------------------------------------------------
 * Trigger-function bodies. Copilot's generated step() calls these
 * by name when the corresponding stream-guard is True for a tick.
 * Each is one or two RV32 instructions of MMIO load/store after
 * GCC inlining.
 * ------------------------------------------------------------------ */

void boot_emit_tick(void) {
    /* Drop a '.' on the JTAG-UART. Visible signal that the boot
     * ROM is alive even before the load handshake starts.
     */
    *(volatile uint32_t *)UART_DATA_ADDR = '.';
}

/* B-2 placeholders — the bodies are uncommented once the Copilot
 * spec starts firing them.
 *
 * uint32_t uart_read_data(void) {
 *     return *(volatile uint32_t *)UART_DATA_ADDR;
 * }
 * void sdram_write(uint32_t addr, uint32_t word) {
 *     *(volatile uint32_t *)addr = word;
 * }
 * void boot_finish(uint32_t kernel_bytes) {
 *     g_kernel_bytes = kernel_bytes;
 * }
 */

/* ------------------------------------------------------------------
 * Entry point. The linker script places this at PC 0; reset
 * dispatches here directly. No startup file (-nostartfiles), so we
 * own the very first instruction the core executes.
 * ------------------------------------------------------------------ */

#define BOOT_TICKS 8000U  /* fires boot_emit_tick 8 times via the
                             "every 1000 ticks" guard, so silicon
                             prints "........" before the spin. */

__attribute__((noreturn, naked))
void _start(void) {
    /* sp := top of SRAM. Done in inline asm because we can't
     * reference 'sp' as a C variable, and we can't trust GCC
     * to emit a stack frame before sp is valid. After this
     * we may use C; locals land in SRAM as expected.
     */
    __asm__ volatile (
        "li sp, %0\n\t"
        "j  c_main\n\t"
        : : "i"(SRAM_TOP)
    );
    __builtin_unreachable();
}

__attribute__((noreturn, used))
void c_main(void) {
    for (uint32_t i = 0; i < BOOT_TICKS; i++) {
        step();
    }

    /* B-2 will replace this with: a0=0, a1=base+kbytes, jalr 0x80000000.
     * For B-1 we just spin so silicon shows the dots without crashing.
     */
    for (;;) {
        __asm__ volatile ("nop");
    }
}
