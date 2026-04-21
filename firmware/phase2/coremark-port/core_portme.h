/* SPDX-FileCopyrightText: 2026 Mika Tammi */
/* SPDX-License-Identifier: MIT OR BSD-3-Clause */

/*
 * riski5 CoreMark port — platform configuration.
 *
 * Modelled on eembc/coremark@v1.01's barebones/core_portme.h,
 * specialised for the riski5 SoC running on Altera DE2 silicon:
 *
 *   - RV32IM, no floating-point hardware (HAS_FLOAT = 0).
 *   - No C stdlib — we're freestanding. <stddef.h> and <stdarg.h>
 *     are GCC freestanding headers, so they're available even with
 *     `-nostdlib`.
 *   - Timing comes from the `mcycle` / `mcycleh` CSRs (Zicsr +
 *     M-mode, both implemented by riski5's CSR file).
 *   - Output goes to the Altera JTAG UART IP at MMIO 0x1000_0000
 *     (see `uart_send_char` in core_portme.c). A `nios2-terminal`
 *     session reads it out.
 *   - Single-threaded (MULTITHREAD = 1 with default_num_contexts =
 *     1).
 *   - Memory: MEM_METHOD = MEM_STACK, CoreMark allocates its
 *     working memory on the stack. This avoids implementing
 *     malloc / sbrk entirely.
 */

#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include <stddef.h>     /* size_t, NULL — freestanding header */
#include <stdarg.h>     /* va_list for ee_printf — freestanding */

/* --- Feature switches ---------------------------------------- */

#ifndef HAS_FLOAT
#define HAS_FLOAT       0
#endif

#ifndef HAS_TIME_H
#define HAS_TIME_H      0
#endif

#ifndef USE_CLOCK
#define USE_CLOCK       0
#endif

#ifndef HAS_STDIO
#define HAS_STDIO       0
#endif

#ifndef HAS_PRINTF
#define HAS_PRINTF      0
#endif

/* --- Compiler-version / flags reporting --------------------- */

#ifndef COMPILER_VERSION
#ifdef __VERSION__
#define COMPILER_VERSION "GCC " __VERSION__
#else
#define COMPILER_VERSION "riscv32-none-elf-gcc (version unknown)"
#endif
#endif

#ifndef COMPILER_FLAGS
#define COMPILER_FLAGS  FLAGS_STR   /* injected via -DFLAGS_STR= by core_portme.mak */
#endif

#ifndef MEM_LOCATION
#define MEM_LOCATION    "STACK"
#endif

/* --- Data types --------------------------------------------- */

typedef signed short   ee_s16;
typedef unsigned short ee_u16;
typedef signed int     ee_s32;
typedef double         ee_f32;      /* unused when HAS_FLOAT=0 but referenced in coremark.h */
typedef unsigned char  ee_u8;
typedef unsigned int   ee_u32;
typedef ee_u32         ee_ptr_int;  /* 32-bit target, pointer fits in u32 */
typedef size_t         ee_size_t;

/* align_mem — 32-bit-aligned pointer arithmetic, used by the
   matrix benchmark to carve its input blocks out of a byte array. */
#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x) - 1) & ~3))

/* --- Timer types -------------------------------------------- */

/* 32-bit CORE_TICKS is enough for ~107 s at 40 MHz before wrap
   (2^32 / 40e6). The per-pass wall time we target is ~10–20 s
   so we're well inside the range. core_portme.c's
   barebones_clock() reads both mcycleh and mcycle with an
   atomicity check and subtracts to 32-bit so this stays honest. */
#define CORETIMETYPE   ee_u32
typedef ee_u32         CORE_TICKS;

/* --- Seed / memory / threading ------------------------------ */

#ifndef SEED_METHOD
#define SEED_METHOD    SEED_VOLATILE
#endif

#ifndef MEM_METHOD
#define MEM_METHOD     MEM_STACK
#endif

#ifndef MULTITHREAD
#define MULTITHREAD    1
#define USE_PTHREAD    0
#define USE_FORK       0
#define USE_SOCKET     0
#endif

#ifndef MAIN_HAS_NOARGC
#define MAIN_HAS_NOARGC 1
#endif

#ifndef MAIN_HAS_NORETURN
#define MAIN_HAS_NORETURN 0
#endif

extern ee_u32 default_num_contexts;

typedef struct CORE_PORTABLE_S {
    ee_u8 portable_id;
} core_portable;

/* --- Hooks called by CoreMark ------------------------------- */

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

/* Auto-select the run profile when none of the three is forced
   from the command line. Matches upstream barebones. */
#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) && !defined(VALIDATION_RUN)
#if (TOTAL_DATA_SIZE == 1200)
#define PROFILE_RUN     1
#elif (TOTAL_DATA_SIZE == 2000)
#define PERFORMANCE_RUN 1
#else
#define VALIDATION_RUN  1
#endif
#endif

int ee_printf(const char *fmt, ...);

#endif /* CORE_PORTME_H */
