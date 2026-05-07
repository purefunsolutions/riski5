/*
 * SPDX-FileCopyrightText: 2026 Mika Tammi
 * SPDX-License-Identifier: MIT OR BSD-3-Clause
 *
 * Stage-0 /init for the riski5 nommu Linux. Two-stage handshake:
 *
 *   1. Direct MMIO write to the JTAG-UART DATA register at
 *      0x1000_0000. Works even before the tty layer is up — the
 *      Altera IP accepts a 32-bit write of a single byte and
 *      drops it on the JTAG host's stdin. Useful as a "userspace
 *      reached / proves L-3b → kernel boot → init handover" signal.
 *
 *   2. write(1, msg, MSGLEN) syscall. Exercises the user → kernel
 *      transition and the JTAG-UART tty driver path. If stage 2
 *      output appears too, the kernel's serial console is fully
 *      operational and we can graduate to a real shell in a future
 *      milestone.
 *
 *   3. exit(0). Linux nommu treats /init exit as a panic, but the
 *      message it prints ("Kernel panic - not syncing: Attempted
 *      to kill init!") is itself useful confirmation.
 *
 * Build: riscv64-unknown-linux-gnu-gcc -march=rv32ima -mabi=ilp32
 * (no flat support). Convert ELF → flat with `objcopy -O binary`,
 * then prepend a 64-byte BFLT v4 header with build_init_bflt.py.
 */

.equ MSGLEN, 38
.equ UART_DATA, 0x10000000

/* PC-relative addressing for msg. Without this the `la t0, msg`
 * macro is optimised by the assembler/linker into an absolute
 * `addi t0, x0, msg_link_address` (msg sits at link-address 0x88
 * given our `-Ttext=0x40`). At runtime the kernel's binfmt_flat
 * loader places /init at some SDRAM page (e.g. 0x80381000) and
 * t0 = 0x88 then points into the riski5 BRAM boot stub instead
 * of our message. We work around this by writing the auipc + addi
 * pair manually with explicit `%pcrel_hi` / `%pcrel_lo` so the
 * runtime PC is always added to the offset.
 *
 * The `1:` / `2:` labels keep each auipc/addi pair correctly
 * anchored — `%pcrel_lo(1b)` resolves to the offset between auipc's
 * PC and the symbol relative to that PC.
 */

.section .text
.globl _start
_start:
    /* --- Stage 1: direct MMIO --- */
1:  auipc t0, %pcrel_hi(msg)
    addi  t0, t0, %pcrel_lo(1b)
    li    t1, MSGLEN
    li    t2, UART_DATA
3:  beqz  t1, 4f
    lbu   t3, 0(t0)
    sw    t3, 0(t2)
    addi  t0, t0, 1
    addi  t1, t1, -1
    j     3b
4:

    /* --- Stage 2: write(1, msg, MSGLEN) --- */
    li    a7, 64           /* __NR_write */
    li    a0, 1            /* fd = stdout */
2:  auipc a1, %pcrel_hi(msg)
    addi  a1, a1, %pcrel_lo(2b)
    li    a2, MSGLEN
    ecall

    /* exit(0). Linux will panic, that's the expected end. */
    li    a7, 93           /* __NR_exit */
    li    a0, 0
    ecall

    /* If for some reason exit didn't take, spin. */
5:  j     5b

.section .rodata
msg:
    .ascii "[init] hello from riski5 nommu Linux!\n"
