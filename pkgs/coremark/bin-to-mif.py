# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# Convert a raw little-endian .bin (output of
# `riscv32-none-elf-objcopy -O binary`) to a Quartus MIF. The MIF is
# a 32-bit-word-per-line image indexed from address 0; consumed by
# Clash via $readmemh / listToVecTH or by Quartus as ROM initial
# contents for the phase-1 imem M4K block.
#
# Usage: python3 bin-to-mif.py <input.bin> <output.mif>
import struct
import sys

if len(sys.argv) != 3:
    sys.stderr.write("usage: bin-to-mif.py <input.bin> <output.mif>\n")
    sys.exit(2)

src_path, dst_path = sys.argv[1], sys.argv[2]

with open(src_path, "rb") as f:
    data = f.read()

# Zero-pad up to a multiple of 4 so struct.unpack doesn't truncate
# a trailing partial word. CoreMark's .text is always word-aligned
# by virtue of the linker script, but .rodata at the very end of the
# image may not be — safer to pad explicitly.
pad = (-len(data)) % 4
data += b"\x00" * pad
word_count = len(data) // 4
words = struct.unpack(f"<{word_count}I", data)

with open(dst_path, "w") as f:
    f.write(f"DEPTH = {word_count};\n")
    f.write("WIDTH = 32;\n")
    f.write("ADDRESS_RADIX = HEX;\n")
    f.write("DATA_RADIX = HEX;\n")
    f.write("CONTENT\nBEGIN\n")
    for addr, w in enumerate(words):
        f.write(f"    {addr:x} : {w:08x};\n")
    f.write("END;\n")
