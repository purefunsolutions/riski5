# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# Compile firmware/phase2/dts/riski5.dts → riski5.dtb via `dtc`.
# The DTB is consumed by the Linux kernel build (L-6) which embeds
# it into the kernel image, and by future bootloaders that pass it
# via a1 to the kernel entry.
#
# `dtc` is in nixpkgs as `dtc` (the Device Tree Compiler from the
# Linux kernel tree). We invoke it with `-O dtb -I dts` to convert
# the source to the binary blob.
{
  stdenv,
  dtc,
}:
stdenv.mkDerivation {
  pname = "riski5-dtb";
  version = "0.1.0";

  src = ../../firmware/phase2/dts;

  nativeBuildInputs = [dtc];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    dtc -O dtb -I dts -o riski5.dtb riski5.dts
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp riski5.dtb $out/
    cp riski5.dts $out/
    runHook postInstall
  '';

  meta = {
    description = "Compiled device tree (DTB) for the riski5 SoC on Altera DE2";
    license = ["MIT" "BSD-3-Clause"];
  };
}
