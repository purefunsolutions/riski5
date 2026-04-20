// SPDX-FileCopyrightText: 2026 Mika Tammi
// SPDX-License-Identifier: MIT OR BSD-3-Clause
//
// riscv-formal wrapper module for riski5.
//
// Pattern mirrors cores/nerv/wrapper.sv in the riscv-formal tree:
//
//   - rvformal_rand_reg provides the symbolic inputs the harness
//     needs (imem_rdata, dmem_rdata). SymbiYosys can set them
//     freely each cycle to explore the full input space.
//
//   - `RVFI_OUTPUTS declares every rvfi_* output port on this
//     wrapper module so the harness can see them.
//
//   - `RVFI_CONN32 is the canonical glue between riski5_formal's
//     flat rvfi_* ports (named exactly as in the RVFI spec) and
//     the wrapper's RVFI outputs — the macro does the 1:1 port
//     mapping for us.
//
// `ifdef RISCV_FORMAL_BUS blocks are absent on purpose. Phase-1
// riscv-formal scope is the in-core proofs (insn_*, pc_*, reg,
// causal, ill, …); bus-fault proofs would need a matching set
// of RISCV_FORMAL_MEM_FAULT macros + the fault injection
// plumbing inside the core. Revisit when phase-1 proofs close.
//
// Assumes stall is tied off false — the core's stall input
// exists for multi-cycle slaves on the real SoC, but the
// formal view has single-cycle abstract memory, so no stall is
// ever needed.

module rvfi_wrapper (
    input clock,
    input reset,
    `RVFI_OUTPUTS
);
  // Symbolic instruction and data read words drive the core each
  // cycle. The harness constrains them via its per-check
  // assumptions (e.g. the `insn_add` check fixes the top 25 bits
  // to the ADD opcode + funct7 pattern).
  (* keep *) `rvformal_rand_reg [31:0] imem_rdata;
  (* keep *) `rvformal_rand_reg [31:0] dmem_rdata;

  // The core itself drives the addresses/writes, so they're
  // plain wires from the DUT — not rand_reg.
  wire [31:0] imem_addr;
  wire [31:0] dmem_addr;
  wire [31:0] dmem_wdata;
  wire  [3:0] dmem_wmask;
  wire        dmem_ren;

  riski5_formal dut (
      .clk        (clock),
      .rst_n      (~reset),
      .imem_rdata (imem_rdata),
      .dmem_rdata (dmem_rdata),
      .imem_addr  (imem_addr),
      .dmem_addr  (dmem_addr),
      .dmem_wdata (dmem_wdata),
      .dmem_wmask (dmem_wmask),
      .dmem_ren   (dmem_ren),
      `RVFI_CONN32
  );
endmodule
