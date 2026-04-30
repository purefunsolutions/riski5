# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# scripts/sdram-write-pattern-test.tcl — exercise the JTAG-Master
# write path against SDRAM to surface upper-16-bit half-word write
# drops and similar bus-layer corruption.
#
# Why: an entire kernel-image upload + Linux boot cycle is an 8-min
# round-trip just to discover that some writes didn't commit. This
# script runs in seconds against an already-flashed bitstream and
# emits a clear PASS / FAIL summary plus per-pattern diagnostics —
# the same data we'd have to mine out of a full boot run by reading
# SDRAM with quartus_stp.
#
# Patterns exercised (each at multiple addresses, multiple rows):
#   1.  master_write_32 of values with non-zero upper-16 bits
#       (DEADBEEF, CAFEF00D, etc.) — catches the hi-half-word drop.
#   2.  master_write_16 to lo half (offset 0) — confirms lo path
#       still works.
#   3.  master_write_16 to hi half (offset 2) — direct test of hi
#       half-word write. This is the bug mode that boot-linux-master
#       hits via the kernel's reset_regs FP-clear sequence.
#   4.  Aligned 32-bit writes after explicit 0xFFFFFFFF reset —
#       reveals "stuck-zero upper half-word" pattern.
#   5.  Cross-row writes (different physical SDRAM rows) — guards
#       against row-buffer / refresh-related corner cases.
#
# Run via:
#   nix run .#sdram-write-pattern-test
#
# Exit code 0 = all PASS; exit code 1 = any FAIL. The script emits
# a per-test "PASS" / "FAIL" line and a final summary, so the host
# Nix wrapper can pipe the output to a log + check the exit code in
# CI.

set masters [get_service_paths master]
if {[llength $masters] == 0} {
    puts stderr "error: no JTAG-Avalon-Master endpoints found."
    puts stderr "       is the riski5-core-linux-master bitstream flashed?"
    exit 2
}
set m [lindex $masters 0]
open_service master $m

set total 0
set passed 0
set failed 0

# Helper: write a 32-bit value, read back, compare. PASS iff equal.
proc check_32 {m a v label} {
    upvar 1 total total
    upvar 1 passed passed
    upvar 1 failed failed
    incr total
    master_write_32 $m $a [list $v]
    set rb [lindex [master_read_32 $m $a 1] 0]
    if {$rb == $v} {
        incr passed
        puts [format "  PASS  %-40s @0x%08x : 0x%08x" $label $a $v]
    } else {
        incr failed
        # Identify which half (lo/hi) corrupted
        set xor [expr {$rb ^ $v}]
        set what "?"
        if {($xor & 0xFFFF) == 0} {
            set what "hi-half dropped"
        } elseif {($xor & 0xFFFF0000) == 0} {
            set what "lo-half dropped"
        } else {
            set what "both halves wrong"
        }
        puts [format "  FAIL  %-40s @0x%08x : wrote 0x%08x  read 0x%08x  (%s)" \
            $label $a $v $rb $what]
    }
}

# Helper: write a 16-bit value at half-word boundary, read back full
# 32-bit and check just that half.
proc check_16 {m base off v label} {
    upvar 1 total total
    upvar 1 passed passed
    upvar 1 failed failed
    incr total
    set a [expr {$base + $off}]
    set wordbase [expr {$base & 0xFFFFFFFC}]
    master_write_16 $m $a [list $v]
    set full [lindex [master_read_32 $m $wordbase 1] 0]
    if {$off == 0 || $off == 2} {
        if {$off == 0} {
            set half [expr {$full & 0xFFFF}]
        } else {
            set half [expr {($full >> 16) & 0xFFFF}]
        }
        if {$half == $v} {
            incr passed
            puts [format "  PASS  %-40s @0x%08x off=%d : 0x%04x" $label $base $off $v]
        } else {
            incr failed
            puts [format "  FAIL  %-40s @0x%08x off=%d : wrote 0x%04x  read 0x%04x  full=0x%08x" \
                $label $base $off $v $half $full]
        }
    } else {
        incr failed
        puts "  ERROR  bad off=$off (must be 0 or 2)"
    }
}

# Helper: reset a 32-bit cell to 0x00000000 via successful lo-write
# of zero (won't help upper half if the write path is broken, but
# at least baselines the lo half).
proc reset_cell {m a} {
    master_write_32 $m $a [list 0x00000000]
}

puts ""
puts "================================================================"
puts " SDRAM JTAG-Master write-pattern test"
puts " task #146 reproducer for the hi-half-word write drop"
puts "================================================================"
puts ""

# ----- Test 1: full 32-bit writes with non-zero upper half ---------
puts "--- Test 1: master_write_32 with non-zero upper-16 bits ---"
set base1 0x80700000
set patterns1 {0xDEADBEEF 0xCAFEF00D 0x12345678 0xAABBCCDD 0xFFFF0000 0xFEDCBA98 0x80000001}
set off 0
foreach p $patterns1 {
    set a [expr {$base1 + $off}]
    reset_cell $m $a
    check_32 $m $a $p "32-bit non-zero-upper"
    incr off 4
}

# ----- Test 2: lo-half-only 16-bit writes --------------------------
puts ""
puts "--- Test 2: master_write_16 to LO half (offset 0) ---"
set base2 0x80700100
set hpatterns {0xAAAA 0x5555 0x1234 0xFFFF}
set off 0
foreach h $hpatterns {
    reset_cell $m [expr {$base2 + $off}]
    check_16 $m [expr {$base2 + $off}] 0 $h "16-bit LO write"
    incr off 4
}

# ----- Test 3: hi-half-only 16-bit writes (BUG MODE) ---------------
puts ""
puts "--- Test 3: master_write_16 to HI half (offset 2) — task #146 ---"
set base3 0x80700200
set off 0
foreach h $hpatterns {
    reset_cell $m [expr {$base3 + $off}]
    check_16 $m [expr {$base3 + $off}] 2 $h "16-bit HI write"
    incr off 4
}

# ----- Test 4: 32-bit write after explicit 0xFFFFFFFF reset -------
# If the hi-write path is broken, writing 0xDEADBEEF after 0xFFFFFFFF
# leaves the hi half stuck at 0xFFFF. Catches the same bug from a
# different angle.
puts ""
puts "--- Test 4: 32-bit write after 0xFFFFFFFF reset ---"
set base4 0x80700300
set off 0
foreach p $patterns1 {
    set a [expr {$base4 + $off}]
    master_write_32 $m $a [list 0xFFFFFFFF]
    set pre [lindex [master_read_32 $m $a 1] 0]
    incr total
    master_write_32 $m $a [list $p]
    set rb [lindex [master_read_32 $m $a 1] 0]
    if {$rb == $p} {
        incr passed
        puts [format "  PASS  post-FF-reset 32-bit              @0x%08x : 0x%08x" $a $p]
    } else {
        incr failed
        puts [format "  FAIL  post-FF-reset 32-bit              @0x%08x : pre=0x%08x  wrote=0x%08x  read=0x%08x" \
            $a $pre $p $rb]
    }
    incr off 4
}

# ----- Test 5: cross-row writes ------------------------------------
puts ""
puts "--- Test 5: writes across different SDRAM rows ---"
# Row stride on DE2 SDRAM is ~512 bytes. Hit several rows.
set rows {0x80700000 0x80700400 0x80700800 0x80701000 0x80710000 0x80720000 0x80800000}
foreach r $rows {
    reset_cell $m $r
    check_32 $m $r 0xDEADBEEF "cross-row 32-bit"
}

puts ""
puts "================================================================"
puts [format " summary: %d passed, %d failed of %d total" $passed $failed $total]
puts "================================================================"

close_service master $m
if {$failed > 0} { exit 1 } else { exit 0 }
