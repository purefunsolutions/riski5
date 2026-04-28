# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# `nix run .#load-sdram-master -- <bin> <base-hex>` — host-side
# direct-to-SDRAM upload via the JTAG-to-Avalon-Master bridge IP
# that the riski5-core-linux bitstream contains. Bypasses the
# JTAG-UART RX path entirely.
#
# Workflow:
#   nix run .#flash-riski5-linux              # 1. flash bitstream
#   nix run .#load-sdram-master -- foo.bin 0x80000000
#                                              # 2. upload via Tcl
#
# The wrapper just forwards args to scripts/load-sdram-master.tcl
# under `quartus_stp`. See that file for the actual transport
# logic.
{
  writeShellApplication,
  psmisc,
  quartus-ii-13,
}:
writeShellApplication {
  name = "load-sdram-master";
  runtimeInputs = [quartus-ii-13 psmisc];
  text = ''
    set -euo pipefail

    if [[ $# -ne 2 ]]; then
      cat >&2 <<EOF
    usage: nix run .#load-sdram-master -- <bin-path> <base-addr-hex>

      flash the loader bitstream first:
        nix run .#flash-riski5-linux

      then call this with a 4-byte-aligned blob and a base address:
        nix run .#load-sdram-master -- kernel.bin 0x80000000
    EOF
      exit 2
    fi

    BIN_PATH="$1"
    BASE_ADDR="$2"

    if [[ ! -f "$BIN_PATH" ]]; then
      echo "error: $BIN_PATH does not exist" >&2
      exit 1
    fi

    # Release the cable from any stale jtagd / nios2-terminal so
    # quartus_stp can grab a fresh JTAG session.
    pkill -9 -f nios2-terminal 2>/dev/null || :
    killall -q jtagd || :
    sleep 0.3

    exec quartus_stp -t ${../scripts/load-sdram-master.tcl} "$BIN_PATH" "$BASE_ADDR"
  '';
}
