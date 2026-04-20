// SPDX-FileCopyrightText: 2026 Mika Tammi
// SPDX-License-Identifier: MIT OR BSD-3-Clause
//
// riski5_sim_top — Verilator simulation top for the whole SoC.
//
// This wraps the Clash-emitted `riski5` module together with the
// Altera-IP-generated `riski5_jtag_uart` module (see
// pkgs/riski5-core/package.nix: ip-generate produces it at synthesis
// time; pkgs/riski5-sim consumes the same Verilog in simulation).
// Unlike pkgs/riski5-core's synthesis wrapper `riski5_top.v`, this
// sim-top:
//
//   1. takes clk/rst_n directly as inputs — no PLL (Verilator
//      doesn't synthesize altpll anyway, and we want the sim to
//      run at 1 cycle / Verilator eval for predictability);
//   2. skips the bidirectional SRAM_DQ resolution — SRAM_DQ_I / _O
//      / _OE are exposed as three separate ports the Haskell
//      harness can drive / observe directly;
//   3. exposes a 1-cycle `uart_tx_valid` / `uart_tx_byte[7:0]` tap
//      observing the Altera IP's FIFO write port, so the test
//      harness sees each TX byte the CPU wrote *with the data the
//      IP actually latched* — the whole point of this layer of
//      verification (our pure-Clash `jtagUartSim` model misses the
//      IP's 1-cycle registered-write behaviour that caused a real
//      silicon bug on 2026-04-20).
//
// The Altera IP's generated Verilog uses `//synthesis translate_on`
// / `off` markers, so Verilator automatically picks the simulation
// variant (FIFO write via $write) rather than the synthesis variant
// (alt_jtag_atlantic, which is encrypted and can't be simulated
// outside Quartus). We don't need to do anything extra for that.

`timescale 1ns / 1ps

module riski5_sim_top (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [3:0]  KEY,
    input  wire [17:0] SW,
    input  wire [15:0] SRAM_DQ_I,

    output wire [17:0] LEDR,
    output wire [8:0]  LEDG,

    output wire [7:0]  LCD_DATA,
    output wire        LCD_RS,
    output wire        LCD_RW,
    output wire        LCD_EN,
    output wire        LCD_ON,
    output wire        LCD_BLON,

    output wire [17:0] SRAM_ADDR,
    output wire [15:0] SRAM_DQ_O,
    output wire        SRAM_DQ_OE,
    output wire        SRAM_CE_N,
    output wire        SRAM_OE_N,
    output wire        SRAM_WE_N,
    output wire        SRAM_UB_N,
    output wire        SRAM_LB_N,

    // --- UART TX observation tap ---
    //
    // One-cycle pulse on the cycle the Altera IP's TX FIFO
    // actually latches a byte from av_writedata. Haskell harness
    // samples these to build the TX byte stream.
    output wire        UART_TX_VALID,
    output wire [7:0]  UART_TX_BYTE
);

  // Avalon-MM-like bus tap from the Clash core to the Altera IP.
  wire        uart_sel;
  wire [31:0] uart_addr;
  wire [31:0] uart_wdata;
  wire [3:0]  uart_be;
  wire        uart_re;
  wire [31:0] uart_rdata;
  wire        uart_ready;

  // IP slave signals.
  wire        jtag_uart_wr       = uart_sel & (uart_be != 4'b0);
  wire        jtag_uart_rd       = uart_sel & uart_re;
  wire        jtag_uart_write_n  = ~jtag_uart_wr;
  wire        jtag_uart_read_n   = ~jtag_uart_rd;
  wire [31:0] jtag_uart_readdata;
  wire        jtag_uart_waitrequest;
  wire        jtag_uart_irq;
  wire        jtag_uart_dataavailable;
  wire        jtag_uart_readyfordata;

  riski5_jtag_uart u_jtag_uart (
      .clk            (clk),
      .rst_n          (rst_n),
      .av_chipselect  (uart_sel),
      .av_address     (uart_addr[2]),
      .av_read_n      (jtag_uart_read_n),
      .av_write_n     (jtag_uart_write_n),
      .av_writedata   (uart_wdata),
      .av_readdata    (jtag_uart_readdata),
      .av_waitrequest (jtag_uart_waitrequest),
      .av_irq         (jtag_uart_irq),
      .dataavailable  (jtag_uart_dataavailable),
      .readyfordata   (jtag_uart_readyfordata)
  );

  assign uart_rdata  = jtag_uart_readdata;
  assign uart_ready  = ~jtag_uart_waitrequest;

  // UART-TX tap. The Altera IP commits av_writedata[7:0] to the TX
  // FIFO on the cycle AFTER the master first presented
  // chipselect+~write_n+waitrequest=1 (fifo_wr is registered).
  // Recreate the condition here so the tap fires on the actual
  // FIFO-latch cycle rather than one cycle early.
  reg        wr_pending;
  reg [7:0]  wr_pending_byte;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_pending      <= 1'b0;
      wr_pending_byte <= 8'h00;
    end else begin
      // A transaction commits (IP's internal fifo_wr<=1) when
      // chipselect+~write_n+waitrequest are all asserted AND
      // av_address==0 (DATA register). Capture the byte being
      // written.
      wr_pending <=
          uart_sel & jtag_uart_wr & jtag_uart_waitrequest & (uart_addr[2] == 1'b0);
      wr_pending_byte <= uart_wdata[7:0];
    end
  end
  assign UART_TX_VALID = wr_pending;
  assign UART_TX_BYTE  = wr_pending_byte;

  // ----- Clash riski5 core --------------------------------------
  riski5 u_riski5 (
      .CLOCK_30    (clk),
      .RESET_30_N  (rst_n),
      .KEY         (KEY),
      .SW          (SW),
      .SRAM_DQ_I   (SRAM_DQ_I),
      .UART_RDATA  (uart_rdata),
      .UART_READY  (uart_ready),
      .LEDR        (LEDR),
      .LEDG        (LEDG),
      .LCD_DATA    (LCD_DATA),
      .LCD_RS      (LCD_RS),
      .LCD_RW      (LCD_RW),
      .LCD_EN      (LCD_EN),
      .LCD_ON      (LCD_ON),
      .LCD_BLON    (LCD_BLON),
      .SRAM_ADDR   (SRAM_ADDR),
      .SRAM_DQ_O   (SRAM_DQ_O),
      .SRAM_DQ_OE  (SRAM_DQ_OE),
      .SRAM_CE_N   (SRAM_CE_N),
      .SRAM_OE_N   (SRAM_OE_N),
      .SRAM_WE_N   (SRAM_WE_N),
      .SRAM_UB_N   (SRAM_UB_N),
      .SRAM_LB_N   (SRAM_LB_N),
      .UART_SEL    (uart_sel),
      .UART_ADDR   (uart_addr),
      .UART_WDATA  (uart_wdata),
      .UART_BE     (uart_be),
      .UART_RE     (uart_re)
  );

endmodule
