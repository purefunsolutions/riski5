# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# Build the rv32 nommu Linux kernel for riski5. Source comes from
# nixpkgs's pinned `linux_6_18` (matches the user's preference for
# 6.18 from the L-* planning Q&A). We layer three configs:
#
#   1. arch/riscv/configs/nommu_virt_defconfig — base nommu profile
#      that already turns on most of what we need.
#   2. arch/riscv/configs/32-bit.config         — switches to RV32.
#   3. ./riski5-overlay.config                  — riski5-specific
#      bits: bootargs, JTAG-UART driver, size cuts.
#
# Output: $out/Image (raw kernel binary, ready to load into SDRAM
# via the L-3b loader), $out/vmlinux (ELF, for Spike/sim debug),
# and $out/config (the merged config we actually built with).
#
# The build is __slow__ (~5 min on a beefy host, longer in our
# CI). The Nix derivation caches it across rebuilds. Trigger
# manually with `nix build .#linux-rv32-nommu`; the L-9 silicon
# bring-up flake output will depend on it.
{
  stdenv,
  lib,
  linux_6_18,
  linux_6_12,
  linux_6_6,
  # Pick which upstream kernel to base the build on. Default 6.18
  # (current stable). Override with "6.12" or "6.6" (LTS) for
  # bisecting suspected scheduler / nommu bugs without rebuilding
  # the whole pipeline.
  kernelChoice ? "6.18",
  pkgsCross,
  bc,
  bison,
  flex,
  cpio,
  perl,
  openssl,
  pahole,
  elfutils,
  # Optional cpio path to embed as the initramfs. When non-null,
  # the kernel build sets CONFIG_INITRAMFS_SOURCE = <path>; when
  # null, the kernel boots without an initramfs (useful for early
  # bring-up — boot panics on rdinit=/init failure but the panic
  # message itself proves Linux ran).
  initramfs ? null,
}: let
  ccPkg = pkgsCross.riscv64.buildPackages.gcc;
  cc = "${ccPkg}/bin/riscv64-unknown-linux-gnu-";
  upstream =
    if kernelChoice == "6.12" then linux_6_12
    else if kernelChoice == "6.6" then linux_6_6
    else linux_6_18;
in
  stdenv.mkDerivation {
    pname = "riski5-linux-rv32-nommu";
    inherit (upstream) version src;

    nativeBuildInputs = [
      ccPkg
      bc
      bison
      flex
      cpio
      perl
      openssl
      pahole
      elfutils
    ];

    # Kernel objects fail this; the kernel emits BFD-format ELFs
    # that nixpkgs's elf-fixup mishandles.
    dontStrip = true;
    dontFixup = true;
    dontPatchELF = true;

    KBUILD_BUILD_VERSION = "1-riski5";
    KBUILD_BUILD_TIMESTAMP = "Thu Jan  1 00:00:00 UTC 1970";

    configurePhase = ''
      runHook preConfigure

      # Step 1 + 2: nommu_virt + 32-bit.
      make ARCH=riscv CROSS_COMPILE=${cc} \
        nommu_virt_defconfig 32-bit.config

      # Step 3: riski5 overlay. Append to .config and rerun
      # olddefconfig so dependent symbols settle.
      cat ${./riski5-overlay.config} >> .config

      ${lib.optionalString (initramfs != null) ''
        # Embed the supplied cpio.gz at link time.
        sed -i 's|^CONFIG_INITRAMFS_SOURCE=.*|CONFIG_INITRAMFS_SOURCE="${initramfs}/initramfs.cpio"|' .config
      ''}

      make ARCH=riscv CROSS_COMPILE=${cc} olddefconfig

      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      make ARCH=riscv CROSS_COMPILE=${cc} -j$NIX_BUILD_CORES Image
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp arch/riscv/boot/Image  $out/Image
      cp vmlinux                $out/vmlinux
      cp .config                $out/config
      runHook postInstall
    '';

    meta = with lib; {
      description = "rv32 nommu Linux kernel for riski5 (Altera DE2)";
      license = licenses.gpl2Only;
      platforms = ["x86_64-linux"];
    };
  }
