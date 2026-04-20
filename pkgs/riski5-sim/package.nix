# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# riski5-sim — Verilator-compiled whole-SoC simulation library.
#
# Takes the Clash-emitted `riski5.v` and the ip-generate-emitted
# Altera JTAG UART `riski5_jtag_uart.v` (both produced in the
# `riski5-core` synthesis flow) and links them under a
# hand-written `riski5_sim_top.v` that:
#
#   - takes `clk` / `rst_n` as plain inputs (no altpll);
#   - exposes a `UART_TX_VALID` / `UART_TX_BYTE` tap so Haskell
#     tests can observe the exact byte the Altera IP commits to
#     its TX FIFO each cycle (the thing our pure-Clash
#     `jtagUartSim` model cannot reproduce — the IP's 1-cycle
#     registered write-data semantics only surface against the
#     real IP Verilog, which is why we add Verilator into the
#     loop for this layer of verification).
#
# Output shape mirrors `verilambda/examples/blinky/package.nix`:
#   $out/lib/libVriski5_sim_top.a
#   $out/lib/libverilated.a
#   $out/include/verilambda_riski5_sim_top_shim.h
#
# The actual Haskell testbench linking against these lands as a
# second-stage cabal test-suite (see test/SocHwSim.hs + a companion
# cabal stanza — added by next commit).
{
  stdenv,
  lib,
  verilator,
  python3,
  verilambda-shim-gen,
  haskellPackages,
  clash-ghc,
  clash-prelude,
  clash-lib,
}: let
  # Clash build: emit riski5.v from our Haskell sources. Same flow
  # as pkgs/riski5-core/package.nix's first phase, reused here so
  # the sim library tracks the current core automatically.
  ghcWithClash = haskellPackages.ghcWithPackages (ps:
    with ps; [
      clash-ghc
      clash-prelude
      clash-lib
      containers
      mtl
    ]);

  # The IP catalog ships with the quartus-ii-13 derivation (see
  # alterade2-flake). We only need the JTAG UART IP in the sim
  # derivation, so the caller passes in the ip-generate-produced
  # riski5_jtag_uart.v as a build-time dependency (to avoid needing
  # Quartus in every simulation consumer).
  #
  # For the first cut we invoke ip-generate directly here, same as
  # riski5-core does. Later we may factor this into a shared
  # derivation.
  quartus-ii-13 ? null,
in
  assert lib.asserts.assertMsg
    (quartus-ii-13 != null)
    "riski5-sim needs quartus-ii-13 to invoke ip-generate for the JTAG UART IP";
  stdenv.mkDerivation {
    pname = "riski5-sim";
    version = "0.1.0";

    src = lib.cleanSourceWith {
      src = ../..;
      filter = path: _type: let
        base = baseNameOf path;
      in
        !(lib.hasPrefix "dist-newstyle" base)
        && !(lib.hasPrefix "result" base)
        && !(lib.hasPrefix ".claude" base)
        && !(lib.hasPrefix ".git" base);
    };

    nativeBuildInputs = [
      verilator
      python3
      verilambda-shim-gen
      ghcWithClash
      quartus-ii-13
    ];

    dontStrip = true;
    dontFixup = true;

    buildPhase = ''
      runHook preBuild

      export HOME=$(mktemp -d)
      export BUILD=$PWD/build
      rm -rf "$BUILD"
      mkdir -p "$BUILD/cbits" "$BUILD/verilog"

      # 1. Generate the JTAG UART IP Verilog. Same args as
      #    pkgs/riski5-core/package.nix; parameters MUST match so
      #    the sim and synthesis versions of the IP agree.
      mkdir -p altera-ip/jtag-uart
      ip-generate \
        --component-file=${quartus-ii-13}/share/altera13.0sp1/ip/altera/sopc_builder_ip/altera_avalon_jtag_uart/altera_avalon_jtag_uart_hw.tcl \
        --output-directory=altera-ip/jtag-uart \
        --output-name=riski5_jtag_uart \
        --file-set=QUARTUS_SYNTH \
        --language=VERILOG \
        --system-info=DEVICE_FAMILY=CYCLONEII \
        --system-info=DEVICE=EP2C35F672C6 \
        --component-parameter=readBufferDepth=64 \
        --component-parameter=writeBufferDepth=64

      # 2. Clash → riski5.v. Identical invocation to riski5-core.
      clash --verilog -fclash-hdlsyn Quartus \
        -XGHC2021 -XImplicitPrelude \
        -isrc -iapp -ifirmware/phase1 \
        Top

      # 3. Assemble the Verilator input tree: all Verilog files +
      #    the manifest + the sim-top wrapper.
      cp verilog/Top.topEntity/riski5.v "$BUILD/verilog/"
      cp altera-ip/jtag-uart/riski5_jtag_uart.v "$BUILD/verilog/"
      cp pkgs/riski5-sim/verilog/riski5_sim_top.v "$BUILD/verilog/"

      # Hand-written manifest describing the sim-top's ports. The
      # real Clash manifest describes `riski5`; we need one for
      # `riski5_sim_top`.
      cp pkgs/riski5-sim/clash-manifest.json "$BUILD/"

      cd "$BUILD"

      # 4. verilambda-shim-gen reads the manifest, emits the C shim.
      verilambda-shim-gen \
        --manifest clash-manifest.json \
        --out-dir cbits

      # 5. verilator compiles every .v file + the shim into a lib.
      verilator --cc --build --trace \
        -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
        -CFLAGS -fPIC \
        --top-module riski5_sim_top \
        --Mdir obj_dir \
        verilog/riski5_sim_top.v \
        verilog/riski5.v \
        verilog/riski5_jtag_uart.v \
        cbits/verilambda_riski5_sim_top_shim.cpp

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib $out/include
      cp $BUILD/obj_dir/libVriski5_sim_top.a $out/lib/
      cp $BUILD/obj_dir/libverilated.a $out/lib/
      cp $BUILD/cbits/verilambda_riski5_sim_top_shim.h $out/include/
      runHook postInstall
    '';

    meta = with lib; {
      description = "riski5 SoC Verilator simulation library (consumed by the cabal test-suite)";
      license = licenses.unfree; # inherits from quartus-ii-13
      platforms = ["x86_64-linux"];
    };
  }
