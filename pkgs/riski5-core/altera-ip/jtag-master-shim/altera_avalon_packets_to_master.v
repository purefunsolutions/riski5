// SPDX-FileCopyrightText: 2026 Mika Tammi
// SPDX-License-Identifier: MIT OR BSD-3-Clause
//
// Drop-in replacement for Altera's `altera_avalon_packets_to_master`
// state machine inside the `altera_jtag_avalon_master` IP composition.
//
// The original Altera component (in
// $QUARTUS_ROOT/ip/altera/sopc_builder_ip/altera_avalon_packets_to_master/)
// silently drops 50–75 % of master writes during high-rate JTAG
// bursts (silicon-verified by the L-3b sentinel test in
// firmware/phase1/LinuxBootMaster.hs — see task #133 in
// .claude/projects/-home-mika-riski5/memory/project_avalon_master_state.md).
//
// This shim:
//   1. Re-uses the original module NAME and PORT LIST so the IP
//      composition's auto-generated wrapper (riski5_jtag_master.v)
//      can instantiate it unchanged.
//   2. Re-declares the same `parameter` list (EXPORT_MASTER_SIGNALS,
//      FIFO_DEPTHS, FIFO_WIDTHU, FAST_VER) so any `#(.FAST_VER(1), …)`
//      override at the instantiation site type-checks. The
//      parameters are intentionally unused — our Clash bridge
//      below has fixed depth/throughput characteristics that don't
//      depend on them.
//   3. Wraps the Clash-emitted `riski5_jtag_avalon_master` module
//      (compiled from src/Riski5/JtagAvalonMaster.hs) under the
//      Altera module name so the rest of the IP composition stays
//      stock-Altera.
//   4. Exposes diagnostic counters (bytes_in_cnt, writes_commit_cnt,
//      reads_commit_cnt — task #133) via three altsource_probe SLD
//      instances so the host can read them via JTAG hub
//      (`read_probe_data jtag_master_bytes_in` etc.) without the
//      counters needing to plumb up through the IP composition
//      wrapper. The probes are self-contained SLD nodes; they
//      register with the JTAG hub the same way the existing JTAG_LOAD
//      probes do (see riski5_top.v's iter_counter_probe).
//
// Build hookup: pkgs/riski5-core/package.nix's buildPhase strips
// the Altera-provided `altera_avalon_packets_to_master.v` from the
// VERILOG_FILE list emitted to Riski5.qsf and adds this shim plus
// the Clash output instead.

`timescale 1ns / 100ps

module altera_avalon_packets_to_master (
    input  wire        clk,
    input  wire        reset_n,

    // Avalon-ST in (from bytes_to_packets via channel_adapter)
    output wire        in_ready,
    input  wire        in_valid,
    input  wire [7:0]  in_data,
    input  wire        in_startofpacket,
    input  wire        in_endofpacket,

    // Avalon-ST out (to channel_adapter → packets_to_bytes)
    input  wire        out_ready,
    output wire        out_valid,
    output wire [7:0]  out_data,
    output wire        out_startofpacket,
    output wire        out_endofpacket,

    // Avalon-MM master
    output wire [31:0] address,
    input  wire [31:0] readdata,
    output wire        read,
    output wire        write,
    output wire [3:0]  byteenable,
    output wire [31:0] writedata,
    input  wire        waitrequest,
    input  wire        readdatavalid
);

    parameter EXPORT_MASTER_SIGNALS = 0;
    parameter FIFO_DEPTHS           = 2;
    parameter FIFO_WIDTHU           = 1;
    parameter FAST_VER              = 0;

    // Diagnostic counters from the Clash FSM (task #133).
    wire [31:0] jam_bytes_in_cnt;
    wire [31:0] jam_writes_commit_cnt;
    wire [31:0] jam_reads_commit_cnt;

    riski5_jtag_avalon_master u_clash_p2m (
        .clk               (clk),
        .reset_n           (reset_n),
        .in_valid          (in_valid),
        .in_data           (in_data),
        .in_startofpacket  (in_startofpacket),
        .in_endofpacket    (in_endofpacket),
        .out_ready         (out_ready),
        .readdata          (readdata),
        .waitrequest       (waitrequest),
        .readdatavalid     (readdatavalid),
        .in_ready          (in_ready),
        .out_valid         (out_valid),
        .out_data          (out_data),
        .out_startofpacket (out_startofpacket),
        .out_endofpacket   (out_endofpacket),
        .address           (address),
        .read              (read),
        .write             (write),
        .byteenable        (byteenable),
        .writedata         (writedata),
        .bytes_in_cnt      (jam_bytes_in_cnt),
        .writes_commit_cnt (jam_writes_commit_cnt),
        .reads_commit_cnt  (jam_reads_commit_cnt)
    );

    // ----- Diagnostic SLD probes ------------------------------------
    // Three 32-bit altsource_probe instances that snapshot the FSM's
    // counters every cycle. The host reads them with quartus_stp /
    // System Console using the instance_id ASCII tag below, e.g.:
    //
    //   read_probe_data [lindex [get_service_paths probe] N]
    //
    // Tag legend:
    //   "JBIN"  = JTAG-Master Bytes IN at Avalon-ST input  (4 byte chars)
    //   "JWRC"  = JTAG-Master WRites Commit at Avalon-MM output
    //   "JRDC"  = JTAG-Master ReaDs Commit
    //
    // Each character maps onto the lpm_decorator[]-encoded
    // `instance_id` field altsource_probe consumes — Quartus matches
    // these 4-byte tags exactly. Width=32 matches our counter width.

    altsource_probe #(
        .lpm_type                 ("altsource_probe"),
        .lpm_hint                 ("CBX_AUTO_BLACKBOX=ALL"),
        .source_width             (0),
        .probe_width              (32),
        .instance_id              ("JBIN"),
        .sld_auto_instance_index  ("YES"),
        .sld_instance_index       (0),
        .sld_ir_width             (3),
        .source_initial_value     ("0"),
        .enable_metastability     ("NO")
    ) u_probe_bytes_in (
        .source     (),
        .probe      (jam_bytes_in_cnt),
        .source_clk (1'b0),
        .source_ena (1'b1)
    );

    altsource_probe #(
        .lpm_type                 ("altsource_probe"),
        .lpm_hint                 ("CBX_AUTO_BLACKBOX=ALL"),
        .source_width             (0),
        .probe_width              (32),
        .instance_id              ("JWRC"),
        .sld_auto_instance_index  ("YES"),
        .sld_instance_index       (0),
        .sld_ir_width             (3),
        .source_initial_value     ("0"),
        .enable_metastability     ("NO")
    ) u_probe_writes_commit (
        .source     (),
        .probe      (jam_writes_commit_cnt),
        .source_clk (1'b0),
        .source_ena (1'b1)
    );

    altsource_probe #(
        .lpm_type                 ("altsource_probe"),
        .lpm_hint                 ("CBX_AUTO_BLACKBOX=ALL"),
        .source_width             (0),
        .probe_width              (32),
        .instance_id              ("JRDC"),
        .sld_auto_instance_index  ("YES"),
        .sld_instance_index       (0),
        .sld_ir_width             (3),
        .source_initial_value     ("0"),
        .enable_metastability     ("NO")
    ) u_probe_reads_commit (
        .source     (),
        .probe      (jam_reads_commit_cnt),
        .source_clk (1'b0),
        .source_ena (1'b1)
    );

endmodule
