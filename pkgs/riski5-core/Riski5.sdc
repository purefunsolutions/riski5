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

# -- SDRAM (DRAM_CLK output) ----------------------------------------
# DRAM_CLK is a gated / forwarded copy of the core clock driving the
# external SDR SDRAM chip. Declare it as a generated clock so STA
# knows the SDRAM pins are synchronous to CLOCK_50 → ALTPLL → clk30
# and doesn't raise unconstrained-output warnings. At 30 MHz the
# chip has > 18 ns of setup/hold margin either side of the FPGA →
# SDRAM edge (IS42S16400-7 requires 1.5 / 0.8 ns), so the default
# I/O register constraints are enough and we don't yet need a
# phase-shifted PLL output here. Phase 1E may revisit when pushing
# fmax above 50 MHz.
#
# The actual DRAM_CLK pin is driven from the same altpll_clk_vec[0]
# as the core — see riski5_top.v in package.nix. This create_generated_clock
# tags that net so STA carries the timing over to the DRAM_* output
# ports the IP drives.
create_generated_clock -name dram_clk \
    -source [get_pins -compatibility_mode {*altpll*|clk[0]}] \
    [get_ports DRAM_CLK]
