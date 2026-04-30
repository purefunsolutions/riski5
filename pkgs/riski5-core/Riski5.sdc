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

# Async reset input from KEY[0] is intentionally exempt from timing.
set_false_path -from [get_ports KEY[0]] -to [all_registers]

# LCD pins are driven by an FSM that counts dozens of clock cycles
# between transitions; the external LCD chip doesn't care about
# setup/hold at the FPGA clock rate. A multicycle / false_path
# constraint could be added here if the fitter ever complains; for
# now we leave the defaults.

# -- SDRAM (DRAM_CLK output) ----------------------------------------
# DRAM_CLK is sourced from altpll clk[1] — a -3 ns phase-shifted
# copy of clk[0] (clkSys, 40 MHz). The phase shift puts the SDRAM
# chip's rising edge AFTER the FPGA's controller-clock edge by
# ~3 ns, leaving plenty of room for FPGA Tco + board-trace delay
# before the chip samples its inputs. This is the standard Altera
# SDRAM Controller deployment pattern and was added in phase L-3b
# after in-phase DRAM_CLK was identified as the likely root cause
# of intermittent JTAG-Avalon-Master write commit failures
# (task #132).
#
# The actual DRAM_CLK pin is driven from altpll_clk_vec[1] — see
# riski5_top.v in package.nix. This create_generated_clock tags
# the net so STA carries the timing over to the DRAM_* output
# ports the IP drives.
create_generated_clock -name dram_clk \
    -source [get_pins -compatibility_mode {*altpll*|clk[1]}] \
    [get_ports DRAM_CLK]
