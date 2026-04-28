# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# `nix run .#load-linux` — host-side counterpart to
# firmware/phase1/LinuxBoot.hs. Sends a kernel image + device-tree
# blob to the riski5 board over the JTAG-UART tap, then attaches a
# nios2-terminal so the user sees kernel printk output.
#
# Defaults: when invoked with no args, uses the kernel + DTB built
# by the riski5 flake (`linux-rv32-nommu/Image` and
# `riski5-dtb/riski5.dtb`). Override either by passing two
# explicit paths:
#
#     nix run .#load-linux                     # use defaults
#     nix run .#load-linux -- kernel.bin dtb   # override both
#
# The default path triggers a Linux kernel build the first time
# you run it (~5 min). Subsequent runs are cached.
{
  writeShellApplication,
  python3,
  quartus-ii-13,
  linux-rv32-nommu,
  riski5-dtb,
}:
writeShellApplication {
  name = "load-linux";
  runtimeInputs = [quartus-ii-13 python3];
  text = ''
    set -euo pipefail

    # Defaults from the flake build.
    DEFAULT_KERNEL="${linux-rv32-nommu}/Image"
    DEFAULT_DTB="${riski5-dtb}/riski5.dtb"

    if [[ $# -eq 0 ]]; then
      KERNEL="$DEFAULT_KERNEL"
      DTB="$DEFAULT_DTB"
      echo "load-linux: using default kernel + DTB from the flake"
    elif [[ $# -eq 2 ]]; then
      KERNEL="$1"
      DTB="$2"
    else
      echo "usage: nix run .#load-linux [-- <kernel-image> <dtb>]" >&2
      echo "" >&2
      echo "  flash the linux-boot bitstream first:" >&2
      echo "    nix run .#flash-riski5-linux" >&2
      echo "" >&2
      echo "  with no args: uses the flake-built kernel + DTB:" >&2
      echo "    $DEFAULT_KERNEL" >&2
      echo "    $DEFAULT_DTB" >&2
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

    echo "Loading:"
    echo "  kernel:   $KERNEL ($KBYTES bytes, $KWORDS words pad-aligned)"
    echo "  dtb:      $DTB ($DBYTES bytes, $DWORDS words pad-aligned)"
    echo "  layout:"
    printf "    [0x80000000 .. 0x%08x]  kernel\n" $((0x80000000 + KBYTES_PAD - 1))
    printf "    [0x%08x .. 0x%08x]  dtb\n" \
      $((0x80000000 + KBYTES_PAD)) $((0x80000000 + KBYTES_PAD + DBYTES_PAD - 1))
    echo ""
    echo "Make sure the linux-boot bitstream is flashed and KEY0 has been pressed."
    echo "Watching for 'L' marker on the JTAG-UART before sending..."

    python3 - "$KWORDS" "$DWORDS" "$KERNEL" "$DTB" <<'PY' | nios2-terminal
    import struct
    import sys

    kwords      = int(sys.argv[1])
    dwords      = int(sys.argv[2])
    kernel_path = sys.argv[3]
    dtb_path    = sys.argv[4]

    out = sys.stdout.buffer

    out.write(struct.pack('<I', kwords))
    out.write(struct.pack('<I', dwords))

    with open(kernel_path, 'rb') as f:
        data = f.read()
    pad = (-len(data)) % 4
    out.write(data)
    out.write(b'\x00' * pad)

    with open(dtb_path, 'rb') as f:
        data = f.read()
    pad = (-len(data)) % 4
    out.write(data)
    out.write(b'\x00' * pad)

    out.flush()
    PY
  '';
}
