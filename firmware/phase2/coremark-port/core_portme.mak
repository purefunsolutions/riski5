# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# riski5 CoreMark port Makefile fragment. Included by upstream
# CoreMark's top-level Makefile when invoked with PORT_DIR pointing
# here. Upstream handles: the five core_*.c files, the compile →
# link two-step (we opt into SEPARATE_COMPILE below), the run1/run2
# log machinery. We just tell it *how* to cross-compile.

# Cross toolchain. Supplied by
# pkgsCross.riscv32-embedded.buildPackages.gcc on the riski5
# devshell; pkgs/coremark/package.nix adds the same to the
# derivation's nativeBuildInputs.
CC              = riscv32-none-elf-gcc
LD              = $(CC)
AS              = $(CC)

# Compiler flags. RV32IM (we ship the M-extension for mul/div),
# ILP32 ABI, freestanding. -ffunction-sections + -fdata-sections
# let the linker garbage-collect unreachable code for a smaller
# .text, which matters because imem tops out at 16 KB.
#
# -fno-builtin keeps GCC from second-guessing our memset / memcpy
# replacements in core_portme.c. Without it, -O2 can inline and
# partially-inline in ways that then still emit fallback libcalls
# back into our replacements, causing infinite recursion.
PORT_CFLAGS     = -O2 -g \
                  -march=rv32im_zicsr -mabi=ilp32 \
                  -nostdlib -nostartfiles -ffreestanding \
                  -fno-builtin -fno-pic \
                  -ffunction-sections -fdata-sections \
                  -fomit-frame-pointer \
                  -Wall

FLAGS_STR       = "$(PORT_CFLAGS) $(XCFLAGS) $(XLFLAGS) $(LFLAGS_END)"
CFLAGS          = $(PORT_CFLAGS) -I$(PORT_DIR) -I. -DFLAGS_STR=\"$(FLAGS_STR)\"

# Linker: our linker script fixes the .text/.rodata at IMEM and
# .bss/stack at SRAM (see linker.ld comments). --gc-sections
# drops unreachable code; -static is redundant under
# -nostdlib -nostartfiles but documents intent.
# $(LD) is gcc (not binutils ld), so -nostdlib / -nostartfiles must
# appear on the link line too — without them gcc auto-links newlib's
# crt0.o + libc + libg, which either drag in soft-float libcalls
# (__ltdf2 etc. from float-enabled libgcc) or fight our own _start.
# Dumping them explicitly on the link command keeps us pure-freestanding.
LFLAGS          = -T $(PORT_DIR)/linker.ld -Wl,--gc-sections \
                  -nostdlib -nostartfiles -ffreestanding -static
LFLAGS_END      =
XCFLAGS        ?=
XLFLAGS        ?=

# Separate compile → link, matching upstream barebones.
SEPARATE_COMPILE = 1
OBJOUT          = -o
COUT            = -c
OFLAG           = -o
OUTFLAG         = -o
OEXT            = .o
EXE             = .elf

# Source files for this port.
#
#   core_portme.c  — timing + UART + portable_{init,fini} + libc shims
#   ee_printf.c    — portable printf (copy of barebones, uart_send_char
#                    stub removed — we define ours in core_portme.c)
#   start.S        — crt0 (reset vector, bss zero, .data copy, call main)
PORT_SRCS       = $(PORT_DIR)/core_portme.c \
                  $(PORT_DIR)/ee_printf.c \
                  $(PORT_DIR)/start.S

# Object files that go into OBJS alongside the core_*.o files.
# $(OEXT) = .o. Upstream's OBJS rule prefixes these with OPATH so
# they land in $(OPATH)$(PORT_DIR)/ — mkdir target $(OPATH)$(PORT_DIR)
# in upstream Makefile creates that dir.
PORT_OBJS       = $(PORT_DIR)/core_portme$(OEXT) \
                  $(PORT_DIR)/ee_printf$(OEXT) \
                  $(PORT_DIR)/start$(OEXT)

vpath %.c $(PORT_DIR)
vpath %.S $(PORT_DIR)

# Compile patterns. Upstream's barebones covers only %.c; we need
# to add %.S for start.S. gcc handles .S preprocessing automatically.
$(OPATH)$(PORT_DIR)/%$(OEXT) : %.c
	$(CC) $(CFLAGS) $(XCFLAGS) $(COUT) $< $(OBJOUT) $@

$(OPATH)%$(OEXT) : %.c
	$(CC) $(CFLAGS) $(XCFLAGS) $(COUT) $< $(OBJOUT) $@

$(OPATH)$(PORT_DIR)/%$(OEXT) : %.S
	$(CC) $(CFLAGS) $(XCFLAGS) $(COUT) $< $(OBJOUT) $@

# Upstream invokes `load` + `run` targets for self-hosted runs; we
# don't self-host (the ELF is baked into the Quartus bitstream via
# CM-3's Top.hs edit). Stub these out so `make link` is the single
# target pkgs/coremark/package.nix uses.
LOAD            = echo "CoreMark ELF is loaded by baking into the Quartus bitstream — see CM-3."
RUN             = echo "CoreMark runs on DE2 silicon — flash and open nios2-terminal. See CM-4."

OPATH           = ./
MKDIR           = mkdir -p

# Upstream expects port_pre/post hooks to exist; no-op them.
.PHONY: port_prebuild port_postbuild port_prerun port_postrun port_preload port_postload
port_pre% port_post% :
