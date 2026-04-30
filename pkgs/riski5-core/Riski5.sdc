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
# phase-shifted copy of clkSdram (100 MHz under task #141 final
# config; previously 30 MHz, before that 40 MHz from the bus PLL).
# The phase shift puts the SDRAM chip's rising edge ~3 ns AFTER
# the FPGA-side controller's rising edge, covering Tco + trace
# delay. At 100 MHz period 10 ns, 3 ns is 30% of the period —
# substantial but well within the chip's setup/hold tolerance for
# the IS42S16400-7 part on the DE2.
# Standard Altera SDRAM Controller deployment pattern; this is
# the pattern that task #132 introduced to fix intermittent
# JTAG-Master write commit failures.
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
# pattern: toggled flags through 2-FF synchronisers on the
# destination side, plus accompanying data registers (m_lat_*,
# cap_rdata_sdram) sampled by the destination side AFTER the
# synchronised toggle edge — so they're stable across the
# boundary by construction.
#
# Declare the clkBus domain and the clkSdram-family of clocks
# (clkSdram, clkSdramOut, dram_clk) as asynchronous clock groups.
# This tells TimeQuest to ignore all paths between the two
# domains, which is what we want — the bridge handles CDC in
# its own logic via toggles + 2-FF synchronisers, and STA has
# nothing useful to say about combinational paths whose
# launch/capture clocks have no defined phase relationship.
set_clock_groups -asynchronous \
    -group { u_altpll|pll|clk[0] } \
    -group { u_altpll_sdram|pll|clk[0] u_altpll_sdram|pll|clk[1] dram_clk }
