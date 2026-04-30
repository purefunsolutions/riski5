# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# Timing constraints for the riski5 design on the Altera DE2
# (Cyclone II EP2C35F672C6). Phase-1B targets the board's 50 MHz
# oscillator directly (no PLL yet); phase 1E will revisit once we
# explore maxing out fmax.

create_clock -name clk50 -period 20.000 [get_ports CLOCK_50]
create_clock -name clk27 -period 37.037 [get_ports CLOCK_27]
derive_pll_clocks
derive_clock_uncertainty

# Async reset input from KEY[0] is intentionally exempt from timing.
set_false_path -from [get_ports KEY[0]] -to [all_registers]

# LCD pins are driven by an FSM that counts dozens of clock cycles
# between transitions; the external LCD chip doesn't care about
# setup/hold at the FPGA clock rate. A multicycle / false_path
# constraint could be added here if the fitter ever complains; for
# now we leave the defaults.

# -- SDRAM (DRAM_CLK output) ----------------------------------------
# Multi-PLL topology (task #141) — see comment block in
# pkgs/riski5-core/package.nix around the u_altpll / u_altpll_sdram
# instantiations for the full clock map.
#
# DRAM_CLK is sourced from u_altpll_sdram|clk[1] — a -3 ns
# phase-shifted copy of clkSdram (30 MHz). The phase shift puts the
# SDRAM chip's rising edge ~3 ns AFTER the FPGA-side controller's
# rising edge, covering Tco + trace delay. Standard Altera SDRAM
# Controller deployment pattern; this is the pattern that
# task #132 introduced to fix intermittent JTAG-Master write
# commit failures.
#
# `derive_pll_clocks` picks up both ALTPLL outputs automatically.
# This `create_generated_clock` tags the dram_clk net so STA
# carries the timing through to the DRAM_* output ports the IP
# drives.
create_generated_clock -name dram_clk \
    -source [get_pins -compatibility_mode {*altpll_sdram*|clk[1]}] \
    [get_ports DRAM_CLK]

# -- SDRAM CDC bridge — clkBus ↔ clkSdram cross-domain --------------
# The riski5_sdram_cdc_bridge module uses a toggle-handshake CDC
# pattern. The toggled flags (req_toggle_bus, done_toggle_sdram)
# go through 2-FF synchronisers on the destination side; the
# accompanying data registers (m_lat_*, cap_rdata_sdram) are
# sampled by the destination side AFTER the synchronised toggle
# edge, so they're stable across the boundary even though the
# combinational paths are unconstrained.
#
# These false-path constraints tell STA to ignore the
# cross-domain combinational paths between latched-on-source and
# sampled-on-dest registers. Without them, Quartus would either
# fail timing on impossible-to-meet 25-ns / 33-ns single-clock
# transfers or insert metastability hazards by retiming.
set_false_path \
    -from [get_registers {*u_sdram_cdc|m_lat_*}] \
    -to   [get_registers {*u_sdram_cdc|s_lat_*_buf}]
set_false_path \
    -from [get_registers {*u_sdram_cdc|cap_rdata_sdram*}] \
    -to   [get_registers {*u_sdram_cdc|cap_rdata_sync_0*}]
set_false_path \
    -from [get_registers {*u_sdram_cdc|req_toggle_bus*}] \
    -to   [get_registers {*u_sdram_cdc|req_sync_0_sdr*}]
set_false_path \
    -from [get_registers {*u_sdram_cdc|done_toggle_sdram*}] \
    -to   [get_registers {*u_sdram_cdc|done_sync_0*}]
