# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# boot-linux-master.tcl — full Linux upload via the
# JTAG-to-Avalon-Master path, in one quartus_stp Tcl session.
#
# Sequence:
#   1. master_write_32 kernel image to 0x80000000
#   2. master_write_32 DTB to 0x80000000 + kbytes
#   3. master_write_32 SRAM[0x20000000] = kbytes
#   4. master_write_32 SRAM[0x20000004] = 1   (go sentinel)
#
# The riski5-core-linux-master bitstream (firmware/phase1/
# LinuxBootMaster.hs) spins on SRAM[+4]; once non-zero it reads
# kbytes from SRAM[+0], computes a1 = 0x80000000 + kbytes (DTB
# pointer), sets a0=0 / sp=0x20080000, JALRs to 0x80000000.
#
# Args:
#   argv[0] — kernel image path (4-byte aligned)
#   argv[1] — DTB path (4-byte aligned; padded if not)

if {[llength $argv] != 2} {
    puts stderr "usage: quartus_stp -t boot-linux-master.tcl <kernel> <dtb>"
    exit 1
}

set kernel_path [lindex $argv 0]
set dtb_path    [lindex $argv 1]

foreach f [list $kernel_path $dtb_path] {
    if {![file exists $f]} {
        puts stderr "error: $f does not exist"
        exit 1
    }
}

set kbytes [file size $kernel_path]
set dbytes [file size $dtb_path]

# Pad both to 4-byte boundaries (in-memory; the on-disk file
# isn't modified). master_write_32 is word-aligned.
set kbytes_pad [expr {($kbytes + 3) & ~3}]
set dbytes_pad [expr {($dbytes + 3) & ~3}]
set kwords [expr {$kbytes_pad / 4}]
set dwords [expr {$dbytes_pad / 4}]

# Per the riski5 boot ABI, a1 points at &dtb = 0x80000000 +
# kbytes (the kernel image's actual byte length, NOT the padded
# count — the kernel knows where its own end is). LinuxBootMaster
# computes a1 from the kbytes value we write to SRAM, so we
# write the unpadded byte count.
set kbase     0x80000000
set dbase     [expr {$kbase + $kbytes_pad}]
set go_addr   0x20000000
set go_sentinel_addr [expr {$go_addr + 4}]

puts "boot-linux-master:"
puts "  kernel : $kernel_path ($kbytes bytes, padded to $kbytes_pad)"
puts "  dtb    : $dtb_path ($dbytes bytes, padded to $dbytes_pad)"
set k_end [expr {$kbase + $kbytes_pad - 1}]
set d_end [expr {$dbase + $dbytes_pad - 1}]
puts "  layout : kernel @ [format 0x%08x $kbase]..[format 0x%08x $k_end]"
puts "           dtb    @ [format 0x%08x $dbase]..[format 0x%08x $d_end]"
puts "  trigger: SRAM\[[format 0x%08x $go_addr]\] <- kbytes=$kbytes"
puts "           SRAM\[[format 0x%08x $go_sentinel_addr]\] <- 1"
puts ""

set masters [get_service_paths master]
if {[llength $masters] == 0} {
    puts stderr "error: no JTAG-Avalon-Master endpoints found."
    puts stderr "       is the riski5-core-linux-master bitstream flashed?"
    exit 1
}
set m [lindex $masters 0]
puts "  master : $m"
open_service master $m

# Helper: stream a binary file into SDRAM in 256-word (1 KB)
# chunks via master_write_32. Reports KB/s every second.
proc upload_file {m path base_addr size_bytes label} {
    set padded [expr {($size_bytes + 3) & ~3}]
    set words  [expr {$padded / 4}]

    set fp [open $path "rb"]
    fconfigure $fp -translation binary

    set chunk_words 256
    set written 0
    set last_print [clock milliseconds]
    set t_start    $last_print

    while {$written < $words} {
        set remaining [expr {$words - $written}]
        set this_chunk [expr {min($chunk_words, $remaining)}]
        set buf [read $fp [expr {$this_chunk * 4}]]
        # Pad the last chunk if the on-disk file is short of a
        # 4-byte boundary.
        if {[string length $buf] < $this_chunk * 4} {
            append buf [string repeat "\x00" [expr {$this_chunk * 4 - [string length $buf]}]]
        }
        set buf_words [list]
        for {set i 0} {$i < $this_chunk} {incr i} {
            binary scan $buf "@[expr {$i * 4}]i" w
            lappend buf_words [expr {$w & 0xFFFFFFFF}]
        }
        set addr [expr {$base_addr + $written * 4}]
        master_write_32 $m $addr $buf_words
        incr written $this_chunk

        set now [clock milliseconds]
        if {$now - $last_print > 1000} {
            set elapsed_s [expr {($now - $t_start) / 1000.0}]
            set kb_done   [expr {$written * 4 / 1024.0}]
            set kb_total  [expr {$padded / 1024.0}]
            set rate      [expr {$kb_done / $elapsed_s}]
            puts [format "  %-7s  %6.1f / %6.1f KB  @ %5.1f KB/s" \
                $label $kb_done $kb_total $rate]
            set last_print $now
        }
    }

    close $fp

    set t_end [clock milliseconds]
    set total_s [expr {($t_end - $t_start) / 1000.0}]
    set total_kb [expr {$padded / 1024.0}]
    if {$total_s < 0.001} { set total_s 0.001 }
    puts [format "  %-7s  done — %.1f KB in %.1f s (%.1f KB/s)" \
        $label $total_kb $total_s [expr {$total_kb / $total_s}]]
}

upload_file $m $kernel_path $kbase $kbytes "kernel"
upload_file $m $dtb_path    $dbase $dbytes "dtb"

puts ""
puts "Writing boot-trigger record..."
master_write_32 $m $go_addr [list $kbytes]
# A small barrier so the sentinel arrives strictly after the
# kbytes word — prevents the boot stub from racing against an
# in-flight kbytes update.
master_write_32 $m $go_sentinel_addr [list 1]

close_service master $m

puts ""
puts "Trigger written. Boot stub will JR to 0x80000000."
puts "Run 'nix run .#console' to see kernel printk on the JTAG-UART."
