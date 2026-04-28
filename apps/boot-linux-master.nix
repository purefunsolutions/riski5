# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# `nix run .#boot-linux-master` — single-shot Linux boot via the
# JTAG-to-Avalon-Master upload path.
#
# Pipeline:
#   1. Kill stale jtagd / nios2-terminal so quartus_pgm + quartus_stp
#      can grab the cable cleanly.
#   2. quartus_pgm → flash riski5-core-linux-master bitstream.
#   3. Recycle jtagd so quartus_stp's master service enumerates
#      against the freshly-flashed FPGA.
#   4. quartus_stp -t boot-linux-master.tcl writes kernel + DTB
#      into SDRAM and the trigger record into SRAM.
#   5. Recycle jtagd one more time.
#   6. exec nios2-terminal so kernel printk lands in the user's
#      shell, with stdin forwarded (interactive console).
#
# Replaces the JTAG-UART loader (boot-linux) for cases where the
# slow link is a problem. The JTAG-Master IP uses a different
# JTAG-streaming protocol than JTAG-UART so it isn't subject to
# the same per-byte overhead.
#
# Defaults: kernel = $linux-rv32-nommu/Image, dtb = $riski5-dtb/
# riski5.dtb. Override by passing two paths:
#
#   nix run .#boot-linux-master                   # use defaults
#   nix run .#boot-linux-master -- kernel.bin dtb.bin
{
  writeShellApplication,
  psmisc,
  quartus-ii-13,
  riski5-core-linux-master,
  linux-rv32-nommu,
  riski5-dtb,
}:
writeShellApplication {
  name = "boot-linux-master";
  runtimeInputs = [quartus-ii-13 psmisc];
  text = ''
    set -euo pipefail

    DEFAULT_KERNEL="${linux-rv32-nommu}/Image"
    DEFAULT_DTB="${riski5-dtb}/riski5.dtb"

    if [[ $# -eq 0 ]]; then
      KERNEL="$DEFAULT_KERNEL"
      DTB="$DEFAULT_DTB"
      echo "boot-linux-master: using default kernel + DTB from the flake"
    elif [[ $# -eq 2 ]]; then
      KERNEL="$1"
      DTB="$2"
    else
      cat >&2 <<EOF
    usage: nix run .#boot-linux-master [-- <kernel-image> <dtb>]
    EOF
      exit 2
    fi

    for f in "$KERNEL" "$DTB"; do
      [[ -f "$f" ]] || { echo "error: $f does not exist" >&2; exit 1; }
    done

    SOF="${riski5-core-linux-master}/Riski5.sof"
    [[ -f "$SOF" ]] || {
      echo "missing $SOF — did the linuxBootMaster bitstream build?" >&2
      exit 1
    }

    # Step 1 — purge stale JTAG holders.
    echo "== boot-linux-master: clearing stale JTAG holders =="
    pkill -9 -f nios2-terminal 2>/dev/null || :
    killall -q jtagd || :
    sleep 0.3

    # Step 2 — locate cable.
    echo "== boot-linux-master: detecting USB-Blaster =="
    cable=$(jtagconfig | awk -F') ' '/USB-Blaster/ {print $2; exit}' | sed 's/ *$//')
    if [[ -z "$cable" ]]; then
      echo "no USB-Blaster detected — is the board plugged in and powered?" >&2
      exit 1
    fi
    echo "  cable: $cable"

    # Step 3 — flash bitstream (also resets the FPGA).
    echo "== boot-linux-master: flashing $SOF =="
    quartus_pgm -c "$cable" -m JTAG -o "p;$SOF"

    # Step 4 — recycle jtagd so quartus_stp's master service
    # enumerates against the freshly-flashed FPGA.
    killall -q jtagd || :
    sleep 0.5

    # Step 5 — upload kernel + DTB + go-trigger via master_write_32.
    # `system-console` lives in sopc_builder/bin/ inside the unwrapped
    # Quartus install. The alterade2-flake wrapper exports
    # quartus_stp / quartus_pgm / etc. but not system-console
    # itself, so we extract the FHS-env path from any wrapped tool's
    # shell script and invoke `system-console` via the same FHS env
    # (which has $QSYS_ROOTDIR on PATH already, see fhs-env.nix).
    echo "== boot-linux-master: streaming kernel + DTB via master_write_32 =="
    fhs_wrapper=$(grep -oE '/nix/store/[^/]+-quartus-ii-13/bin/quartus-ii-13' \
        "$(command -v quartus_stp)" | head -1)
    if [[ -z "$fhs_wrapper" ]]; then
      echo "error: could not extract FHS path from quartus_stp wrapper" >&2
      exit 1
    fi
    # Pass paths via env vars — System Console's --script= flag
    # doesn't propagate positional argv to the Tcl interpreter.
    BOOT_LINUX_KERNEL="$KERNEL" \
    BOOT_LINUX_DTB="$DTB" \
    "$fhs_wrapper" system-console \
        --script=${../scripts/boot-linux-master.tcl} \
        -cli

    # Step 6 — recycle jtagd again so nios2-terminal gets a fresh
    # JTAG-UART handle (the master service's connection may have
    # left the IP in a state nios2-terminal needs to re-init).
    killall -q jtagd || :
    sleep 0.5

    # Step 7 — open kernel console.
    echo "== boot-linux-master: opening kernel console =="
    echo "  kernel printk and your keystrokes are now bridged."
    echo "  press Ctrl-C to detach."
    exec nios2-terminal
  '';
}
