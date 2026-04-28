#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# load-linux.sh — host-side counterpart to firmware/phase1/LinuxBoot.hs.
# Sends a kernel image + device-tree blob to the riski5 board over the
# JTAG-UART tap. The on-board boot stub writes both into SDRAM, then
# JALRs into the kernel with the standard RISC-V Linux boot ABI
# (a0 = hartid, a1 = &dtb).
#
# Workflow:
#   nix build .#riski5-core-linux       # build the bitstream
#   nix build .#linux-rv32-nommu        # build the kernel (slow)
#   nix build .#riski5-dtb              # build the device tree
#   nix run   .#flash-riski5-linux      # flash the bitstream
#   scripts/load-linux.sh \
#       result-linux/Image \
#       result-dtb/riski5.dtb           # send kernel + DTB
#
# Wire-protocol (must match LinuxBoot.hs):
#   bytes 0..3 : little-endian kernel word count K
#   bytes 4..7 : little-endian DTB    word count D
#   then       : K * 4 bytes of kernel
#   then       : D * 4 bytes of DTB
#
# After 'D' marker on the JTAG-UART, kernel printk output streams via
# the same tap (`earlycon=jtag-uart,mmio,0x10000000` in our DTS).
# Ctrl-C the nios2-terminal to stop.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <kernel-image> <dtb>" >&2
  echo "" >&2
  echo "  flash the loader bitstream first:" >&2
  echo "    nix run .#flash-riski5-linux" >&2
  exit 2
fi

KERNEL="$1"
DTB="$2"

for f in "$KERNEL" "$DTB"; do
  if [[ ! -f "$f" ]]; then
    echo "error: $f does not exist" >&2
    exit 1
  fi
done

KBYTES=$(stat -c %s "$KERNEL")
DBYTES=$(stat -c %s "$DTB")

# Both blobs must be a multiple of 4 bytes; pad with zeros otherwise.
# (The DTB tail can have arbitrary bytes; kernel Image is naturally
# 4-byte aligned by the linker.)
KBYTES_PAD=$(( (KBYTES + 3) & ~3 ))
DBYTES_PAD=$(( (DBYTES + 3) & ~3 ))
KWORDS=$(( KBYTES_PAD / 4 ))
DWORDS=$(( DBYTES_PAD / 4 ))

echo "Loading:"
echo "  kernel:   $KERNEL ($KBYTES bytes, $KWORDS words pad-aligned)"
echo "  dtb:      $DTB ($DBYTES bytes, $DWORDS words pad-aligned)"
echo "  layout:"
echo "    [0x80000000 .. 0x$(printf '%08x' $((0x80000000 + KBYTES_PAD - 1)))]  kernel"
echo "    [0x$(printf '%08x' $((0x80000000 + KBYTES_PAD)))   .. 0x$(printf '%08x' $((0x80000000 + KBYTES_PAD + DBYTES_PAD - 1)))]  dtb"
echo ""
echo "Make sure the linux-boot bitstream is flashed and KEY0 has been pressed."
echo "Watching for 'L' marker on the JTAG-UART before sending..."

python3 - "$KWORDS" "$DWORDS" "$KERNEL" "$DTB" <<'PY' | nios2-terminal
import struct
import sys

kwords     = int(sys.argv[1])
dwords     = int(sys.argv[2])
kernel_path = sys.argv[3]
dtb_path    = sys.argv[4]

out = sys.stdout.buffer

# Length prefixes.
out.write(struct.pack('<I', kwords))
out.write(struct.pack('<I', dwords))

# Kernel, padded to multiple of 4.
with open(kernel_path, 'rb') as f:
    data = f.read()
pad = (-len(data)) % 4
out.write(data)
out.write(b'\x00' * pad)

# DTB, padded to multiple of 4.
with open(dtb_path, 'rb') as f:
    data = f.read()
pad = (-len(data)) % 4
out.write(data)
out.write(b'\x00' * pad)

out.flush()
PY
