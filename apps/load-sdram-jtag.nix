# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# `nix run .#load-sdram-jtag -- <bin-path>` — host-side counterpart
# to firmware/phase1/SdramLoader.hs. Spawns nios2-terminal, sends
# a length-prefixed binary blob into its stdin with a live progress
# bar, then keeps the terminal attached so any post-load output
# from the on-board firmware streams to the user's shell.
#
# Bitstream prerequisite (run once before each load):
#
#     nix run .#flash-riski5-sdramload
#
# Then load and watch:
#
#     nix run .#load-sdram-jtag -- result/program.bin
#
# Transport / progress / subprocess machinery lives in
# `riski5-load-stream` (tools/load-stream/Main.hs).
{
  writeShellApplication,
  quartus-ii-13,
  riski5-load-stream,
}:
writeShellApplication {
  name = "load-sdram-jtag";
  # quartus-ii-13 supplies nios2-terminal, which riski5-load-stream
  # spawns as a subprocess and pipes the blob into.
  runtimeInputs = [riski5-load-stream quartus-ii-13];
  text = ''
    set -euo pipefail

    if [[ $# -ne 1 ]]; then
      cat >&2 <<EOF
    usage: nix run .#load-sdram-jtag -- <bin-path>

      flash the loader bitstream first:
        nix run .#flash-riski5-sdramload
    EOF
      exit 2
    fi

    BIN_PATH="$1"

    if [[ ! -f "$BIN_PATH" ]]; then
      echo "error: $BIN_PATH does not exist" >&2
      exit 1
    fi

    BYTES=$(stat -c %s "$BIN_PATH")
    if (( BYTES % 4 != 0 )); then
      echo "error: $BIN_PATH has $BYTES bytes, not a multiple of 4. Pad it first." >&2
      exit 1
    fi

    WORDS=$(( BYTES / 4 ))

    exec riski5-load-stream sdram-jtag "$WORDS" "$BIN_PATH"
  '';
}
