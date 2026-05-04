# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# uart-counter-probe.tcl — read the UART IP commit counter (CMTC)
# and 'B'-byte counter (ITRC) from the riski5 silicon.
#
# CMTC = ip_commit_counter, increments every cycle the JTAG-UART
#        IP sees uart_sel & jtag_uart_wr & jtag_uart_waitrequest
#        — the precise hardware-side commit signal.
#
# ITRC = iter_counter, increments only when the committed byte's
#        low 8 bits are 0x42 ('B'). Used as a coarse "iteration
#        marker" by SRAM/SDRAM stress firmwares.
#
# If silicon outputs nothing on JTAG-UART:
#   * CMTC = 0   →  IP never committed. Bridge / bus never delivered
#                   a write strobe to the UART. Diagnose the bridge
#                   with core-bridge-probe.tcl.
#   * CMTC > 0   →  IP DID commit but nios2-terminal saw nothing.
#                   Likely cause: JTAG-UART transport / FIFO drain
#                   issue, OR the bytes are non-printable (NULs).

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
foreach n {CMTC ITRC} {
    if {![dict exists $ids $n]} {
        puts "ERROR: probe '$n' not found"
        foreach k [dict keys $ids] {
            puts "  available: $k -> [dict get $ids $k]"
        }
        exit 1
    }
}

start_insystem_source_probe -hardware_name $cable -device_name $dev

proc bin_to_int {bits} {
    set n 0
    foreach c [split $bits ""] { set n [expr {$n * 2 + $c}] }
    return $n
}

set N 4
set INTERVAL_MS 250

puts ""
puts "=== UART commit counters ($N x ${INTERVAL_MS}ms) ==="
for {set i 0} {$i < $N} {incr i} {
    set cmtc [read_probe_data -instance_index [dict get $ids CMTC]]
    set itrc [read_probe_data -instance_index [dict get $ids ITRC]]
    puts [format "Sample %d:  CMTC=%d (UART IP commits)  ITRC=%d ('B' bytes)" \
        $i [bin_to_int $cmtc] [bin_to_int $itrc]]
    after $INTERVAL_MS
}

end_insystem_source_probe
