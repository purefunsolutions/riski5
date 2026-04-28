# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# load-sdram-master.tcl — host-side bulk SDRAM upload via the
# JTAG-to-Avalon-Master bridge IP that the riski5-core-linux
# bitstream contains (see L-3b option A in docs/linux-boot.md).
#
# Workflow:
#
#   nix run .#flash-riski5-linux                    # 1. flash bitstream
#   quartus_stp -t scripts/load-sdram-master.tcl \
#       <bin-path> <base-addr-hex>                  # 2. upload via Tcl
#
# This script bypasses the JTAG-UART RX path entirely: every
# 32-bit word goes through `master_write_32` on the Avalon-MM
# bridge straight into SDRAM. Expected throughput is the JTAG
# bridge's native rate (typically 50-100 KB/s on USB-Blaster vs.
# the JTAG-UART path's 1-2 KB/s on this rig).
#
# Args:
#   argv[0] — path to the binary blob to upload (kernel + DTB,
#             pre-concatenated; see scripts/load-linux for the
#             host-side packing logic).
#   argv[1] — base address as a hex string (e.g. "0x80000000").
#             Each 32-bit word is written sequentially starting
#             here.
#
# Error handling: any Avalon-MM access failure (waitrequest
# timeout, bus error) bubbles up as a Tcl error and aborts the
# upload. The riski5 core is still spinning in its boot-ROM
# polling loop while this runs — the JTAG_LOAD_MODE mux in the
# SoC routes our writes around it (see Riski5.Soc).

if {[llength $argv] != 2} {
    puts stderr "usage: quartus_stp -t load-sdram-master.tcl <bin-path> <base-addr-hex>"
    exit 1
}

set bin_path [lindex $argv 0]
set base_addr [expr [lindex $argv 1]]

if {![file exists $bin_path]} {
    puts stderr "error: $bin_path does not exist"
    exit 1
}

set bytes [file size $bin_path]
if {$bytes % 4 != 0} {
    puts stderr "error: $bin_path has $bytes bytes, not a multiple of 4."
    puts stderr "       pad it first or fix the producer."
    exit 1
}
set words [expr $bytes / 4]

puts "load-sdram-master:"
puts "  bin    : $bin_path"
puts "  bytes  : $bytes"
puts "  words  : $words"
puts [format "  dst    : 0x%08x .. 0x%08x" $base_addr [expr $base_addr + $bytes - 1]]
puts ""

# Open the JTAG service and locate our master endpoint. System
# Console enumerates every Avalon master visible across the JTAG
# chain; with one bridge per bitstream we expect exactly one
# match. If multiple bitstreams ever share the cable, this needs
# refining (e.g. matching on instance ID).
set masters [get_service_paths master]
if {[llength $masters] == 0} {
    puts stderr "error: no JTAG-Avalon-Master endpoints found on the chain."
    puts stderr "       is the bitstream flashed?"
    exit 1
}
set m [lindex $masters 0]
puts "  master : $m"
open_service master $m

# Read the binary in 1 KB chunks (= 256 words) and issue
# sequential master_write_32 calls. Larger batches are possible
# but harder to debug if one chunk fails halfway through.
set fp [open $bin_path "rb"]
fconfigure $fp -translation binary

set chunk_words 256
set written 0
set t_start [clock milliseconds]

while {$written < $words} {
    set remaining [expr $words - $written]
    set this_chunk [expr min($chunk_words, $remaining)]
    set buf [read $fp [expr $this_chunk * 4]]
    set buf_words [list]
    for {set i 0} {$i < $this_chunk} {incr i} {
        # Little-endian word from the byte stream.
        binary scan $buf "@[expr $i * 4]i" w
        lappend buf_words [expr {$w & 0xFFFFFFFF}]
    }
    set addr [expr $base_addr + $written * 4]
    master_write_32 $m $addr $buf_words
    incr written $this_chunk

    # Progress: once per second is plenty.
    set now [clock milliseconds]
    if {$now - $t_start > 1000 && $written % 1024 == 0} {
        set elapsed_s [expr ($now - $t_start) / 1000.0]
        set kb [expr ($written * 4) / 1024.0]
        set rate [expr $kb / $elapsed_s]
        puts [format "  %6.1f KB / %6.1f KB  @ %5.1f KB/s" $kb [expr $bytes / 1024.0] $rate]
    }
}

close $fp
close_service master $m

set t_end [clock milliseconds]
set total_s [expr ($t_end - $t_start) / 1000.0]
set total_kb [expr $bytes / 1024.0]
puts ""
puts [format "load-sdram-master: done — %.1f KB in %.1f s (%.1f KB/s)" \
    $total_kb $total_s [expr $total_kb / $total_s]]
puts ""
puts "SDRAM is now populated. Press KEY0 (or have firmware JR to"
puts "the load base) to start executing what was uploaded."
