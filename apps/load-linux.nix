# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# `nix run .#load-linux` — host-side counterpart to
# firmware/phase1/LinuxBoot.hs. Spawns nios2-terminal, sends a
# kernel + device-tree blob into its stdin with a live progress
# bar, then keeps the terminal attached so kernel printk lands
# in the user's shell.
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
#
# All transport / progress / subprocess machinery lives in the
# Haskell host-tool `riski5-load-stream`, defined at
# `tools/load-stream/Main.hs`. This wrapper only does
# arg-validation + word-count math.
{
  writeShellApplication,
  quartus-ii-13,
  riski5-load-stream,
  linux-rv32-nommu,
  riski5-dtb,
}:
writeShellApplication {
  name = "load-linux";
  # quartus-ii-13 supplies nios2-terminal, which riski5-load-stream
  # spawns as a subprocess and pipes the kernel+DTB into.
  runtimeInputs = [riski5-load-stream quartus-ii-13];
  text = ''
    set -euo pipefail

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
      cat >&2 <<EOF
    usage: nix run .#load-linux [-- <kernel-image> <dtb>]

      flash the linux-boot bitstream first:
        nix run .#flash-riski5-linux

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

    exec riski5-load-stream linux \
      "$KWORDS" "$DWORDS" "$KERNEL" "$DTB"
  '';
}
