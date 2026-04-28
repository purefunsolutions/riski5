# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# Build the @riski5-boot-rom-gen@ host-tool — the Copilot-eDSL
# generator (tools/boot-rom/Main.hs). Mirrors riski5-load-stream's
# pattern: standalone GHC compile against a custom ghcWithPackages
# bundle, no Cabal-in-Nix to avoid pulling the whole Clash build.
{
  stdenv,
  ghc,
}:
stdenv.mkDerivation {
  pname = "riski5-boot-rom-gen";
  version = "0.1.0";

  src = ../../tools/boot-rom;

  nativeBuildInputs = [ghc];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    ghc -O2 \
      -Wall \
      -odir . -hidir . \
      -o riski5-boot-rom-gen \
      Main.hs
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m 0755 riski5-boot-rom-gen $out/bin/
    runHook postInstall
  '';

  meta = {
    description = "Copilot-eDSL → C generator for the riski5 boot ROM";
    license = ["MIT" "BSD-3-Clause"];
    platforms = ["x86_64-linux"];
  };
}
