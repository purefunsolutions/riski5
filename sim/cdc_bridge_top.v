// SPDX-FileCopyrightText: 2026 Mika Tammi
// SPDX-License-Identifier: MIT OR BSD-3-Clause
//
// cdc_bridge_top — Verilator simulation top wiring the
// riski5_sdram_cdc_bridge to a behavioral SDRAM IP model. The
// C++ testbench (cdc_bridge_test.cpp) drives this module's
// master-side ports, peeks the slave-side, and verifies the
// bridge's hi-half / lo-half write commit pattern.

`timescale 1ns / 1ps

module cdc_bridge_top (
    input  wire        clkBus,
    input  wire        rstBus_n,
    input  wire        clkSdram,
    input  wire        rstSdram_n,

    // Master-side Avalon-MM (driven by C++ testbench)
    input  wire        m_cs,
    input  wire [21:0] m_addr,
    input  wire [15:0] m_wdata,
    input  wire [1:0]  m_be,
    input  wire        m_rd,
    input  wire        m_wr,
    output wire [15:0] m_rdata,
    output wire        m_valid,
    output wire        m_waitrequest
);

    // Slave-side wires (bridge → behavioral IP)
    wire        s_cs;
    wire [21:0] s_addr;
    wire [15:0] s_wdata;
    wire [1:0]  s_be;
    wire        s_rd;
    wire        s_wr;
    wire [15:0] s_rdata;
    wire        s_valid;
    wire        s_waitrequest;

    // Debug taps (unused in the testbench but present in the
    // bridge's port list).
    wire [1:0]  dbg_m_state;
    wire [1:0]  dbg_s_state;
    wire        dbg_req_toggle_bus;
    wire        dbg_done_toggle_sdram;
    wire [15:0] dbg_cap_rdata_sdram;
    wire [21:0] dbg_m_lat_addr;

    riski5_sdram_cdc_bridge u_bridge (
        .clkBus(clkBus), .rstBus_n(rstBus_n),
        .m_cs(m_cs), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_be(m_be), .m_rd(m_rd), .m_wr(m_wr),
        .m_rdata(m_rdata), .m_valid(m_valid),
        .m_waitrequest(m_waitrequest),

        .clkSdram(clkSdram), .rstSdram_n(rstSdram_n),
        .s_cs(s_cs), .s_addr(s_addr), .s_wdata(s_wdata),
        .s_be(s_be), .s_rd(s_rd), .s_wr(s_wr),
        .s_rdata(s_rdata), .s_valid(s_valid),
        .s_waitrequest(s_waitrequest),

        .dbg_m_state(dbg_m_state),
        .dbg_s_state(dbg_s_state),
        .dbg_req_toggle_bus(dbg_req_toggle_bus),
        .dbg_done_toggle_sdram(dbg_done_toggle_sdram),
        .dbg_cap_rdata_sdram(dbg_cap_rdata_sdram),
        .dbg_m_lat_addr(dbg_m_lat_addr)
    );

    sdram_ip_behavioral u_ip (
        .clk(clkSdram), .reset_n(rstSdram_n),
        .az_cs(s_cs),
        .az_addr(s_addr),
        .az_data(s_wdata),
        .az_be_n(~s_be),
        .az_rd_n(~s_rd),
        .az_wr_n(~s_wr),
        .za_data(s_rdata),
        .za_valid(s_valid),
        .za_waitrequest(s_waitrequest)
    );

endmodule
