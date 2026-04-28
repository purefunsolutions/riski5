# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# Build a minimal cpio.gz initramfs for the riski5 nommu Linux:
#
#   /init             — BFLT hello-world from L-7
#   /proc, /sys, /dev — empty mount-point dirs
#
# Linux's `usr/gen_init_cpio` is the canonical builder, but we can
# achieve the same shape with `cpio -o -H newc` driven from a
# scripted layout (no `gen_init_cpio` config-file syntax to learn).
{
  stdenv,
  lib,
  cpio,
  init-rv32-nommu,
}:
stdenv.mkDerivation {
  pname = "riski5-initramfs-rv32-nommu";
  version = "0.1.0";

  dontUnpack = true;
  nativeBuildInputs = [cpio];

  buildPhase = ''
    runHook preBuild

    # Lay out a tiny rootfs in a tmpdir.
    mkdir -p root/{proc,sys,dev}
    cp ${init-rv32-nommu}/init root/init
    chmod +x root/init

    # Build a newc cpio (Linux's preferred initramfs format).
    # We don't gzip — the kernel can ingest uncompressed cpio
    # directly via CONFIG_INITRAMFS_SOURCE, and at our size
    # (a few hundred bytes for /init plus directory entries)
    # gzip overhead exceeds the saved bytes.
    (
      cd root
      find . -mindepth 1 -print0 | LC_ALL=C sort -z \
        | cpio --null --create --format=newc --quiet
    ) > initramfs.cpio

    ls -la initramfs.cpio
    ${cpio}/bin/cpio --list < initramfs.cpio

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp initramfs.cpio $out/initramfs.cpio
    runHook postInstall
  '';

  meta = with lib; {
    description = "Minimal cpio initramfs for riski5 nommu Linux";
    license = ["MIT" "BSD-3-Clause"];
  };
}
