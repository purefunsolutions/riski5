# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# Cross-compile firmware/phase2/init-rv32-nommu/init.S into a BFLT
# (Binary Flat) executable for our nommu Linux. The L-8 initramfs
# package puts this at /init in the cpio.
#
# Pipeline:
#   1. riscv64-unknown-linux-gnu-as → init.o (rv32 ELF object)
#   2. riscv64-unknown-linux-gnu-ld → init.elf (rv32 statically
#      linked at PC 0).
#   3. riscv64-unknown-linux-gnu-objcopy -O binary → init.bin
#      (raw .text + .rodata, no ELF wrapper).
#   4. build_init_bflt.py prepends a 64-byte BFLT v4 header.
#
# Output: $out/init — the BFLT-wrapped flat binary, ~200 bytes.
{
  stdenv,
  lib,
  pkgsCross,
  python3,
}: let
  ccPkg = pkgsCross.riscv64.buildPackages.gcc;
  binutils = pkgsCross.riscv64.buildPackages.binutils;
  cc = "${ccPkg}/bin/riscv64-unknown-linux-gnu-";
in
  stdenv.mkDerivation {
    pname = "riski5-init-rv32-nommu";
    version = "0.1.0";

    src = ../../firmware/phase2/init-rv32-nommu;

    nativeBuildInputs = [ccPkg binutils python3];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild

      ${cc}as -march=rv32ima -mabi=ilp32 -o init.o init.S

      ${cc}ld -m elf32lriscv \
        --build-id=none \
        -e _start \
        -Ttext=0x40 \
        -o init.elf \
        init.o

      ${cc}objcopy -O binary -j .text -j .rodata init.elf init.bin

      python3 build_init_bflt.py init.bin init

      ls -la init
      ${cc}objdump -d init.elf | head -30

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp init        $out/init
      cp init.elf    $out/init.elf
      cp init.bin    $out/init.bin
      runHook postInstall
    '';

    meta = with lib; {
      description = "BFLT /init for riski5 nommu Linux (hello-world)";
      license = ["MIT" "BSD-3-Clause"];
      platforms = ["x86_64-linux"];
    };
  }
