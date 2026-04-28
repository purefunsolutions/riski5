# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# `nix run .#load-sdram-jtag -- <bin-path>` — host-side counterpart
# to firmware/phase1/SdramLoader.hs. Sends a length-prefixed binary
# blob over the JTAG-UART tap; the on-board SdramLoader writes it
# to SDRAM at 0x80000000+ and JALRs there.
#
# Bitstream prerequisite (run once before each load):
#
#     nix run .#flash-riski5-sdramload
#
# Then load and watch:
#
#     nix run .#load-sdram-jtag -- result/program.bin
#
# The shell-script equivalent at scripts/load-sdram-jtag.sh works
# the same way without the Nix-app wrapper, useful for iterations
# that don't want to re-resolve flake outputs.
{
  writeShellApplication,
  python3,
  quartus-ii-13,
}:
writeShellApplication {
  name = "load-sdram-jtag";
  runtimeInputs = [quartus-ii-13 python3];
  text = ''
    set -euo pipefail

    if [[ $# -ne 1 ]]; then
      echo "usage: nix run .#load-sdram-jtag -- <bin-path>" >&2
      echo "" >&2
      echo "  flash the loader bitstream first:" >&2
      echo "    nix run .#flash-riski5-sdramload" >&2
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

    echo "Loading $BIN_PATH:"
    echo "  bytes:       $BYTES"
    echo "  word count:  $WORDS"
    printf "  destination: 0x80000000 .. 0x%08x\n" $((0x80000000 + BYTES - 1))
    echo ""
    echo "Make sure the loader bitstream is flashed and KEY0 has been pressed."
    echo "Watching for 'L' marker on the JTAG-UART before sending..."

    python3 - "$WORDS" "$BIN_PATH" <<'PY' | nios2-terminal
    import struct
    import sys

    word_count = int(sys.argv[1])
    bin_path   = sys.argv[2]

    out = sys.stdout.buffer
    out.write(struct.pack('<I', word_count))
    with open(bin_path, 'rb') as f:
        out.write(f.read())
    out.flush()
    PY
  '';
}
