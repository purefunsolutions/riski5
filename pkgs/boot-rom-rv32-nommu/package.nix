# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# Boot ROM build pipeline (B-* in docs/boot-rom-copilot.md):
#
#   1. Run riski5-boot-rom-gen — Haskell tool that emits
#      boot_rom_step.{c,h} from a Copilot eDSL spec.
#   2. Cross-compile that + start.c via the L-5 RV32 toolchain
#      (riscv64-unknown-linux-gnu-gcc -march=rv32ima -mabi=ilp32).
#   3. objcopy -O binary → flat .text blob.
#
# Output: $out/boot_rom.{elf,bin,c,h,disasm}.
#
# B-1 status: minimal placeholder spec (boot_emit_tick every
# 1000 ticks). Wire this output into the riski5-core-linux Nix
# variant once B-2..B-5 land — the existing
# firmware/phase1/LinuxBoot.hs Asm-eDSL stub stays the live
# boot ROM until the Copilot path matches its behaviour.
{
  stdenv,
  lib,
  pkgsCross,
  riski5-boot-rom-gen,
}: let
  ccPkg = pkgsCross.riscv64.buildPackages.gcc;
  binutils = pkgsCross.riscv64.buildPackages.binutils;
  cc = "${ccPkg}/bin/riscv64-unknown-linux-gnu-";
in
  stdenv.mkDerivation {
    pname = "riski5-boot-rom-rv32-nommu";
    version = "0.1.0";

    src = ../../firmware/phase2/boot-rom;

    nativeBuildInputs = [ccPkg binutils riski5-boot-rom-gen];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild

      # Step 1: Copilot codegen → boot_rom_step.{c,h,_types.h}.
      mkdir -p generated
      riski5-boot-rom-gen generated

      # Copilot's emitted C unconditionally #includes
      # <string.h>, <stdlib.h>, <math.h> — those are hosted-libc
      # headers that drag in <gnu/stubs-ilp32.h> on this
      # cross-toolchain (riscv64-unknown-linux-gnu has no rv32
      # multilib). Our boot-ROM spec doesn't use anything from
      # those headers (no memcpy / malloc / sqrt), so strip the
      # offending includes and substitute <stddef.h> (freestanding,
      # provided by GCC itself) which carries the size_t /
      # NULL macros Copilot's generated code actually uses.
      sed -i \
        -e 's|^#include <string.h>$|#include <stddef.h>|' \
        -e '/^#include <stdlib.h>$/d' \
        -e '/^#include <math.h>$/d' \
        generated/boot_rom_step.c

      echo "### Copilot-emitted boot_rom_step.h:"
      cat generated/boot_rom_step.h
      echo "### Copilot-emitted boot_rom_step.c (head, post-strip):"
      head -40 generated/boot_rom_step.c

      # Step 2: cross-compile start.c + the generated step source.
      # -nostartfiles  : we provide _start ourselves
      # -ffreestanding : no hosted libc / OS assumptions
      # -nostdlib      : no auto-link of crt/libc
      # -fno-builtin   : do not constant-fold things into memcpy etc.
      # -Os            : size-optimise (BRAM is 16 KB)
      # -mno-relax     : keep PC-relative addresses concrete (no
      #                  linker-relaxation surprises in the flat blob)
      # -no-pie + -static to avoid the toolchain's default
      # dynamic / position-independent linking (the riscv64 cross
      # is built for hosted Linux distros where shared objects are
      # the default; we want a freestanding bare-metal blob).
      ${cc}gcc \
        -march=rv32ima -mabi=ilp32 \
        -nostartfiles -nostdlib -ffreestanding -fno-builtin \
        -fno-pic -no-pie -static -Os -Wall -Wextra -mno-relax \
        -Wl,--build-id=none \
        -Igenerated \
        -T linker.ld \
        -o boot_rom.elf \
        start.c generated/boot_rom_step.c

      ${cc}objdump -d boot_rom.elf > boot_rom.disasm

      # Step 3: flat binary.
      ${cc}objcopy -O binary -j .text boot_rom.elf boot_rom.bin

      echo "### boot_rom.bin: $(stat -c %s boot_rom.bin) bytes"
      echo "### boot_rom.disasm (first 40 lines):"
      head -40 boot_rom.disasm

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp boot_rom.elf      $out/boot_rom.elf
      cp boot_rom.bin      $out/boot_rom.bin
      cp boot_rom.disasm   $out/boot_rom.disasm
      cp generated/boot_rom_step.c        $out/boot_rom_step.c
      cp generated/boot_rom_step.h        $out/boot_rom_step.h
      cp generated/boot_rom_step_types.h  $out/boot_rom_step_types.h
      runHook postInstall
    '';

    meta = with lib; {
      description = "Copilot-eDSL → C → RV32 boot ROM for riski5";
      license = ["MIT" "BSD-3-Clause"];
      platforms = ["x86_64-linux"];
    };
  }
