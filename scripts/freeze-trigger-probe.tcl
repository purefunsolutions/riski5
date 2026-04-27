# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# freeze-trigger-probe.tcl — sample the SDRAM-exec multi-byte
# debug probes:
#
#   FRZP (128-bit probe): 4 consecutive @pcFetchS@ snapshots
#                         starting at the trigger cycle.
#   FRZF (32-bit probe):  4 consecutive flag bytes from the
#                         same cycles.
#   CAPR (1-bit source):  re-arm the snapshot + reset counters.
#   CMTC (32-bit probe):  total IP-side commit-pulse count
#                         since last @CAPR@ pulse.
#   ITRC (32-bit probe):  iteration count (number of @B@ bytes
#                         committed) since last @CAPR@ pulse.
#
# The CMTC : ITRC ratio tells us whether the silicon multi-byte
# residual is master-side multi-commit (ratio > 2) or something
# further out (ratio == 2 → IP commits exactly the bytes the
# master assertions ask for, and the multi-byte pattern lives
# in JTAG transport / nios2-terminal display).

set cable ""
foreach hw [get_hardware_names] {
    if {[string match "*USB-Blaster*" $hw]} { set cable $hw; break }
}
if {$cable eq ""} { puts "ERROR: no USB-Blaster cable found"; exit 1 }
set dev [lindex [get_device_names -hardware_name $cable] 0]
puts "cable: $cable / device: $dev"

set ids [dict create]
foreach inst [get_insystem_source_probe_instance_info \
                  -hardware_name $cable -device_name $dev] {
    dict set ids [lindex $inst 3] [lindex $inst 0]
}
foreach n {FRZP FRZF CAPR CMTC ITRC} {
    if {![dict exists $ids $n]} {
        puts "ERROR: probe '$n' not found"
        foreach k [dict keys $ids] {
            puts "  available: $k -> [dict get $ids $k]"
        }
        exit 1
    }
}
puts "Probes: [dict keys $ids]"

start_insystem_source_probe -hardware_name $cable -device_name $dev

proc rearm {capr_idx} {
    write_source_data -instance_index $capr_idx -value 1 -value_in_hex
    write_source_data -instance_index $capr_idx -value 0 -value_in_hex
}

proc bin_to_int {bits} {
    set n 0
    foreach c [split $bits ""] { set n [expr {$n * 2 + $c}] }
    return $n
}

proc decode_flags {bits} {
    set captured [string index $bits 0]
    set bram     [string index $bits 1]
    set urdy     [string index $bits 2]
    set sram     [string index $bits 3]
    set uacc     [string index $bits 4]
    set fst      [string index $bits 5]
    set dst      [string index $bits 6]
    set st       [string index $bits 7]
    return [format "s=%s ds=%s fs=%s uacc=%s sram=%s urdy=%s bram=%s CAP=%s" \
        $st $dst $fst $uacc $sram $urdy $bram $captured]
}

proc bin_to_hex {bits} {
    set hex ""
    set len [string length $bits]
    set rem [expr {$len % 4}]
    if {$rem != 0} {
        set pad [string repeat "0" [expr {4 - $rem}]]
        set bits "${pad}${bits}"
    }
    set len [string length $bits]
    for {set i 0} {$i < $len} {incr i 4} {
        set nibble [string range $bits $i [expr {$i + 3}]]
        set n 0
        foreach c [split $nibble ""] { set n [expr {$n * 2 + $c}] }
        append hex [format %X $n]
    }
    return $hex
}

# === Step 1: 4-cycle waveform around the trigger ===
puts ""
puts "=== Freeze-trigger 4-cycle waveform (single capture) ==="
rearm [dict get $ids CAPR]
after 50
set pc_all    [read_probe_data -instance_index [dict get $ids FRZP]]
set flags_all [read_probe_data -instance_index [dict get $ids FRZF]]
for {set ofs 0} {$ofs < 4} {incr ofs} {
    set pc_bits    [string range $pc_all    [expr {$ofs * 32}] [expr {$ofs * 32 + 31}]]
    set flags_bits [string range $flags_all [expr {$ofs * 8}]  [expr {$ofs * 8 + 7}]]
    puts [format "  +%d: pcFetch=0x%-8s | %s" $ofs [bin_to_hex $pc_bits] [decode_flags $flags_bits]]
}

# === Step 2: count IP commits vs iterations over a measured window ===
puts ""
puts "=== IP commit-rate measurement ==="
foreach delay {100 250 500 1000} {
    rearm [dict get $ids CAPR]
    after $delay
    set commits [bin_to_int [read_probe_data -instance_index [dict get $ids CMTC]]]
    set iters   [bin_to_int [read_probe_data -instance_index [dict get $ids ITRC]]]
    if {$iters > 0} {
        set ratio [format %.3f [expr {double($commits) / $iters}]]
    } else {
        set ratio "n/a (0 iters)"
    }
    puts [format "  %4d ms : commits=%d iters=%d commit/iter=%s" $delay $commits $iters $ratio]
}

end_insystem_source_probe
