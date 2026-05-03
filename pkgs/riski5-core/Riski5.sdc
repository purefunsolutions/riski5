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
#
# Tested 2026-05-02: bumping to 3 ns then 4 ns did NOT change
# the Linux stack-protector panic at PC 0x8002cd98 (same panic
# point, same call trace, same wall time within ±1 ms). Timing
# margin is ruled out as the cause of that panic; the bug is
# software-side.
# Phase C SDC: Quartus's PLL allocator may merge u_altpll_bus and
# u_altpll_sdram into a single physical Cyclone II PLL block (both
# take CLOCK_50 as input; the chip has 4 PLLs total but only 1 is
# used per "logical PLL" if outputs fit). Post-merge the clocks
# can show up under either u_altpll_bus|pll|clk[N] or
# u_altpll_sdram|pll|clk[N] depending on which name Quartus picked.
# Classify clocks by period (TCL foreach because Quartus 13.0sp1's
# get_clocks doesn't support a -filter expression).
#
# Bus clock = the 40 MHz one (period ≈ 25 ns); SDRAM clock = the
# faster one (period < 24 ns covers everything from 50 MHz upward).
set bus_clocks   {}
set sdram_clocks {}
# Iterate every clock in the design; classify by period. Includes
# both PLL outputs (u_altpll_*|pll|clk[N]) and generated clocks
# like dram_clk that derive from PLL outputs. Excludes the source
# clocks (clk50, altera_reserved_tck) since they aren't sequential
# domain clocks.
foreach_in_collection clk [all_clocks] {
    set name [get_clock_info -name $clk]
    set per  [get_clock_info -period $clk]
    # Skip the input source clocks.
    if {$name eq "clk50" || $name eq "altera_reserved_tck"} {
        continue
    }
    if {$per >= 24.0 && $per <= 26.0} {
        lappend bus_clocks $name
    } elseif {$per > 0 && $per < 24.0} {
        lappend sdram_clocks $name
    }
}

# Diagnostic: print what we found so we can see in the fit log
# whether the foreach correctly classified the clocks.
post_message -type info "Riski5.sdc: bus_clocks = $bus_clocks"
post_message -type info "Riski5.sdc: sdram_clocks = $sdram_clocks"

# Existing 2 ns over-constraint on the bus clock — kills the
# Quartus 13.0sp1 placement lottery. Apply per-clock since
# set_clock_uncertainty wants get_clocks objects.
foreach name $bus_clocks {
    set_clock_uncertainty -setup -add 2.0 \
        -from [get_clocks $name] -to [get_clocks $name]
}

# Looser uncertainty on the SDRAM domain since it runs at a higher
# rate near Cyclone II's Fmax envelope.
foreach name $sdram_clocks {
    set_clock_uncertainty -setup -add 0.3 \
        -from [get_clocks $name] -to [get_clocks $name]
}

# CDC bridges between bus and SDRAM domains are inherently safe via
# toggle handshake + 2-FF synchronisers + quasi-static held buses.
# False-path the crossings so TimeQuest doesn't try (and fail) to
# close timing on them.
foreach b $bus_clocks {
    foreach s $sdram_clocks {
        set_false_path -from [get_clocks $b] -to [get_clocks $s]
        set_false_path -from [get_clocks $s] -to [get_clocks $b]
    }
}

# NOTE: dram_clk false-paths used to live here, but dram_clk isn't
# defined yet at this point in the SDC (create_generated_clock is
# below). Moved to immediately after the create_generated_clock
# line.

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
    -source [get_pins -compatibility_mode {*u_altpll_sdram*|clk[1]}] \
    [get_ports DRAM_CLK]

# dram_clk drives the chip's CLK pin and is synthesised AFTER our
# foreach above ran (so it didn't end up in $sdram_clocks). Now
# that the clock exists, false-path its crossings to the bus
# domain explicitly. The wrapper Verilog has bus-domain debug
# captures (last_write_dq_r etc.) that sample DRAM_DQ on dram-cmd
# edges; those are unsynchronised diagnostic taps, not real CDC
# paths, but TimeQuest doesn't know that.
foreach b $bus_clocks {
    set_false_path -from [get_clocks dram_clk] -to [get_clocks $b]
    set_false_path -from [get_clocks $b] -to [get_clocks dram_clk]
}

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
# Phase C: tightened from 6.0/2.0 to 5.4/2.0 — matches the chip's
# actual t_AC=5.4 ns spec without the extra board-trace allowance
# we were including. The DE2's DRAM_DQ traces are physically very
# short (~5 mm), so the ~0.5 ns trace allowance was overconservative.
# At higher SDRAM clock rates this single change unlocks 0.6 ns of
# slack on the chip-input path and lets the design close timing.
set_input_delay  -clock dram_clk -max  5.4 [get_ports DRAM_DQ[*]]
set_input_delay  -clock dram_clk -min  2.0 [get_ports DRAM_DQ[*]]
