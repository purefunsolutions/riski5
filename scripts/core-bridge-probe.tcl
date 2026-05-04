# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# core-bridge-probe.tcl — read the CoreCdcBridge state probes
# (task #46) via quartus_stp's read_probe_data.
#
# Probes read:
#
#   PCFE (32-bit): the BUS-side core's pcFetchS (= the bridge
#                  slave's sLatReq.cbrPcFetch as routed through
#                  the bus). Sampled in DomBus.
#
#   BPCC (32-bit): the CORE-side live cbrPcFetch — the PC the
#                  RISC-V core is actively asserting on its imem
#                  port right now. Sampled in DomCore. If BPCC
#                  stays at 0 forever the core itself is stuck
#                  before the bridge ever fires.
#
#   BPCM (32-bit): the bridge master's mLastSentPc — the PC the
#                  bridge most recently fired a transaction for.
#                  Sampled in DomCore. Sentinel-init = 0xFFFFFFFF
#                  before the first fetch fires.
#
#   BPCS (32-bit): the bridge slave's sLatReq.cbrPcFetch — the
#                  PC the slave most recently latched from the
#                  master's payload. Sampled in DomBus.
#
#   BDGM (8-bit):  master FSM state byte. Bit layout:
#                    [1:0] mPhase         (0=MIdle, 1=MBusy, 2=MDone)
#                    [2]   mReqToggle
#                    [3]   doneToggleC    (synced from slave)
#                    [4]   doneEdgeC      (1-cycle pulse)
#                    [5]   reqIsLive      (would-fire predicate)
#                    [7:6] cbrPcFetch[1:0]
#
#   BDGS (8-bit):  slave FSM state byte. Bit layout:
#                    [1:0] sPhase         (0=SIdle, 1=SDrive,
#                                           2=SServe, 3=SDone)
#                    [2]   sDoneToggle
#                    [3]   reqToggleB     (synced from master)
#                    [4]   reqEdgeB       (1-cycle pulse)
#                    [5]   replyInB.cbrStall
#                    [6]   replyInB.cbrDataStall
#                    [7]   sLatReq.cbrPcFetch[0]
#
# Diagnostic chain:
#
#   * BPCC stays at 0 forever      → core never advances past reset PC.
#                                     Bridge would never fire either.
#                                     Likely cause: rstCore_n stuck low
#                                     (PLL didn't lock), OR the bridge
#                                     never delivers a stall=False
#                                     reply so the core is held in
#                                     perpetual MBusy stall.
#
#   * BPCC advances, BPCM stays 0  → core IS running, but the bridge
#                                     master FSM never fires. Likely
#                                     cause: the sentinel-init lost
#                                     in synthesis (BPCM should be
#                                     0xFFFFFFFF before first fire).
#
#   * BPCM advances, BPCS lags     → master fires but slave never
#                                     latches. Likely cause: CDC
#                                     bit-skew or syncBitVector bug.
#
#   * BPCM == BPCS, both lagging   → both sides see same PC but
#     vs BPCC                       core has moved past it. Bridge
#                                     is bottlenecked or stuck in
#                                     SServe waiting for a stall
#                                     release that never comes.
#
# Workflow: flash a riski5-core-coremark or riski5-core-aexttest
# bitstream that uses the multi-PLL Phase D-2 wiring (CoreCdcBridge),
# then run this script to sample the bridge / core state. Decide
# next debug step from the chain above.

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
foreach n {PCFE BPCC BPCM BPCS BDGM BDGS} {
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

proc bit {bits idx} {
    set len [string length $bits]
    return [string index $bits [expr {$len - 1 - $idx}]]
}

proc slice_int {bits hi lo} {
    set len [string length $bits]
    set start [expr {$len - 1 - $hi}]
    set end   [expr {$len - 1 - $lo}]
    return [bin_to_int [string range $bits $start $end]]
}

proc decode_bdgm {bits} {
    set m_state [slice_int $bits 1 0]
    set req_t   [bit $bits 2]
    set done_t  [bit $bits 3]
    set done_e  [bit $bits 4]
    set live    [bit $bits 5]
    set m_state_n {MIdle MBusy MDone reserved}
    return [format "phase=%-5s reqT=%s doneT=%s doneE=%s live=%s pc1=%s pc0=%s" \
        [lindex $m_state_n $m_state] $req_t $done_t $done_e $live \
        [bit $bits 7] [bit $bits 6]]
}

proc decode_bdgs {bits} {
    set s_state [slice_int $bits 1 0]
    set done_t  [bit $bits 2]
    set req_t   [bit $bits 3]
    set req_e   [bit $bits 4]
    set stall   [bit $bits 5]
    set dstall  [bit $bits 6]
    set s_state_n {SIdle SDrive SServe SDone}
    return [format "phase=%-6s doneT=%s reqT=%s reqE=%s stall=%s dStall=%s pc0=%s" \
        [lindex $s_state_n $s_state] $done_t $req_t $req_e \
        $stall $dstall [bit $bits 7]]
}

# Take N samples at INTERVAL_MS apart so we can see whether the
# bridge / core state is animating or genuinely parked.
set N 8
set INTERVAL_MS 100

puts ""
puts "=== Core / bridge state samples ($N x ${INTERVAL_MS}ms) ==="
for {set i 0} {$i < $N} {incr i} {
    set pcfe [read_probe_data -instance_index [dict get $ids PCFE]]
    set bpcc [read_probe_data -instance_index [dict get $ids BPCC]]
    set bpcm [read_probe_data -instance_index [dict get $ids BPCM]]
    set bpcs [read_probe_data -instance_index [dict get $ids BPCS]]
    set bdgm [read_probe_data -instance_index [dict get $ids BDGM]]
    set bdgs [read_probe_data -instance_index [dict get $ids BDGS]]

    puts [format "Sample %d:" $i]
    puts [format "  PCs:    bus_pcFetchS=0x%08X core_live=0x%08X" \
        [bin_to_int $pcfe] [bin_to_int $bpcc]]
    puts [format "  Bridge: master_lastPc=0x%08X slave_latPc=0x%08X" \
        [bin_to_int $bpcm] [bin_to_int $bpcs]]
    puts [format "  Master: %s" [decode_bdgm $bdgm]]
    puts [format "  Slave:  %s" [decode_bdgs $bdgs]]

    after $INTERVAL_MS
}

end_insystem_source_probe
