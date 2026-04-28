# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# `nix run .#boot-linux` — single-shot Linux silicon bring-up:
#
#   1. Kill any stale jtagd / nios2-terminal that's hanging onto
#      the USB-Blaster from a previous run.
#   2. Flash the linuxBoot bitstream onto the DE2. FPGA
#      reconfiguration IS a reset, so this is exactly equivalent
#      to a KEY0 press as far as the boot ROM is concerned.
#   3. Brief settle (~0.5 s) so the boot ROM finishes _start +
#      bss zero-fill and is sitting in the polling loop ready to
#      accept bytes.
#   4. Stream kernel + DTB into the JTAG-UART; nios2-terminal
#      stays attached so kernel printk lands in the user's shell.
#
# Replaces the old two-step `nix run .#flash-riski5-linux && nix
# run .#load-linux` workflow. The two-step variant survived
# random failures because:
#
#   - Stale jtagd / nios2-terminal sometimes held the device,
#     causing the second step to hang or get truncated output.
#   - "KEY0 must be pressed" was load-bearing folk-wisdom that
#     wasn't actually wired up — the boot ROM relied on whatever
#     state was there at session start, which silently got out
#     of sync with stale data left over from an earlier load
#     attempt.
#
# Both go away when the flash + load are atomic in one script.
#
# Defaults: when invoked with no args, uses the kernel + DTB
# built by the riski5 flake. Override either by passing two
# explicit paths:
#
#     nix run .#boot-linux                     # use defaults
#     nix run .#boot-linux -- kernel.bin dtb   # override both
#
# After loading completes, riski5-load-stream switches to
# interactive mode — keystrokes are forwarded into the running
# kernel's tty.
{
  writeShellApplication,
  psmisc,
  quartus-ii-13,
  riski5-core-linux,
  riski5-load-stream,
  linux-rv32-nommu,
  riski5-dtb,
}:
writeShellApplication {
  name = "boot-linux";
  runtimeInputs = [quartus-ii-13 psmisc riski5-load-stream];
  text = ''
    set -euo pipefail

    DEFAULT_KERNEL="${linux-rv32-nommu}/Image"
    DEFAULT_DTB="${riski5-dtb}/riski5.dtb"

    if [[ $# -eq 0 ]]; then
      KERNEL="$DEFAULT_KERNEL"
      DTB="$DEFAULT_DTB"
      echo "boot-linux: using default kernel + DTB from the flake"
    elif [[ $# -eq 2 ]]; then
      KERNEL="$1"
      DTB="$2"
    else
      cat >&2 <<EOF
    usage: nix run .#boot-linux [-- <kernel-image> <dtb>]

      with no args: uses the flake-built kernel + DTB:
        $DEFAULT_KERNEL
        $DEFAULT_DTB
    EOF
      exit 2
    fi

    for f in "$KERNEL" "$DTB"; do
      if [[ ! -f "$f" ]]; then
        echo "error: $f does not exist" >&2
        exit 1
      fi
    done

    KBYTES=$(stat -c %s "$KERNEL")
    DBYTES=$(stat -c %s "$DTB")
    KBYTES_PAD=$(( (KBYTES + 3) & ~3 ))
    DBYTES_PAD=$(( (DBYTES + 3) & ~3 ))
    KWORDS=$(( KBYTES_PAD / 4 ))
    DWORDS=$(( DBYTES_PAD / 4 ))

    SOF="${riski5-core-linux}/Riski5.sof"
    if [[ ! -f "$SOF" ]]; then
      echo "missing $SOF — did the linuxBoot bitstream build?" >&2
      exit 1
    fi

    # Step 1 — purge stale JTAG holders. jtagd is the daemon
    # quartus_pgm spawns; nios2-terminal is what a previous
    # boot-linux run leaves attached after the user Ctrl-C's
    # the kernel. Both block the cable until killed.
    echo "== boot-linux: clearing stale JTAG holders =="
    pkill -9 -f nios2-terminal 2>/dev/null || :
    killall -q jtagd || :
    sleep 0.3

    # Step 2 — locate the cable. Same auto-detect as
    # apps/flash-riski5.nix.
    echo "== boot-linux: detecting USB-Blaster =="
    cable=$(jtagconfig | awk -F') ' '/USB-Blaster/ {print $2; exit}' | sed 's/ *$//')
    if [[ -z "$cable" ]]; then
      echo "no USB-Blaster detected — is the board plugged in and powered?" >&2
      exit 1
    fi
    echo "  cable: $cable"

    # Step 3 — flash. quartus_pgm's @p;<sof>@ verb performs FPGA
    # reconfiguration which is itself a reset; the boot ROM at
    # PC=0 is guaranteed to be at the start of _start the moment
    # this returns "Configuration succeeded".
    echo "== boot-linux: flashing $SOF =="
    quartus_pgm -c "$cable" -m JTAG -o "p;$SOF"

    # Step 4 — settle. Boot ROM runs _start (sp setup, bss
    # zero-fill in SRAM, ~80 cycles), prints 'L', enters the
    # polling loop. 500 ms at 40 MHz is 20 M cycles — orders
    # of magnitude more than needed, but cheap.
    sleep 0.5

    # Step 5 — stream. riski5-load-stream owns nios2-terminal
    # spawning, header building, progress bar, and post-load
    # interactive forwarding.
    echo "== boot-linux: streaming kernel ($KBYTES B) + DTB ($DBYTES B) =="
    exec riski5-load-stream linux \
      "$KWORDS" "$DWORDS" "$KERNEL" "$DTB"
  '';
}
