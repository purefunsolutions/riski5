# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# Timing constraints for the riski5 design on the Altera DE2
# (Cyclone II EP2C35F672C6). Single-PLL topology — task #146 dropped
# the second SDRAM PLL when the Altera SDRAM Controller IP and the
# CDC bridge were replaced by the pure-Clash SDR controller in
# 'Riski5.SdrController' running on clkBus.

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

# -- SDRAM chip-side I/O timing -------------------------------------
# Single 40 MHz domain. DRAM_CLK is driven directly from clkBus
# (u_altpll|clk[0]). At 25 ns period, the chip's setup/hold
# margins (1.5 ns / 0.8 ns) are comfortable on the DE2 board
# traces; no phase-shifted PLL output is required.
create_generated_clock -name dram_clk \
    -source [get_pins -compatibility_mode {*u_altpll*|clk[0]}] \
    [get_ports DRAM_CLK]
