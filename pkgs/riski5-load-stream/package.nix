# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# Build the @riski5-load-stream@ host-tool — a small Haskell
# program (tools/load-stream/Main.hs) that owns nios2-terminal and
# pipes a kernel + DTB into its stdin with a live progress bar.
#
# Standalone GHC compile, no Cabal — Main.hs only needs base,
# bytestring, and process, and we don't want to pull the whole
# Clash riski5 build into a tiny host utility derivation.
{
  stdenv,
  ghc,
}:
stdenv.mkDerivation {
  pname = "riski5-load-stream";
  version = "0.1.0";

  src = ../../tools/load-stream;

  nativeBuildInputs = [ghc];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    ghc -O2 \
      -Wall -Werror \
      -threaded \
      -odir . -hidir . \
      -o riski5-load-stream \
      Main.hs
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m 0755 riski5-load-stream $out/bin/
    runHook postInstall
  '';

  meta = {
    description = "Host-side JTAG-UART loader for riski5 (kernel + DTB streamer)";
    license = ["MIT" "BSD-3-Clause"];
    platforms = ["x86_64-linux"];
  };
}
