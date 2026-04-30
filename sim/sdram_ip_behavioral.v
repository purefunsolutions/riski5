// SPDX-FileCopyrightText: 2026 Mika Tammi
// SPDX-License-Identifier: MIT OR BSD-3-Clause
//
// sdram_ip_behavioral — Verilator-friendly behavioral model of
// the Altera altera_avalon_new_sdram_controller IP slave port.
//
// Mirrors what `Riski5.Sdram.sdramIpSim` does on the Haskell side:
// a 16-bit Avalon-MM slave that accepts read/write requests with
// a 1-cycle response latency. Skips:
//
//   - the chip-side init / refresh / ACTIVATE / PRECHARGE
//     (we don't model the SDRAM chip protocol — only the IP's
//     slave-port handshake);
//   - the IP's full pipelining (we use a single registered cycle
//     for valid response).
//
// Storage: a flat array of 16-bit half-words indexed by az_addr
// (which the bridge already passes as a half-word index per the
// Altera IP convention with dataWidth=16). Capacity defaults to
// 64 KiB (= 32 Ki half-words) so testbenches stay light, but a
// MEM_SIZE parameter overrides it.
//
// Useful for catching adapter / bridge bugs that would otherwise
// only surface against the real silicon (task #146 hi-half-word
// write drop is the originating motivator).

`timescale 1ns / 1ps

module sdram_ip_behavioral #(
    parameter integer MEM_SIZE = 65536
) (
    input  wire        clk,
    input  wire        reset_n,

    // Avalon-MM slave (driven by CDC bridge's slave-side outputs)
    input  wire        az_cs,
    input  wire [21:0] az_addr,
    input  wire [15:0] az_data,
    input  wire [1:0]  az_be_n,
    input  wire        az_rd_n,
    input  wire        az_wr_n,

    output reg  [15:0] za_data,
    output reg         za_valid,
    output wire        za_waitrequest
);

    // A single Avalon-MM transaction takes 1 cycle: accept on the
    // cycle the master asserts cs+~rd_n / cs+~wr_n, drop
    // waitrequest=0 immediately, drive za_valid one cycle later
    // for reads. This matches sdramIpSim's behaviour and is enough
    // to flush bridge-side bugs.
    assign za_waitrequest = 1'b0;

    reg [15:0] mem [0:MEM_SIZE-1];

    integer i;
    initial begin
        for (i = 0; i < MEM_SIZE; i = i + 1) mem[i] = 16'h0000;
    end

    wire [21:0] idx = az_addr % MEM_SIZE;
    wire        do_write = az_cs & ~az_wr_n;
    wire        do_read  = az_cs & ~az_rd_n;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            za_data  <= 16'h0000;
            za_valid <= 1'b0;
        end else begin
            za_valid <= 1'b0;
            if (do_write) begin
                // Active-low byte enables. az_be_n[k]=0 means
                // byte k is enabled; az_be_n[k]=1 means preserve.
                if (~az_be_n[0]) mem[idx][7:0]  <= az_data[7:0];
                if (~az_be_n[1]) mem[idx][15:8] <= az_data[15:8];
            end else if (do_read) begin
                za_data  <= mem[idx];
                za_valid <= 1'b1;
            end
        end
    end

endmodule
