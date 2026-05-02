# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# Timing constraints for the riski5 design on the Altera DE2
# (Cyclone II EP2C35F672C6). Single-PLL topology — task #146 dropped
# the second SDRAM PLL when the Altera SDRAM Controller IP and the
# CDC bridge were replaced by the pure-Clash SDR controller in
# 'Riski5.SdrController' running on clkBus. The DRAM_CLK output is
# driven from the PLL's clk2 (+90° phase-shifted from clkBus) so
# the chip's clock edge falls in the middle of the FPGA's stable
# DQ / command window after the I/O-cell Tco — see the package.nix
# u_altpll comment block and the FAST_OUTPUT_REGISTER assignments
# in Riski5.qsf.

create_clock -name clk50 -period 20.000 [get_ports CLOCK_50]
create_clock -name clk27 -period 37.037 [get_ports CLOCK_27]
derive_pll_clocks
derive_clock_uncertainty

# Over-constrain the PLL's bus clock by 2 ns of extra setup
# uncertainty. Silicon runs at 40 MHz (25 ns period); telling
# TimeQuest to assume 2 ns more skew forces the fitter to find
# data paths that fit in 23 ns instead of 25. Kills the Quartus
# 13.0sp1 placement lottery that lets two builds from identical
# Verilog produce different .sof files — both reporting the same
# +2.4 ns worst-case slack, but with subtly different placement
# of BRAM / SRAM controller paths near the timing tipping point;
# CoreMark can silently corrupt on one bitstream and run clean
# on another despite STA being happy with both. The over-
# constraint forces every build into the safe-margin region.
# DRAM_CLK is exempt — its source-synchronous +90° relationship
# already has a hand-tuned ±0.5 ns trace allowance baked into
# the set_input_delay / set_output_delay budgets below.
set_clock_uncertainty \
    -setup -add 2.0 \
    -from [get_clocks {u_altpll|pll|clk[0]}] \
    -to   [get_clocks {u_altpll|pll|clk[0]}]

# Async reset input from KEY[0] is intentionally exempt from timing.
set_false_path -from [get_ports KEY[0]] -to [all_registers]

# LCD pins are driven by an FSM that counts dozens of clock cycles
# between transitions; the external LCD chip doesn't care about
# setup/hold at the FPGA clock rate. A multicycle / false_path
# constraint could be added here if the fitter ever complains; for
# now we leave the defaults.

# -- SDRAM chip-side I/O timing -------------------------------------
# Source-synchronous interface on a single 40 MHz domain. clk2 of
# u_altpll (+90° phase-shifted, so +6.25 ns at 25 ns period) is
# routed straight to DRAM_CLK; we mirror that with an explicit
# create_generated_clock so TimeQuest models the I/O-cell Tco on
# the DRAM_CLK pin and uses it as the reference for the chip-side
# data + command paths.
create_generated_clock -name dram_clk \
    -source [get_pins -compatibility_mode {*u_altpll*|clk[2]}] \
    [get_ports DRAM_CLK]

# IS42S16400-7TL chip-side timing (datasheet, -7TL grade):
#
#   Inputs (FPGA → chip):
#     t_DS  = 1.5 ns  setup time before chip's CLK rising edge
#     t_DH  = 0.8 ns  hold time after chip's CLK rising edge
#
#   Outputs (chip → FPGA, READ data on DRAM_DQ):
#     t_AC  = 5.4 ns  CLK → DQ valid    (max, -7TL)
#     t_OH  = 2.5 ns  CLK → DQ hold     (min, -7TL)
#
# We add ~0.5 ns of board-trace allowance on each side (the DE2's
# DRAM_DQ traces are short — the chip sits next to the FPGA — but
# leaving headroom is cheap).

# DE2 SDRAM signals driven by the FPGA. Includes write data, all
# command pins, address, bank, and per-byte mask. DRAM_CLK is
# excluded because it IS the reference, not a referenced output.
set dram_outputs [get_ports {DRAM_DQ[*] DRAM_ADDR[*] DRAM_BA[*] \
                              DRAM_RAS_N DRAM_CAS_N DRAM_WE_N    \
                              DRAM_CS_N DRAM_CKE                  \
                              DRAM_LDQM DRAM_UDQM}]
set_output_delay -clock dram_clk -max  2.0 $dram_outputs
set_output_delay -clock dram_clk -min -1.3 $dram_outputs

# DRAM_DQ as inputs (READ data path, chip → FPGA).
set_input_delay  -clock dram_clk -max  6.0 [get_ports DRAM_DQ[*]]
set_input_delay  -clock dram_clk -min  2.0 [get_ports DRAM_DQ[*]]
