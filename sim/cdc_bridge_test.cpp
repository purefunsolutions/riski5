// SPDX-FileCopyrightText: 2026 Mika Tammi
// SPDX-License-Identifier: MIT OR BSD-3-Clause
//
// cdc_bridge_test — Verilator C++ testbench for the
// riski5_sdram_cdc_bridge module + behavioral SDRAM IP. Drives
// 32-bit and 16-bit Avalon-MM master transactions and verifies
// the bridge propagates them through to the IP correctly.
//
// Reproduces the task #146 "hi-half-word write drop" pattern
// that boot-linux-master was hitting on silicon. If the bridge
// is the bug source, this testbench will see the exact same
// drop pattern in pure Verilator simulation.
//
// Build (under nix develop):
//
//     nix run .#cdc-bridge-test
//
// Exit: 0 = all PASS, 1 = any FAIL.

#include "Vcdc_bridge_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <cstdio>
#include <cstdint>
#include <cstdlib>

static Vcdc_bridge_top* dut = nullptr;
static VerilatedVcdC*  trace = nullptr;
static uint64_t        sim_time = 0;
static int             tests = 0;
static int             passed = 0;
static int             failed = 0;

// One bus + sdram clock tick. Bus is 40 MHz (= 25 ns), SDRAM is
// 108 MHz (= 9.26 ns). For simplicity the testbench uses a 2:1
// ratio (bus = 1 step, sdram = 2 steps) — enough to exercise
// CDC paths without modelling the exact frequencies.
static void tick_bus() {
    dut->clkBus = 0;
    dut->clkSdram = !dut->clkSdram;
    dut->eval();
    if (trace) trace->dump(sim_time++);

    dut->clkSdram = !dut->clkSdram;
    dut->eval();
    if (trace) trace->dump(sim_time++);

    dut->clkBus = 1;
    dut->clkSdram = !dut->clkSdram;
    dut->eval();
    if (trace) trace->dump(sim_time++);

    dut->clkSdram = !dut->clkSdram;
    dut->eval();
    if (trace) trace->dump(sim_time++);
}

static void reset() {
    dut->rstBus_n = 0;
    dut->rstSdram_n = 0;
    dut->m_cs = 0; dut->m_addr = 0; dut->m_wdata = 0;
    dut->m_be = 0; dut->m_rd = 0; dut->m_wr = 0;
    dut->clkBus = 0; dut->clkSdram = 0;
    for (int i = 0; i < 8; i++) tick_bus();
    dut->rstBus_n = 1;
    dut->rstSdram_n = 1;
    for (int i = 0; i < 8; i++) tick_bus();
}

// Issue a single 16-bit Avalon-MM write to the bridge's master
// side. Holds m_cs+m_wr until the bridge drops m_waitrequest,
// then drops both. Returns true if the write completed within
// max_cycles bus ticks.
static bool master_write(uint32_t addr, uint16_t data, uint8_t be) {
    dut->m_addr = addr;
    dut->m_wdata = data;
    dut->m_be = be;
    dut->m_wr = 1;
    dut->m_cs = 1;
    dut->m_rd = 0;
    dut->eval();

    // Hold until waitrequest drops.
    int max_cycles = 200;
    while (dut->m_waitrequest && max_cycles--) {
        tick_bus();
    }
    if (max_cycles <= 0) {
        dut->m_cs = 0; dut->m_wr = 0;
        return false;
    }
    // One more tick to commit the write to the bridge's M_DONE_W.
    tick_bus();
    dut->m_cs = 0; dut->m_wr = 0; dut->m_be = 0;
    // Drain a few extra cycles so the slave-side completes its
    // write to the IP before we issue the next request.
    for (int i = 0; i < 8; i++) tick_bus();
    return true;
}

// Issue a single 16-bit read. Returns the read value, or 0xFFFF
// if it timed out.
static uint16_t master_read(uint32_t addr) {
    dut->m_addr = addr;
    dut->m_rd = 1;
    dut->m_cs = 1;
    dut->m_wr = 0;
    dut->m_be = 0;
    dut->eval();

    int max_cycles = 200;
    while (dut->m_waitrequest && max_cycles--) tick_bus();
    if (max_cycles <= 0) {
        dut->m_cs = 0; dut->m_rd = 0;
        return 0xFFFF;
    }
    // m_valid pulses one cycle after waitrequest drops.
    int wait = 32;
    while (!dut->m_valid && wait--) tick_bus();
    uint16_t v = dut->m_rdata;
    dut->m_cs = 0; dut->m_rd = 0;
    for (int i = 0; i < 8; i++) tick_bus();
    return v;
}

static void check_eq(uint16_t got, uint16_t want, const char* label, uint32_t addr) {
    tests++;
    if (got == want) {
        passed++;
        printf("  PASS  %-40s addr=0x%06x : 0x%04x\n", label, addr, got);
    } else {
        failed++;
        printf("  FAIL  %-40s addr=0x%06x : got 0x%04x  want 0x%04x\n",
               label, addr, got, want);
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    dut = new Vcdc_bridge_top;
    if (argc > 1 && std::string(argv[1]) == "--trace") {
        trace = new VerilatedVcdC;
        dut->trace(trace, 99);
        trace->open("cdc_bridge_test.vcd");
    }

    printf("================================================================\n");
    printf(" CDC bridge + behavioral SDRAM IP testbench (task #146)\n");
    printf("================================================================\n\n");

    reset();

    // Test 1: write-then-read at LO half-word index (even addr).
    printf("--- Test 1: 16-bit writes to EVEN half-word indices (= LO half) ---\n");
    {
        uint16_t patterns[] = {0xAAAA, 0x5555, 0x1234, 0xFFFF};
        uint32_t base = 0x000100;  // half-word index, LSB = 0
        for (size_t i = 0; i < sizeof(patterns)/sizeof(patterns[0]); i++) {
            uint32_t addr = base + i*2;  // step by 2 half-words to land in adjacent 32-bit words
            master_write(addr, patterns[i], 0b11);
            uint16_t rb = master_read(addr);
            check_eq(rb, patterns[i], "16-bit LO write+read", addr);
        }
    }

    // Test 2: write-then-read at HI half-word index (odd addr).
    printf("\n--- Test 2: 16-bit writes to ODD half-word indices (= HI half) ---\n");
    {
        uint16_t patterns[] = {0xAAAA, 0x5555, 0x1234, 0xFFFF};
        uint32_t base = 0x000201;  // half-word index, LSB = 1 → upper half
        for (size_t i = 0; i < sizeof(patterns)/sizeof(patterns[0]); i++) {
            uint32_t addr = base + i*2;
            master_write(addr, patterns[i], 0b11);
            uint16_t rb = master_read(addr);
            check_eq(rb, patterns[i], "16-bit HI write+read", addr);
        }
    }

    // Test 3: pair (lo, hi) write — both halves of a 32-bit word.
    printf("\n--- Test 3: lo+hi pair (mimics SDRAM adapter SWriteLoReq+SWriteHiReq) ---\n");
    {
        struct { uint16_t lo, hi; uint32_t base; } cases[] = {
            { 0xBEEF, 0xDEAD, 0x000300 },
            { 0xF00D, 0xCAFE, 0x000302 },
            { 0x5678, 0x1234, 0x000304 },
        };
        for (size_t i = 0; i < sizeof(cases)/sizeof(cases[0]); i++) {
            // Write LO half first
            master_write(cases[i].base + 0, cases[i].lo, 0b11);
            // Then HI half (just like the SDRAM adapter does for a 32-bit write)
            master_write(cases[i].base + 1, cases[i].hi, 0b11);
            uint16_t lo = master_read(cases[i].base + 0);
            uint16_t hi = master_read(cases[i].base + 1);
            check_eq(lo, cases[i].lo, "lo of pair-write", cases[i].base + 0);
            check_eq(hi, cases[i].hi, "hi of pair-write", cases[i].base + 1);
        }
    }

    if (trace) trace->close();
    delete dut;
    delete trace;

    printf("\n================================================================\n");
    printf(" summary: %d passed, %d failed of %d total\n", passed, failed, tests);
    printf("================================================================\n");
    return failed > 0 ? 1 : 0;
}
