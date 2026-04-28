#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# load-sdram-jtag.sh — host-side counterpart to firmware/phase1/SdramLoader.hs.
# Sends a length-prefixed binary blob to the riski5 board over the JTAG-UART
# tap; the on-board loader writes it to SDRAM at 0x80000000+ and JALRs there.
#
# Usage:
#   nix run .#flash-riski5-sdramload     # flash the loader bitstream
#   scripts/load-sdram-jtag.sh kernel.bin
#
# The script:
#   1. Validates that <bin-path> exists and its byte length is a multiple of 4.
#   2. Computes word_count = bytes / 4 and emits a 4-byte little-endian
#      header followed by the binary verbatim.
#   3. Pipes the resulting stream into nios2-terminal's stdin.
#
# The on-board firmware reads exactly (4 + 4 × word_count) bytes, prints
# 'L' (loader ready) and 'D' (load complete) markers around the load, then
# JALRs to 0x80000000. After 'D', further UART output is whatever the
# loaded program writes.
#
# Throughput: the JTAG-UART TX path runs at ~100 KB/s end-to-end; an 8 MB
# Linux image takes ~80 s. One-time cost per kernel rebuild (the DE2 keeps
# SDRAM contents through KEY0 reset, so re-running an already-loaded image
# is just KEY0 + a quick re-flash isn't even needed).

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <bin-path>" >&2
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
echo "  destination: 0x80000000 .. $(printf '0x%08x' $(( 0x80000000 + BYTES - 1 )))"
echo ""
echo "Make sure the loader bitstream is flashed and KEY0 has been pressed."
echo "Watching for 'L' marker on the JTAG-UART before sending..."

# Compose: 4-byte LE word count + binary verbatim.
# `printf` with %.4b gives little-endian 32-bit; prefer python for clarity.
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
