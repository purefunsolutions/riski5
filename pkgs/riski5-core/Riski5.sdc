# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# Timing constraints for the riski5 design on the Altera DE2
# (Cyclone II EP2C35F672C6). Phase-1B targets the board's 50 MHz
# oscillator directly (no PLL yet); phase 1E will revisit once we
# explore maxing out fmax.

create_clock -name clk50 -period 20.000 [get_ports CLOCK_50]
derive_pll_clocks
derive_clock_uncertainty

# Async reset input from KEY0 is intentionally exempt from timing.
set_false_path -from [get_ports KEY0] -to [all_registers]

# LCD pins are driven by an FSM that counts dozens of clock cycles
# between transitions; the external LCD chip doesn't care about
# setup/hold at the FPGA clock rate. A multicycle / false_path
# constraint could be added here if the fitter ever complains; for
# now we leave the defaults.
