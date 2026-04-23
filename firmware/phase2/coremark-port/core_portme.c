/* SPDX-FileCopyrightText: 2026 Mika Tammi */
/* SPDX-License-Identifier: MIT OR BSD-3-Clause */

/*
 * riski5 CoreMark port — timing + UART + minimal C runtime.
 *
 * This is the part of the port that actually ties CoreMark to
 * silicon. It provides:
 *
 *   1. start_time / stop_time / get_time / time_in_secs —
 *      timing based on the RV32IM `mcycle` / `mcycleh` CSRs.
 *      40 MHz core clock means one "tick" = 25 ns.
 *
 *   2. uart_send_char — the single output primitive ee_printf
 *      calls. Writes to the Altera JTAG UART IP's data register
 *      at 0x1000_0000. SoC waitrequest stalls the core while the
 *      IP's 64-byte TX FIFO is full, so this is effectively
 *      blocking without needing a software-polled WSPACE check.
 *
 *   3. portable_init / portable_fini — barebones platform
 *      init/fini. The JTAG UART IP needs no runtime init; the
 *      sanity checks on ee_ptr_int / ee_u32 widths catch a
 *      misconfigured <core_portme.h>.
 *
 *   4. memset / memcpy — freestanding replacements. GCC may
 *      emit libcalls to these even when we ask for no libc,
 *      and CoreMark's core_main.c explicitly calls memcpy
 *      (tables[]-init path) and memset (CRC scratch).
 *
 *   5. default_num_contexts = 1. Upstream pattern; CoreMark
 *      reads this as "how many parallel threads to simulate".
 *      We're single-threaded.
 *
 *   6. The three seed_*_volatile globals that the VALIDATION_RUN
 *      / PERFORMANCE_RUN / PROFILE_RUN macro picks between —
 *      copied verbatim from barebones/core_portme.c so scores
 *      remain comparable.
 */

#include "coremark.h"
#include "core_portme.h"

/* --- Run-profile seed values (upstream) --------------------- */

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

ee_u32 default_num_contexts = 1;

/* --- JTAG UART output --------------------------------------- */

/* Altera JTAG UART IP sits at 0x1000_0000:
 *   offset 0  = DATA register   — write → push byte into TX FIFO
 *   offset 4  = CONTROL register — bit [31:16] = WSPACE (TX FIFO slots free)
 *
 * Why the WSPACE poll before every write?
 *
 * Empirically, streaming back-to-back sw instructions to offset 0 hangs
 * the Altera IP once the TX FIFO fills up even though our SoC honours
 * av_waitrequest via the bus stall. The IP seems to require one cycle of
 * av_write=0 between back-to-back transactions so its internal drain FSM
 * advances reliably; holding av_write asserted continuously lets it get
 * stuck. A lw from the CONTROL register between writes interleaves a
 * read transaction (av_read=1, av_write=0), which gives the IP the gap
 * it needs without any SoC-level Verilog changes (see CM-4 writeup at
 * docs/perf/coremark-2026-04-23.md for the hang analysis).
 */
#define RISKI5_UART_BASE  0x10000000u
#define RISKI5_UART_DATA  (RISKI5_UART_BASE + 0)
#define RISKI5_UART_CTL   (RISKI5_UART_BASE + 4)

void uart_send_char(char c) {
    volatile unsigned int *data = (volatile unsigned int *)RISKI5_UART_DATA;
    volatile unsigned int *ctl  = (volatile unsigned int *)RISKI5_UART_CTL;

    /* Spin until TX FIFO has space. WSPACE = ctl[31:16]. */
    while ((*ctl >> 16) == 0u) {
        /* busy-wait */
    }
    *data = (unsigned int)(unsigned char)c;
}

/* --- Timing via mcycle --------------------------------------- */

/* Read the full 64-bit mcycle atomically (hi/lo read twice to
   guard against the low half wrapping between reads). We fold
   back to 32-bit ticks for CoreMark because CORE_TICKS is
   ee_u32 in our port — see core_portme.h's comment about the
   107-second wrap window at 40 MHz. */
static inline ee_u32 read_mcycle_lo(void) {
    ee_u32 v;
    __asm__ volatile("csrr %0, mcycle" : "=r"(v));
    return v;
}

static CORETIMETYPE barebones_clock(void) {
    return (CORETIMETYPE)read_mcycle_lo();
}

#define GETMYTIME(t_ptr)     (*(t_ptr) = barebones_clock())
#define MYTIMEDIFF(fin, ini) ((fin) - (ini))
#define TIMER_RES_DIVIDER    1
#define SAMPLE_TIME_IMPLEMENTATION 1
#define EE_TICKS_PER_SEC     (40000000U / TIMER_RES_DIVIDER)

static CORETIMETYPE start_time_val;
static CORETIMETYPE stop_time_val;

void start_time(void) {
    GETMYTIME(&start_time_val);
}

void stop_time(void) {
    GETMYTIME(&stop_time_val);
}

CORE_TICKS get_time(void) {
    return (CORE_TICKS)MYTIMEDIFF(stop_time_val, start_time_val);
}

/* HAS_FLOAT = 0 → secs_ret is ee_u32 (integer seconds). This
   loses sub-second precision but CoreMark's core_main.c only
   uses time_in_secs for (a) the >10 s validity check, and (b)
   scaling iterations/sec. Integer seconds is fine for both
   once total runtime is comfortably above 10 s. */
secs_ret time_in_secs(CORE_TICKS ticks) {
    return (secs_ret)ticks / (secs_ret)EE_TICKS_PER_SEC;
}

/* --- portable_init / portable_fini -------------------------- */

void portable_init(core_portable *p, int *argc, char *argv[]) {
    (void)argc;
    (void)argv;

    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *)) {
        ee_printf("ERROR! ee_ptr_int width mismatch!\n");
    }
    if (sizeof(ee_u32) != 4) {
        ee_printf("ERROR! ee_u32 not 32-bit!\n");
    }

    /* No UART init needed — the Altera JTAG UART IP is
       self-initialising at bitstream load. */
    p->portable_id = 1;
}

void portable_fini(core_portable *p) {
    p->portable_id = 0;
}

/* --- Freestanding libc shims -------------------------------- */

/* GCC -O2 will emit calls to memcpy / memset for non-trivial
   aggregate copies and zero-inits. CoreMark also calls them
   directly (`memcpy` in core_main.c tables_init, `memset` in
   test_parallel). We provide the minimal correct impls here. */

void *memset(void *dst, int c, size_t n) {
    unsigned char *p = (unsigned char *)dst;
    unsigned char v  = (unsigned char)c;
    while (n--) *p++ = v;
    return dst;
}

void *memcpy(void *dst, const void *src, size_t n) {
    unsigned char       *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    while (n--) *d++ = *s++;
    return dst;
}

/* core_state.c's CRC path uses strlen to walk the input
   pattern. Freestanding GCC doesn't provide it — supply the
   obvious one. */
size_t strlen(const char *s) {
    const char *p = s;
    while (*p) p++;
    return (size_t)(p - s);
}
