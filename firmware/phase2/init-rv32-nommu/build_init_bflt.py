#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
"""Wrap a flat-binary RISC-V `.text` blob in a BFLT v4 header.

Linux nommu loads BFLT (Binary Flat) executables via
`fs/binfmt_flat.c`. The format prepends a 64-byte header that
records the magic, version, and the segment offsets +
relocation-table offsets within the file. For our tiny `_start`
stub the segments are degenerate: no rodata-as-data,
no relocations, no GOT — so most header fields are zero and the
whole thing is a constant-shape "stub" header.

Usage:
    build_init_bflt.py <input.bin> <output.flat>

Where <input.bin> is the output of
`riscv64-unknown-linux-gnu-objcopy -O binary init.elf init.bin`
(plus -j .text -j .rodata to keep both segments in one blob).

Reference: include/uapi/linux/flat.h in the Linux tree.
"""

import struct
import sys


BFLT_MAGIC = b"bFLT"
BFLT_VERSION = 4

# Header layout (uapi/linux/flat.h, struct flat_hdr):
#
#   char    magic[4];         = "bFLT"
#   __be32  rev;              = 4
#   __be32  entry;            offset of _start in the loaded
#                             image (0 — _start is the first
#                             instruction in our flat).
#   __be32  data_start;       offset of data segment (= text size,
#                             but we have no data → just text size).
#   __be32  data_end;         offset of end of data (= bss start).
#   __be32  bss_end;          offset of end of bss (= total size).
#   __be32  stack_size;       requested stack size (4 KB is plenty
#                             for our stub).
#   __be32  reloc_start;      offset of relocation table (0 — no
#                             relocations in -fpic flat).
#   __be32  reloc_count;      = 0
#   __be32  flags;            = 0
#   __be32  build_date;       = 0 (we leave reproducibility on
#                             our build system).
#   char    filler[5*4];      = zeros
#
# 4 + 12 * 4 = 52 ... wait that's 52 not 64. Let me recount.
# 4 (magic) + 4 (rev) + 4 (entry) + 4 (data_start) + 4 (data_end)
#   + 4 (bss_end) + 4 (stack_size) + 4 (reloc_start) + 4 (reloc_count)
#   + 4 (flags) + 4 (build_date) + 5*4 (filler) = 64. OK.


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write(
            "usage: build_init_bflt.py <input.bin> <output.flat>\n"
        )
        return 2

    in_path, out_path = sys.argv[1], sys.argv[2]

    with open(in_path, "rb") as f:
        text = f.read()

    text_size = len(text)
    # 4 (magic) + 10 × 4 (be32 fields) + 20 (filler 5×4 bytes) = 64.
    header = struct.pack(
        ">4sIIIIIIIIII20s",
        BFLT_MAGIC,
        BFLT_VERSION,
        0,                  # entry — start of text
        64 + text_size,     # data_start (= end of text within file;
                            # we have no data segment, so this also
                            # equals data_end below)
        64 + text_size,     # data_end
        64 + text_size,     # bss_end (no bss either)
        4096,               # stack_size — 4 KB is plenty
        0,                  # reloc_start
        0,                  # reloc_count
        0,                  # flags
        0,                  # build_date
        b"\x00" * 20,       # filler[5*4] bytes
    )
    assert len(header) == 64, len(header)

    with open(out_path, "wb") as f:
        f.write(header)
        f.write(text)

    print(f"BFLT: {out_path} ({64 + text_size} bytes total, "
          f"{text_size} byte text)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
