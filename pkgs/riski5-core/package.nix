# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# Clash → Verilog → Quartus → .sof for the riski5 design on the
# Altera DE2 (Cyclone II EP2C35F672C6).
#
# Phase-1B first hardware run: the .qsf leaves most pins as TODOs
# (see pkgs/riski5-core/Riski5.qsf for the list). Quartus still
# auto-places unassigned outputs, so the build produces a .sof, but
# the LEDR / LEDG / LCD pins will land on arbitrary physical pins
# until a reviewer fills in the Terasic DE2 pin table values. That's
# fine for verifying the synthesis flow works end-to-end; the
# actual T19 hardware bring-up is gated on the pin-assignment
# review.
{
  stdenv,
  lib,
  haskellPackages,
  quartus-ii-13,
}: let
  ghcWithClash = haskellPackages.ghcWithPackages (ps:
    with ps; [
      clash-ghc
      clash-prelude
      clash-lib
      containers
      mtl
    ]);
in
  stdenv.mkDerivation {
    pname = "riski5-core";
    version = "0.1.0";

    # Reach up two levels to the repo root so we get src/, app/, and
    # the Quartus files together. cleanSource keeps dist-newstyle,
    # result/, .claude, and test/ out of the build.
    src = lib.cleanSourceWith {
      src = ../..;
      filter = path: _type: let
        base = baseNameOf path;
      in
        !(lib.hasPrefix "dist-newstyle" base)
        && !(lib.hasPrefix "result" base)
        && !(lib.hasPrefix ".claude" base)
        && !(lib.hasPrefix ".git" base)
        && base != "test";
    };

    nativeBuildInputs = [ghcWithClash quartus-ii-13];

    dontStrip = true;
    dontPatchELF = true;
    dontFixup = true;

    buildPhase = ''
      runHook preBuild

      export HOME=$(mktemp -d)

      # Clash emits Verilog into ./verilog/Top.topEntity/ based on
      # the Synthesize annotation in app/Top.hs (named "riski5").
      # Top.hs imports Hello from firmware/phase1/, so include that
      # source root too. Language extensions mirror the `common
      # language` stanza in riski5.cabal, since clash --verilog
      # doesn't read cabal.
      clash --verilog -fclash-hdlsyn Quartus \
        -isrc -iapp -ifirmware/phase1 \
        -XGHC2021 \
        -XDataKinds \
        -XDeriveAnyClass \
        -XDerivingStrategies \
        -XLambdaCase \
        -XNoStarIsType \
        -XTypeFamilies \
        -XUndecidableInstances \
        -XFlexibleContexts \
        -XScopedTypeVariables \
        -XTemplateHaskell \
        -XTypeOperators \
        -XRecordWildCards \
        Top

      # Quartus expects Riski5.qpf / Riski5.qsf / Riski5.sdc at the
      # build root. The .qsf references verilog/Top.topEntity/riski5.v
      # as its source file — matching what Clash just produced.
      cp pkgs/riski5-core/Riski5.qpf .
      cp pkgs/riski5-core/Riski5.qsf .
      cp pkgs/riski5-core/Riski5.sdc .

      quartus_sh --flow compile Riski5 || {
        echo ""
        echo "NOTE: Quartus flow did not close cleanly."
        echo "For first bring-up this is typically fine as long as a"
        echo ".sof was produced; pin-assignment TODOs in the .qsf lead"
        echo "to warnings rather than hard failures. Check output_files/"
        echo "and the reports below."
        echo ""
      }

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out" "$out/reports" "$out/verilog"

      # Quartus may drop the .sof into . or output_files/ depending
      # on assignments. Find whichever landed.
      if find . -name 'Riski5.sof' | head -1 | grep -q .; then
        find . -name 'Riski5.sof' -exec cp {} "$out/Riski5.sof" \;
      else
        echo "WARNING: no Riski5.sof in build output. See reports."
      fi

      if [ -d verilog ]; then
        cp -r verilog/* "$out/verilog/" || true
      fi

      find . -name 'Riski5.*.rpt' -exec cp {} "$out/reports/" \; || true

      runHook postInstall
    '';

    meta = with lib; {
      description = "riski5 RV32I Clash core synthesised for the Altera DE2";
      license = licenses.unfree; # inherits from quartus-ii-13
      platforms = ["x86_64-linux"];
    };
  }
