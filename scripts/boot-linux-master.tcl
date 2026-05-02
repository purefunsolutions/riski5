# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# boot-linux-master.tcl — full Linux upload via the
# JTAG-to-Avalon-Master path, in one system-console Tcl session.
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

## Args come via env vars because System Console's --script= flag is
## broken in Quartus 13.0sp1 — see apps/boot-linux-master.nix for the
## stdin-pipe workaround and the matching `exit 0` at the end of this
## file.

if {![info exists ::env(BOOT_LINUX_KERNEL)] ||
    ![info exists ::env(BOOT_LINUX_DTB)]} {
    puts stderr "error: BOOT_LINUX_KERNEL and BOOT_LINUX_DTB must be set"
    exit 1
}
set kernel_path $::env(BOOT_LINUX_KERNEL)
set dtb_path    $::env(BOOT_LINUX_DTB)

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
# Park the DTB at 0x8040_0000 — well past the kernel's __bss_stop
# (~0x8036_F258 for our linux-rv32-nommu build). Placing it
# immediately after the kernel image (kbase + kbytes_pad) overlaps
# the kernel's BSS region; @clear_bss@ then zeroes the trailing
# part of the DTB before @setup_arch@ parses it, and Linux either
# panics or silently hangs depending on which DTB nodes survive.
# The boot stub at firmware/phase1/LinuxBootMaster.hs hard-codes
# the same address into @a1@ — keep them in sync.
set dbase     0x80400000
# The L-3a JTAG-load path routes JTAG-Avalon-Master writes only to
# SDRAM, so the trigger record has to live in SDRAM too. Park it
# at the very top of the 8 MB chip — a real kernel image can't
# reach this far during the upload phase. Once the kernel boots
# it may overwrite the trigger; the boot stub never re-reads it.
set go_addr   0x807FFFF0
set go_sentinel_addr [expr {$go_addr + 4}]

puts "boot-linux-master:"
puts "  kernel : $kernel_path ($kbytes bytes, padded to $kbytes_pad)"
puts "  dtb    : $dtb_path ($dbytes bytes, padded to $dbytes_pad)"
set k_end [expr {$kbase + $kbytes_pad - 1}]
set d_end [expr {$dbase + $dbytes_pad - 1}]
puts "  layout : kernel @ [format 0x%08x $kbase]..[format 0x%08x $k_end]"
puts "           dtb    @ [format 0x%08x $dbase]..[format 0x%08x $d_end]"
puts "  trigger: SDRAM\[[format 0x%08x $go_addr]\] <- kbytes=$kbytes"
puts "           SDRAM\[[format 0x%08x $go_sentinel_addr]\] <- 1"
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
        # Bulk-write the chunk, then issue one master_read at the
        # chunk's last address to force the Altera SDRAM IP to
        # drain its write buffer. This combines with the
        # input-latching SDRAM adapter (commit b3ed070's follow-up:
        # @latchedAddr/Wdata/Be@ in @Riski5.Sdram@) so the master's
        # bus signals don't have to remain stable through the
        # multi-cycle 32→16 write sequence.
        set addr [expr {$base_addr + $written * 4}]
        master_write_32 $m $addr $buf_words
        catch {master_read_32 $m $addr 1}
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

# Verify-and-retry pass over the first 64 words of an uploaded
# image. Reads each word back, compares against expected, and
# falls back to a single-word write+read+retry on mismatch (up
# to 3 retries per word). Existence-of-mismatches at THIS layer
# (after the new sticky arbiters) means the bulk master_write_32
# still has a residual drop pattern at specific cell offsets;
# the retry recovers each cell silently and reports a count.
proc verify_first_words {m path base_addr nwords label} {
    set fp [open $path "rb"]
    fconfigure $fp -translation binary
    set buf [read $fp [expr {$nwords * 4}]]
    close $fp

    set fixed 0
    set bad 0
    for {set i 0} {$i < $nwords} {incr i} {
        if {[string length $buf] < ($i + 1) * 4} { break }
        binary scan $buf "@[expr {$i * 4}]i" expected
        set expected [expr {$expected & 0xFFFFFFFF}]
        set wa [expr {$base_addr + $i * 4}]
        set rb [lindex [master_read_32 $m $wa 1] 0]
        if {$rb != $expected} {
            incr bad
            for {set retry 0} {$retry < 3} {incr retry} {
                master_write_32 $m $wa [list $expected]
                set rb [lindex [master_read_32 $m $wa 1] 0]
                if {$rb == $expected} { incr fixed; break }
            }
            puts [format "  verify %s @0x%08x: got 0x%08x want 0x%08x  %s" \
                $label $wa $rb $expected \
                [expr {$rb == $expected ? "fixed" : "PERMANENT MISMATCH"}]]
        }
    }
    puts [format "  verify %s: %d / %d words bulk-dropped, %d recovered" \
        $label $bad $nwords $fixed]
}

# Bulk verify the WHOLE uploaded image. Reads back in 256-word
# chunks (~150 ms per chunk via master_read_32) and compares each
# word to the source. Reports the first mismatch + total mismatch
# count. Catches the "high-address upload corruption" task #146
# left behind: the original 1024-word verify only covered the
# first 4 KB, but a 3.2 MB Linux upload corrupts arbitrary bytes
# at much higher offsets (silently, since master_read_32 reads
# back from the same SDRAM controller's row buffer that absorbed
# the bulk write). Slow path — adds ~1× the upload time. Worth
# it: without it, kernel boots into a wfi loop the first time
# `jalr setup_vm` lands on a corrupted instruction, with no
# diagnostic.
proc verify_all {m path base_addr size_bytes label} {
    set padded [expr {($size_bytes + 3) & ~3}]
    set words  [expr {$padded / 4}]
    set fp [open $path "rb"]
    fconfigure $fp -translation binary
    set buf [read $fp $padded]
    close $fp
    if {[string length $buf] < $padded} {
        append buf [string repeat "\x00" [expr {$padded - [string length $buf]}]]
    }

    set chunk_words 256
    set verified 0
    set bad 0
    set first_bad_addr -1
    set first_bad_got 0
    set first_bad_want 0
    set last_print [clock milliseconds]
    set t_start    $last_print

    while {$verified < $words} {
        set remaining [expr {$words - $verified}]
        set this_chunk [expr {min($chunk_words, $remaining)}]
        set addr [expr {$base_addr + $verified * 4}]
        set rb [master_read_32 $m $addr $this_chunk]
        for {set i 0} {$i < $this_chunk} {incr i} {
            binary scan $buf "@[expr {($verified + $i) * 4}]i" expected
            set expected [expr {$expected & 0xFFFFFFFF}]
            set got [expr {[lindex $rb $i] & 0xFFFFFFFF}]
            if {$got != $expected} {
                if {$first_bad_addr == -1} {
                    set first_bad_addr [expr {$addr + $i * 4}]
                    set first_bad_got $got
                    set first_bad_want $expected
                }
                incr bad
            }
        }
        incr verified $this_chunk

        set now [clock milliseconds]
        if {$now - $last_print > 1000} {
            set elapsed_s [expr {($now - $t_start) / 1000.0}]
            set kb_done   [expr {$verified * 4 / 1024.0}]
            set kb_total  [expr {$padded / 1024.0}]
            set rate      [expr {$kb_done / $elapsed_s}]
            puts [format "  verify-all %s  %6.1f / %6.1f KB  @ %5.1f KB/s  (%d bad so far)" \
                $label $kb_done $kb_total $rate $bad]
            set last_print $now
        }
    }

    if {$bad == 0} {
        puts [format "  verify-all %s: %d / %d words OK" $label $verified $words]
    } else {
        puts [format "  verify-all %s: %d / %d words BAD; first @ 0x%08x: got 0x%08x want 0x%08x" \
            $label $bad $verified $first_bad_addr $first_bad_got $first_bad_want]
    }
    return $bad
}

upload_file $m $kernel_path $kbase $kbytes "kernel"
upload_file $m $dtb_path    $dbase $dbytes "dtb"

# Verify the kernel image. Earlier versions verified just the
# first 64 words (=256 bytes = 0x100 = the .head.text reset
# vector + lottery + setup_trap_vector area), based on the belief
# that bulk master_write_32 was reliable past that point.
#
# Task #144 SDRAM-readback diagnosis (2026-04-30) found persistent
# corruption of 32-bit words' UPPER half-words in the 0x1A0..0x224
# range — the Linux kernel's reset_regs FP-register-clear sequence
# (fmv.w.x ft0..ft11). Lower 16 bits committed correctly; upper 16
# bits stayed at random pre-existing SDRAM values. The kernel
# happens to expose this only for SMP=n builds where the FP code
# starts at 0x1A8 (the SMP=y kernel had GPR-clear instructions
# there with upper bits = 0, which trivially matched). So the
# bulk-write reliability claim was wrong; we just got lucky on
# the SMP=y baseline.
#
# Bumping the verify to 1024 words (= 4 KB) covers all of
# .head.text in the SMP=n kernel (head.text is 0x2DC bytes; 4 KB
# is 5x that, generous margin for any future head.S growth).
# Cost: ~1 sec at ~1ms/word read. Trivial vs. the 5-min upload.
# If we ever measure systematic drops past 4 KB, extend further.
verify_first_words $m $kernel_path $kbase 1024 "kernel"

# Full-kernel bulk verify. Catches any silent upload corruption
# past the 4 KB window the per-word verify covers.
set kbad [verify_all $m $kernel_path $kbase $kbytes "kernel"]
if {$kbad > 0} {
    puts ""
    puts "ABORTING: kernel image corrupted in SDRAM after upload."
    puts "  Boot stub would JR into garbage and silent-hang in wfi."
    puts "  Re-flash the bitstream and try again, or root-cause the"
    puts "  upload corruption (task #17 in TODO.md)."
    close_service master $m
    exit 1
}

# Earlier versions ran a "Fixup" pass here that overwrote the
# 0x800000A4..0x800000C0 region with hardcoded LINUX-KERNEL bytes
# (csrw mie / csrw mip / fence.i / jal / auipc / addi / csrw mtvec
# / li). It was a workaround for the Altera-master IP's silent
# write-drops in those specific cells. With the bridge replaced
# by `Riski5.JtagAvalonMaster` (commit dcb225d) and the SoC bus
# fixed by the sticky JTAG-mux + sticky fetch/data arbiters
# (commits a6df51b + 5781b44), every host-side write commits
# correctly. The fixup is no longer needed and was actively
# harmful for non-Linux payloads — it overwrote arbitrary
# instruction words with the kernel's specific bytes, so any
# upload other than the Linux Image was getting silently
# corrupted at +0xA4..+0xC0.

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

# Tell System Console (the host REPL) to exit after the upload — see
# the comment in apps/boot-linux-master.nix about the
# `source ... | system-console -cli` pattern.
exit 0
