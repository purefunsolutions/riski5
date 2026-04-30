# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# sdram-state-probe.tcl — read the SDRAM CDC bridge / IP state
# probes (task #142) via quartus_stp's read_probe_data.
#
# Probes read:
#
#   PCFE (32-bit): the core's pcFetchS, for context — tells us
#                  what instruction the core is trying to fetch
#                  when we sample.
#
#   DBGF (8-bit):  packed SoC stall / ready / accepted flags, see
#                  Riski5.Soc.SocOut.soDbgFlags.
#
#   SDST (32-bit): SDRAM CDC bridge state, see riski5_top.v's
#                  sdram_bridge_state_pack:
#                    [1:0]   m_state (M_IDLE/M_BUSY/M_DONE_W/M_DONE_R)
#                    [3:2]   s_state (S_IDLE/S_REQ/S_AWAIT_VALID/S_DONE)
#                    [4]     req_toggle_bus
#                    [5]     done_toggle_sdram
#                    [6]     bridge_waitrequest (to Clash master)
#                    [7]     bridge_valid       (to Clash master)
#                    [8]     sdram_ip_az_cs     (bridge → IP)
#                    [9]     sdram_ip_az_rd
#                    [10]    sdram_ip_az_wr
#                    [11]    sdram_ip_waitrequest (IP → bridge)
#                    [12]    sdram_ip_valid
#                    [13]    sdram_cs           (Clash master → bridge)
#                    [14]    sdram_rd
#                    [15]    sdram_wr
#                    [31:16] m_lat_addr[15:0]   (last latched
#                                                request address,
#                                                low 16 bits)
#
#   SDIO (32-bit):
#                    [15:0]  bridge_cap_rdata_sdram (last 16-bit
#                                                    word the IP
#                                                    returned via
#                                                    valid pulse)
#                    [21:16] m_lat_addr[21:16]      (high 6 bits
#                                                    of the
#                                                    address)
#                    [31:22] padding
#
# Workflow: flash riski5-core-linux-master, kick off
# boot-linux-master to upload kernel + DTB and JR into Linux,
# wait for the silicon hang at PC=0x80000108, then run this
# script to sample the bridge / IP state. Hand off the sample
# to the user to interpret which side parked.

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
foreach n {PCFE DBGF SDST SDIO} {
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

proc bin_to_int {bits} {
    set n 0
    foreach c [split $bits ""] { set n [expr {$n * 2 + $c}] }
    return $n
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

# Probe data string: char 0 is the MSB. For an N-bit probe of
# width N, bit k of the underlying register is at string index (N-1-k).
proc bit {bits idx} {
    set len [string length $bits]
    return [string index $bits [expr {$len - 1 - $idx}]]
}

# Slice [hi:lo] (inclusive, lo ≤ hi) out of a binary string and
# return the integer value.
proc slice_int {bits hi lo} {
    set len [string length $bits]
    # The bit at index k of the register is at string index (len-1-k).
    # Slicing bits [hi..lo] of the register = string range
    # [len-1-hi .. len-1-lo].
    set start [expr {$len - 1 - $hi}]
    set end   [expr {$len - 1 - $lo}]
    return [bin_to_int [string range $bits $start $end]]
}

proc decode_dbgf {bits} {
    return [format "s=%s ds=%s fs=%s uacc=%s sram=%s urdy=%s bram=%s cap=%s" \
        [bit $bits 0] [bit $bits 1] [bit $bits 2] [bit $bits 3] \
        [bit $bits 4] [bit $bits 5] [bit $bits 6] [bit $bits 7]]
}

proc decode_sdst {bits} {
    set m_state [slice_int $bits 1 0]
    set s_state [slice_int $bits 3 2]
    set req_t   [bit $bits 4]
    set done_t  [bit $bits 5]
    set bridge_wr [bit $bits 6]
    set bridge_v  [bit $bits 7]
    set ip_cs   [bit $bits 8]
    set ip_rd   [bit $bits 9]
    set ip_wr   [bit $bits 10]
    set ip_wr_req [bit $bits 11]
    set ip_v    [bit $bits 12]
    set m_cs    [bit $bits 13]
    set m_rd    [bit $bits 14]
    set m_wr    [bit $bits 15]
    set lat_lo  [slice_int $bits 31 16]

    set m_state_n {IDLE BUSY DONE_W DONE_R}
    set s_state_n {IDLE REQ AWAIT_VALID DONE}

    return [format "m=%-7s s=%-12s req_t=%s done_t=%s | bridge: wr=%s v=%s | ip: cs=%s rd=%s wr=%s wreq=%s v=%s | master: cs=%s rd=%s wr=%s | lat_lo=0x%04X" \
        [lindex $m_state_n $m_state] [lindex $s_state_n $s_state] \
        $req_t $done_t \
        $bridge_wr $bridge_v \
        $ip_cs $ip_rd $ip_wr $ip_wr_req $ip_v \
        $m_cs $m_rd $m_wr \
        $lat_lo]
}

proc decode_sdio {bits} {
    set rdata  [slice_int $bits 15 0]
    set lat_hi [slice_int $bits 21 16]
    return [format "rdata=0x%04X lat_hi=0x%02X (full lat addr=0x%06X)" \
        $rdata $lat_hi [expr {$lat_hi * 65536}]]
}

# Take N samples at INTERVAL_MS apart so we can see whether the
# bridge / IP state is animating or genuinely parked.
set N 8
set INTERVAL_MS 100

puts ""
puts "=== SDRAM bridge / IP state samples ($N × ${INTERVAL_MS}ms) ==="
for {set i 0} {$i < $N} {incr i} {
    set pcfe [read_probe_data -instance_index [dict get $ids PCFE]]
    set dbgf [read_probe_data -instance_index [dict get $ids DBGF]]
    set sdst [read_probe_data -instance_index [dict get $ids SDST]]
    set sdio [read_probe_data -instance_index [dict get $ids SDIO]]

    set lat_hi [slice_int $sdio 21 16]
    set lat_lo [slice_int $sdst 31 16]
    set full_lat [expr {$lat_hi * 65536 + $lat_lo}]

    puts [format "Sample %d:" $i]
    puts [format "  PC      0x%08X    flags  %s" \
        [bin_to_int $pcfe] [decode_dbgf $dbgf]]
    puts [format "  bridge  %s" [decode_sdst $sdst]]
    puts [format "  rdata   0x%04X        full_lat_addr=0x%06X" \
        [slice_int $sdio 15 0] $full_lat]

    after $INTERVAL_MS
}

end_insystem_source_probe
