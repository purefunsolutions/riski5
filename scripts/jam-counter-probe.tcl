# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# jam-counter-probe.tcl — read the diagnostic counters that
# riski5_jtag_avalon_master (task #133) feeds into three altsource_probe
# SLD instances inside the IP composition shim:
#
#   JBIN  = bytes accepted at the FSM's Avalon-ST input
#           (in_ready && in_valid handshake count)
#   JWRC  = master-write commits (waitrequest dropped while write=1)
#   JRDC  = master-read commits
#
# Drop pattern interpretation (after a kernel + DTB upload of
# `bytes_sent` via master_write_32):
#
#   JBIN < bytes_sent / 4 + overhead   -> drops UPSTREAM of the FSM
#                                          (FIFO / bytes_to_packets /
#                                           JTAG-PHY layer)
#   JBIN ≈ bytes_sent + overhead       -> bytes reach the FSM cleanly
#   JWRC ≈ bytes_sent / 4              -> writes commit to SDRAM
#                                          (anything less = drops at
#                                          FSM/master layer or below)
#
# Run with quartus_stp (Tcl shell), once a riski5-core-linux-master
# bitstream is flashed and an upload run has just completed:
#
#   quartus_stp -t scripts/jam-counter-probe.tcl

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
foreach n {JBIN JWRC JRDC} {
    if {![dict exists $ids $n]} {
        puts "ERROR: probe '$n' not found — is the riski5-core-linux-master"
        puts "       bitstream flashed?"
        foreach k [dict keys $ids] {
            puts "  available: $k -> [dict get $ids $k]"
        }
        exit 1
    }
}
puts "Probes: [dict keys $ids]"

start_insystem_source_probe -hardware_name $cable -device_name $dev

proc bin_to_int {bits} {
    set n 0
    foreach c [split $bits ""] { set n [expr {$n * 2 + $c}] }
    return $n
}

set bin [bin_to_int [read_probe_data -instance_index [dict get $ids JBIN]]]
set wrc [bin_to_int [read_probe_data -instance_index [dict get $ids JWRC]]]
set rdc [bin_to_int [read_probe_data -instance_index [dict get $ids JRDC]]]

puts ""
puts "=== JTAG-Avalon-Master diagnostic counters ==="
puts [format "  bytes_in_cnt      = %d  (0x%08x)" $bin $bin]
puts [format "  writes_commit_cnt = %d  (0x%08x)" $wrc $wrc]
puts [format "  reads_commit_cnt  = %d  (0x%08x)" $rdc $rdc]
puts ""
if {$wrc > 0} {
    set bin_per_wrc [expr {double($bin) / $wrc}]
    puts [format "  bytes_in / writes_commit = %.2f bytes per accepted write" $bin_per_wrc]
}

end_insystem_source_probe
exit 0
