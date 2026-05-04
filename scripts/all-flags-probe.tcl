# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# all-flags-probe.tcl — comprehensive bridge + bus + UART debug
# probe for diagnosing why CMTC stays at 0 even though the core
# is executing instructions (task #46).

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

start_insystem_source_probe -hardware_name $cable -device_name $dev

proc bin_to_int {bits} {
    set n 0
    foreach c [split $bits ""] { set n [expr {$n * 2 + $c}] }
    return $n
}

proc bit {bits idx} {
    set len [string length $bits]
    return [string index $bits [expr {$len - 1 - $idx}]]
}

set N 8
set INTERVAL_MS 200

puts ""
puts "=== Comprehensive bridge / bus / UART probe ($N x ${INTERVAL_MS}ms) ==="
puts "DBGF bit layout: stall, dataStall, fetchStall, uartAccepted,"
puts "                 sramDataReady, uartReady, bramReady, captured"
puts ""

for {set i 0} {$i < $N} {incr i} {
    set pcfe [read_probe_data -instance_index [dict get $ids PCFE]]
    set bpcc [read_probe_data -instance_index [dict get $ids BPCC]]
    set bpcm [read_probe_data -instance_index [dict get $ids BPCM]]
    set bpcs [read_probe_data -instance_index [dict get $ids BPCS]]
    set dbgf [read_probe_data -instance_index [dict get $ids DBGF]]
    set cmtc [read_probe_data -instance_index [dict get $ids CMTC]]

    set s    [bit $dbgf 0]
    set ds   [bit $dbgf 1]
    set fs   [bit $dbgf 2]
    set uacc [bit $dbgf 3]
    set sram [bit $dbgf 4]
    set urdy [bit $dbgf 5]
    set bram [bit $dbgf 6]

    puts [format "Sample %d:  CMTC=%-5d  flags: s=%s ds=%s fs=%s uacc=%s urdy=%s bram=%s sramRdy=%s" \
        $i [bin_to_int $cmtc] $s $ds $fs $uacc $urdy $bram $sram]
    puts [format "         pcs:  bus=0x%08X  core=0x%08X  master=0x%08X  slave=0x%08X" \
        [bin_to_int $pcfe] [bin_to_int $bpcc] [bin_to_int $bpcm] [bin_to_int $bpcs]]

    after $INTERVAL_MS
}

end_insystem_source_probe
