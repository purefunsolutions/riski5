/* SPDX-FileCopyrightText: 2026 Mika Tammi */
/* SPDX-License-Identifier: MIT OR BSD-3-Clause */

/*
 * riski5 CoreMark crt0 — reset vector + minimal C runtime setup.
 *
 * At reset:
 *   PC       = 0x0000_0000
 *   all GPRs = 0
 *   mstatus  = 0 (M-mode, IRQ off)
 *   mtvec    = 0x0000_0100 (default trap handler — we don't enable
 *              interrupts during CoreMark, so the only way mtvec
 *              fires is an illegal instruction / misaligned-access
 *              fault, which we treat as "hang" below)
 *
 * This file is KEEP()'d into .text.init (see linker.ld), which is
 * placed at the very start of IMEM — so _start is literally the
 * first instruction the CPU fetches.
 *
 * Sequence:
 *   1. Initialise sp to _stack_top (top of SRAM, 0x2008_0000).
 *   2. Zero .bss (covers CoreMark's static state arrays).
 *   3. Copy .data LMA → VMA (IMEM → SRAM) so initialised data
 *      lives in writable memory. CoreMark emits almost no .data,
 *      but the loop is correct if any shows up.
 *   4. Clear mstatus.MIE (already 0 at reset, belt-and-braces).
 *   5. Call main(). CoreMark's main returns an int but we ignore
 *      it — the benchmark's last ee_printf line is the score we
 *      want on the UART, and returning doesn't drain the TX FIFO.
 *   6. Infinite loop. The JTAG UART FIFO drains while we spin so
 *      nios2-terminal sees the full score output.
 *
 * mtvec handler: plain WFI loop. Any trap during CoreMark is a
 * fatal program bug (illegal instr or misaligned-access) — freezing
 * at the trap PC is the right behaviour for debugging via
 * `quartus_sh` memory-content probes.
 */

    .section .text.init, "ax", @progbits
    .global _start
    .global _trap_hang
    .type _start, @function
    .type _trap_hang, @function

_start:
    /* Canonical RISC-V C-runtime prologue. la-sequences use
       AUIPC + ADDI pairs that the linker resolves against the
       symbol addresses in IMEM/SRAM. */

    /* Stack pointer → top of SRAM. */
    la      sp, _stack_top

    /* gp (global pointer) — we don't use relaxed addressing so
       leave it at 0; barebones CoreMark does the same. */

    /* --- Zero .bss ------------------------------------------- */
    la      a0, _sbss
    la      a1, _ebss
1:
    beq     a0, a1, 2f
    sw      zero, 0(a0)
    addi    a0, a0, 4
    j       1b
2:

    /* --- Copy .data LMA → VMA --------------------------------- */
    la      a0, _sidata     /* source: in IMEM (bus-readable per CM-3) */
    la      a1, _sdata      /* dest:   in SRAM                          */
    la      a2, _edata
3:
    beq     a1, a2, 4f
    lw      t0, 0(a0)
    sw      t0, 0(a1)
    addi    a0, a0, 4
    addi    a1, a1, 4
    j       3b
4:

    /* Ensure mstatus.MIE stays 0 — CoreMark runs with IRQs off
       (no timer, no devices are interrupt-driven here). Any
       spurious interrupt during the run would perturb the score. */
    csrci   mstatus, 0x8    /* clear bit 3 = MIE */

    /* Call main. CoreMark's main runs one complete benchmark pass
       including portable_init / portable_fini and then returns. */
    call    main

    /* After main returns — infinite loop. The UART FIFO drains
       while we spin (the hardware IP handles that on its own
       clock-gated side), so a nios2-terminal session still sees
       every byte written. Hitting an actual WFI would be
       preferable but WFI is a priv-Zicntr feature that riski5
       treats as NOP, so we just jump-to-self. */
5:
    j       5b

    .size _start, . - _start


/* Trap handler — at 0x0000_0100 (mtvec default). Any trap during
   CoreMark means a bug in the port (misaligned access, illegal
   instruction, ECALL/EBREAK from our own code). Freeze here so
   a JTAG probe can read mepc / mcause / mtval. Aligned to 256 B
   so the mtvec low bits are clear (direct mode). */

    .section .text, "ax", @progbits
    .align  8
_trap_hang:
    j       _trap_hang

    .size _trap_hang, . - _trap_hang
