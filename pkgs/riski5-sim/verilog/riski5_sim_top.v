// SPDX-FileCopyrightText: 2026 Mika Tammi
// SPDX-License-Identifier: MIT OR BSD-3-Clause
`timescale 1ns/1ps
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
//      silicon bug on 2026-04-20);
//   4. instantiates an internal `sim_sdram_chip` (defined below)
//      that consumes the chip-side pins riski5 drives via
//      `Riski5.SdrController` — the same RAS/CAS/WE/DQM protocol
//      the IS42S16400 SDRAM on the DE2 board sees. Backing storage
//      is an 8 MB unpacked array. Pre-loaded by the harness over
//      `MEM_INIT_*` ports during reset (kernel + DTB land directly
//      in the simulated SDRAM cells, mirroring what the
//      JTAG-Avalon-Master path does on real silicon).
//
// The Altera IP's generated Verilog uses `//synthesis translate_on`
// / `off` markers, so Verilator automatically picks the simulation
// variant (FIFO write via $write) rather than the synthesis variant
// (alt_jtag_atlantic, which is encrypted and can't be simulated
// outside Quartus).
//
// SDRAM chip model is faithful at the command-protocol level
// (ACTIVATE / READ / WRITE / PRECHARGE / AUTO REFRESH / LMR with
// CL=2 read pipeline + DQM byte mask + per-bank active-row
// tracking) but does NOT model refresh as a data-decay timer —
// AUTO REFRESH commands are accepted as no-ops. That's enough
// to faithfully test the SdrController's emitted command stream
// against the riski5 core under the same kernel image that runs
// on silicon.
module riski5_sim_top (
    // ---- Three-domain clock + reset inputs (Phase E-b) ---------
    //
    // The wrapper exposes one clock + active-low reset per Clash
    // domain (DomBus / DomCore / DomSdram). The harness in
    // tools/linux-hwsim/Main.hs drives these three pairs
    // independently so we can simulate the multi-PLL silicon
    // topology faithfully — bus 40 MHz, core potentially 60-80 MHz,
    // sdram at 100 MHz to chip-spec 133 MHz. The pre-Phase-E
    // wrapper had only `clk`/`rst_n` and the Top.hs CLOCK_CORE /
    // CLOCK_SDRAM ports were missing entirely (Verilator silently
    // ties them to 0, which broke the sim build the moment Phase
    // D-1 added CLOCK_CORE — see commit history of this file).
    //
    // For the simplest single-clock harness, drive all three
    // clk_* inputs with the same waveform; the bridges' tied
    // semantics still work (the bridge runs a synchroniser even
    // when source and dest are physically the same clock, just at
    // single-cycle latency rather than 2). For a true multi-rate
    // run, drive each at its own period — the harness then exercises
    // the toggle-handshake CDC FSMs the same way silicon does.
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clk_core,
    input  wire        rst_core_n,
    input  wire        clk_sdram,
    input  wire        rst_sdram_n,
    input  wire [3:0]  KEY,
    input  wire [17:0] SW,
    // SRAM data-in driven by the harness (SRAM chip simulated host-side)
    input  wire [15:0] SRAM_DQ_I,

    // SDRAM pre-load: the harness writes into the chip's backing
    // memory directly while reset is held, then releases reset and
    // the controller comes up against an already-populated SDRAM.
    // INIT_ADDR is a 22-bit 16-bit-word address (0..4M-1). On every
    // posedge clk where INIT_WRITE=1, INIT_DATA is committed to
    // mem[INIT_ADDR].
    input  wire [21:0] MEM_INIT_ADDR,
    input  wire [15:0] MEM_INIT_DATA,
    input  wire        MEM_INIT_WRITE,

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
    output wire [7:0]  UART_TX_BYTE,

    // --- PC observation tap (Phase E-b debug) ---
    //
    // Live IF-stage program counter from Riski5.Core (the
    // DEBUG_CORE_PC port = pcFetchInCoreS in DomCore). The
    // harness samples this every cycle to build a PC histogram
    // — exactly what we need to bisect "kernel hangs at PC X"
    // silicon bugs in Verilator before round-tripping to the
    // FPGA. NOT to be confused with topEntity's DEBUG_PCFETCH
    // port, which carries the SoC-body's bus-side view of PC
    // (= 0 between bridge transactions in the bridge slave's
    // SIdle/SDone phases). The core-side view is the one a human
    // debugging "where is the kernel hung" wants.
    output wire [31:0] DEBUG_PCFETCH,

    // --- DMEM rdata observation tap (task #52 debug) ---
    //
    // Live bus-side @dmemRdataS@ — the value the SoC body returns
    // to the core's data port for the most recent LW. The harness
    // samples this whenever DEBUG_PCFETCH == 0x801ec464 (the LW
    // in the kernel's irqentry_exit_to_user_mode loop) to identify
    // which thread_info.flags bit is stuck.
    output wire [31:0] DEBUG_DMEM_RDATA,

    // --- Bridge-captured DMEM rdata tap (task #52 debug 2) ---
    //
    // What the bridge actually presents to the core as the LW result
    // (= coreReplyInCoreS.cbrDmemRdata). MAY DIFFER from
    // DEBUG_DMEM_RDATA above: that one shows the bus's combinational
    // mux output at the SAMPLE cycle, which can reflect a stale
    // dataRdataLastS from an earlier LW. This signal is what the
    // core actually consumes for the latest completed LW.
    output wire [31:0] DEBUG_BRIDGE_DMEM_RDATA
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

  // PC tap exposed at sim top (core-side, NOT bus-side — see
  // wrapper port-list comment). dbg_core_pc_w is wired below
  // from the riski5 instance's DEBUG_CORE_PC output.
  assign DEBUG_PCFETCH = dbg_core_pc_w;
  // DMEM rdata tap (task #52). Bus-side view; sourced from the
  // riski5 instance's new DEBUG_DMEM_RDATA output.
  assign DEBUG_DMEM_RDATA = dbg_dmem_rdata_w;
  // Bridge-captured DMEM rdata tap (task #52 debug 2). What the
  // bridge actually delivers to the core for the latest LW.
  assign DEBUG_BRIDGE_DMEM_RDATA = dbg_bridge_dmem_rdata_w;

  // ---- SDRAM chip-side wires (riski5 ⇄ sim_sdram_chip) ---------
  wire [11:0] sdram_addr_w;
  wire [1:0]  sdram_ba_w;
  wire        sdram_cas_n_w;
  wire        sdram_cke_w;
  wire        sdram_cs_n_w;
  wire [15:0] sdram_dq_out_w;
  wire        sdram_dq_oe_w;
  wire [1:0]  sdram_dqm_w;
  wire        sdram_ras_n_w;
  wire        sdram_we_n_w;
  wire [15:0] sdram_dq_in_w;

  // ---- Debug taps -------
  // dbg_pcfetch_w is exposed at sim top as DEBUG_PCFETCH (Phase E-b).
  // dbg_dmem_rdata_w is exposed at sim top as DEBUG_DMEM_RDATA (#52).
  // dbg_bridge_dmem_rdata_w is exposed as DEBUG_BRIDGE_DMEM_RDATA (#52 debug 2).
  // The remaining debug ports below stay dangling — sim doesn't
  // need them yet, and exposing every one inflates the C ABI for
  // no current consumer.
  wire [31:0]  dbg_pcfetch_w;
  wire [31:0]  dbg_dmem_rdata_w;
  wire [31:0]  dbg_bridge_dmem_rdata_w;
  wire [7:0]   dbg_flags_w;
  wire [127:0] dbg_frozen_pc_w;
  wire [31:0]  dbg_frozen_flags_w;

  // ---- JTAG-Avalon-Master read-back ports left dangling --------
  wire [31:0]  jtag_load_rdata_w;
  wire         jtag_load_busy_w;

  // ---- Phase D bridge debug ports left dangling ---------------
  // The Top.hs topEntity exposes these so silicon-side
  // altsource_probes can sample bridge FSM phases + PCs (task #46
  // diagnostics). The sim wrapper doesn't surface them at the C
  // ABI; if a future test wants to assert against them, expose
  // matching outputs here and add them to clash-manifest.json.
  wire [7:0]   dbg_bridge_master_w;
  wire [7:0]   dbg_bridge_slave_w;
  wire [31:0]  dbg_bridge_master_pc_w;
  wire [31:0]  dbg_bridge_slave_pc_w;
  wire [31:0]  dbg_core_pc_w;

  // ----- Clash riski5 core --------------------------------------
  //
  // Tie off everything we don't want the harness to drive:
  //   UART_IRQ            = 0  — sim UART never raises IRQ
  //   DEBUG_RESET_CAPTURE = 0  — no debug-capture state machine
  //   DEBUG_CAPTURE_OFFSET= 0
  //   JTAG_LOAD_*         = 0  — pre-load via SDRAM chip's INIT
  //                              ports instead of routing through
  //                              the L-3 JTAG-load mux
  riski5 u_riski5 (
      .CLOCK_BUS              (clk),
      .RESET_BUS_N            (rst_n),
      // Phase E-b: each domain has its own clock + reset input on
      // the wrapper. The harness in tools/linux-hwsim/Main.hs
      // drives them — same waveform for single-clock runs, distinct
      // periods for multi-PLL bring-up. The SDRAM chip model below
      // is also clocked from clk_sdram so its CL=2 read pipeline
      // stays in lockstep with whatever rate the SDRAM controller
      // is running at.
      .CLOCK_CORE             (clk_core),
      .RESET_CORE_N           (rst_core_n),
      .CLOCK_SDRAM            (clk_sdram),
      .RESET_SDRAM_N          (rst_sdram_n),
      .KEY                    (KEY),
      .SW                     (SW),
      .SRAM_DQ_I              (SRAM_DQ_I),
      .UART_RDATA             (uart_rdata),
      .UART_READY             (uart_ready),
      .UART_IRQ               (1'b0),
      .SDRAM_DQ_IN            (sdram_dq_in_w),
      .DEBUG_RESET_CAPTURE    (1'b0),
      .DEBUG_CAPTURE_OFFSET   (2'b00),
      .JTAG_LOAD_MODE         (1'b0),
      .JTAG_LOAD_ADDR         (32'h00000000),
      .JTAG_LOAD_WDATA        (32'h00000000),
      .JTAG_LOAD_WE           (1'b0),
      .JTAG_LOAD_RD           (1'b0),
      .JTAG_LOAD_BE           (4'h0),
      .LEDR                   (LEDR),
      .LEDG                   (LEDG),
      .LCD_DATA               (LCD_DATA),
      .LCD_RS                 (LCD_RS),
      .LCD_RW                 (LCD_RW),
      .LCD_EN                 (LCD_EN),
      .LCD_ON                 (LCD_ON),
      .LCD_BLON               (LCD_BLON),
      .SRAM_ADDR              (SRAM_ADDR),
      .SRAM_DQ_O              (SRAM_DQ_O),
      .SRAM_DQ_OE             (SRAM_DQ_OE),
      .SRAM_CE_N              (SRAM_CE_N),
      .SRAM_OE_N              (SRAM_OE_N),
      .SRAM_WE_N              (SRAM_WE_N),
      .SRAM_UB_N              (SRAM_UB_N),
      .SRAM_LB_N              (SRAM_LB_N),
      .UART_SEL               (uart_sel),
      .UART_ADDR              (uart_addr),
      .UART_WDATA             (uart_wdata),
      .UART_BE                (uart_be),
      .UART_RE                (uart_re),
      .SDRAM_ADDR_OUT         (sdram_addr_w),
      .SDRAM_BA               (sdram_ba_w),
      .SDRAM_CAS_N            (sdram_cas_n_w),
      .SDRAM_CKE              (sdram_cke_w),
      .SDRAM_CS_N             (sdram_cs_n_w),
      .SDRAM_DQ_OUT           (sdram_dq_out_w),
      .SDRAM_DQ_OE            (sdram_dq_oe_w),
      .SDRAM_DQM              (sdram_dqm_w),
      .SDRAM_RAS_N            (sdram_ras_n_w),
      .SDRAM_WE_N             (sdram_we_n_w),
      .DEBUG_PCFETCH          (dbg_pcfetch_w),
      .DEBUG_DMEM_RDATA       (dbg_dmem_rdata_w),
      .DEBUG_BRIDGE_DMEM_RDATA(dbg_bridge_dmem_rdata_w),
      .DEBUG_FLAGS            (dbg_flags_w),
      .DEBUG_FROZEN_PC        (dbg_frozen_pc_w),
      .DEBUG_FROZEN_FLAGS     (dbg_frozen_flags_w),
      .DEBUG_BRIDGE_MASTER    (dbg_bridge_master_w),
      .DEBUG_BRIDGE_SLAVE     (dbg_bridge_slave_w),
      .DEBUG_BRIDGE_MASTER_PC (dbg_bridge_master_pc_w),
      .DEBUG_BRIDGE_SLAVE_PC  (dbg_bridge_slave_pc_w),
      .DEBUG_CORE_PC          (dbg_core_pc_w),
      .JTAG_LOAD_RDATA        (jtag_load_rdata_w),
      .JTAG_LOAD_BUSY         (jtag_load_busy_w)
  );

  // ----- SDRAM chip model ---------------------------------------
  // Clocked from clk_sdram (Phase E-b): the chip model's CL=2 read
  // pipeline + ACTIVATE/READ/WRITE timing are JEDEC-defined in
  // controller-clock cycles, so the model must run at the same
  // rate as Riski5.SdrController. With the harness driving
  // clk_sdram at 100 MHz (10_000 ps period) and clk at 25_000 ps,
  // the chip model now executes 2.5 commands per bus cycle —
  // matching what the multi-PLL silicon does.
  sim_sdram_chip u_sdram (
      .clk        (clk_sdram),
      .cke        (sdram_cke_w),
      .cs_n       (sdram_cs_n_w),
      .ras_n      (sdram_ras_n_w),
      .cas_n      (sdram_cas_n_w),
      .we_n       (sdram_we_n_w),
      .addr       (sdram_addr_w),
      .ba         (sdram_ba_w),
      .dqm        (sdram_dqm_w),
      .dq_in      (sdram_dq_oe_w ? sdram_dq_out_w : 16'h0000),
      .dq_out     (sdram_dq_in_w),
      .init_addr  (MEM_INIT_ADDR),
      .init_data  (MEM_INIT_DATA),
      .init_write (MEM_INIT_WRITE)
  );

endmodule

// --------------------------------------------------------------
// sim_sdram_chip
// --------------------------------------------------------------
//
// Faithful command-protocol-level model of the IS42S16400 SDRAM
// on the DE2 board:
//   4 banks × 4096 rows × 256 cols × 16-bit data = 8 MB
//
// Implements:
//   - ACTIVATE: latch row address per bank
//   - READ:    schedule data-on-DQ 2 cycles later (CL=2),
//              optionally with auto-precharge (A[10]=1)
//   - WRITE:   commit dq_in[15:0] to mem[bank,row,col] same cycle,
//              honouring DQM byte mask, optionally auto-precharge
//   - PRECHARGE: clear active-row bit (single bank or all banks
//                via A[10])
//   - AUTO REFRESH: accepted, no data decay simulated
//   - LMR (Load Mode Register): accepted, fixed BL=1 / CL=2 (we
//     don't gate behaviour on the LMR write — controller
//     programmes CL=2 BL=1 at boot and never changes it)
//   - NOP / DESELECT: ignored
//
// Pre-load: when init_write is high, mem[init_addr] := init_data
// on posedge clk. The harness drives this while the riski5 core is
// in reset, then releases. After reset the controller goes through
// its 100 µs init sequence (the model accepts the initial PRECHARGE
// + 8 AUTO REFRESHes + LMR no-ops); subsequent reads return the
// pre-loaded bytes.
module sim_sdram_chip (
    input  wire        clk,
    input  wire        cke,
    input  wire        cs_n,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [11:0] addr,
    input  wire [1:0]  ba,
    input  wire [1:0]  dqm,
    input  wire [15:0] dq_in,
    output reg  [15:0] dq_out,

    // Pre-load (harness drives during reset)
    input  wire [21:0] init_addr,
    input  wire [15:0] init_data,
    input  wire        init_write
);

    // 4M × 16-bit words = 8 MB
    reg [15:0] mem [0:4194303];

    // Per-bank open-row state.
    reg [11:0] active_row [0:3];
    reg        active     [0:3];

    // CL=2 read pipeline. JEDEC CL=N: data is valid on DQ on the
    // Nth posedge after the READ command. Implementation:
    //   T_x   : READ command latched. read_d1 := mem[cell],
    //           read_v1 := 1.
    //   T_x+1 : pipeline shifts: read_d2 := read_d1, read_v2 := 1.
    //   T_x+2 : dq_out drives from read_d2. Controller samples
    //           dq_out at this cycle's posedge — sees the data.
    reg [15:0] read_d1, read_d2;
    reg        read_v1, read_v2;
    reg [1:0]  read_dqm1, read_dqm2;

    integer i;
    initial begin
      // One-time loop at sim start. Cost ~32 MB and ~10ms at
      // startup — negligible vs the simulation runtime.
      for (i = 0; i < 4194304; i = i + 1) begin
        mem[i] = 16'h0000;
      end
      for (i = 0; i < 4; i = i + 1) begin
        active_row[i] = 12'h000;
        active[i]     = 1'b0;
      end
      dq_out    = 16'h0000;
      read_d1   = 16'h0000;
      read_d2   = 16'h0000;
      read_v1   = 1'b0;
      read_v2   = 1'b0;
      read_dqm1 = 2'b00;
      read_dqm2 = 2'b00;
    end

    // Decoded SDRAM command. cs_n=1 (deselect) is treated the same
    // as NOP. cs_n=0 with all of ras/cas/we_n=1 is also NOP.
    wire is_active   = (~cs_n) & (~ras_n) & ( cas_n) & ( we_n);
    wire is_read     = (~cs_n) & ( ras_n) & (~cas_n) & ( we_n);
    wire is_write    = (~cs_n) & ( ras_n) & (~cas_n) & (~we_n);
    wire is_pcharge  = (~cs_n) & (~ras_n) & ( cas_n) & (~we_n);
    wire is_aref     = (~cs_n) & (~ras_n) & (~cas_n) & ( we_n);
    wire is_lmr      = (~cs_n) & (~ras_n) & (~cas_n) & (~we_n);

    // Linear word address for the currently-targeted bank+row+col.
    wire [21:0] linear_addr = {ba, active_row[ba], addr[7:0]};

    // Single always block — both the controller's commands and
    // the harness's pre-load writes target mem[]. Putting them in
    // separate always blocks would invoke Verilator's "multiple
    // drivers on RAM array" path, which isn't deterministic.
    always @(posedge clk) begin
      // Pre-load: harness drives init_write while reset is held
      // (cke is low / controller is in init NOP) but we process
      // it unconditionally so it works at any time.
      if (init_write) begin
        mem[init_addr] <= init_data;
      end

      if (cke) begin
        // Pipeline shifts every cycle (default — overridden below
        // by READ if applicable for stage 1).
        read_v1   <= 1'b0;
        read_d2   <= read_d1;
        read_v2   <= read_v1;
        read_dqm2 <= read_dqm1;

        if (is_active) begin
          active_row[ba] <= addr;
          active[ba]     <= 1'b1;
        end else if (is_read) begin
          if (active[ba]) begin
            read_d1 <= mem[linear_addr];
            // Task #52 debug: log reads of chip cells around
            // bus addr 0x80273380 (init_task.flags). Chip cells
            // 0x14E6C0 (low half) and 0x14E6C1 (high half).
            if (linear_addr == 22'h14E6C0 || linear_addr == 22'h14E6C1) begin
              $display("[SDRAM-READ] cell=0x%h returning=0x%h",
                       linear_addr, mem[linear_addr]);
            end
          end else begin
            // Read of an inactive bank — undefined chip behaviour,
            // model as zeros (matches a typical un-written cell).
            read_d1 <= 16'h0000;
          end
          read_v1   <= 1'b1;
          read_dqm1 <= dqm;
          if (addr[10]) active[ba] <= 1'b0; // auto-precharge
        end else if (is_write) begin
          if (active[ba]) begin
            // DQM=1 masks the byte (data ignored). DQM=0 commits.
            if (~dqm[0]) mem[linear_addr][7:0]  <= dq_in[7:0];
            if (~dqm[1]) mem[linear_addr][15:8] <= dq_in[15:8];
            // Task #52 debug: log writes to chip cells around
            // bus addr 0x80273380 (init_task.flags). Chip cells
            // 0x14E6C0 (low half) and 0x14E6C1 (high half).
            if (linear_addr == 22'h14E6C0 || linear_addr == 22'h14E6C1) begin
              $display("[SDRAM-WRITE] cell=0x%h dq_in=0x%h dqm=%b old=0x%h",
                       linear_addr, dq_in, dqm, mem[linear_addr]);
            end
          end
          if (addr[10]) active[ba] <= 1'b0; // auto-precharge
        end else if (is_pcharge) begin
          if (addr[10]) begin
            active[0] <= 1'b0;
            active[1] <= 1'b0;
            active[2] <= 1'b0;
            active[3] <= 1'b0;
          end else begin
            active[ba] <= 1'b0;
          end
        end
        // is_aref / is_lmr / NOP / DESELECT: no memory effect.

        // CL=2: data on DQ at the 2nd posedge after READ. Stage-2
        // of the pipeline drives dq_out, which the controller
        // samples on the next clock edge.
        if (read_v2) begin
          dq_out[7:0]  <= read_dqm2[0] ? 8'h00 : read_d2[7:0];
          dq_out[15:8] <= read_dqm2[1] ? 8'h00 : read_d2[15:8];
        end else begin
          dq_out <= 16'h0000;
        end
      end // if (cke)
    end // always

endmodule
