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
  # The IP catalog ships with the quartus-ii-13 derivation (see
  # alterade2-flake). We only need the JTAG UART IP in the sim
  # derivation, so the caller passes in the ip-generate-produced
  # riski5_jtag_uart.v as a build-time dependency (to avoid needing
  # Quartus in every simulation consumer).
  #
  # For the first cut we invoke ip-generate directly here, same as
  # riski5-core does. Later we may factor this into a shared
  # derivation.
  quartus-ii-13,
  # Firmware variant baked into BRAM. "linuxBootSim" (the default)
  # bakes the JTAG-Avalon-Master Linux boot stub + enables SDRAM
  # fetch — what tools/linux-hwsim expects. "sdramHighStress"
  # bakes the BRAM-resident high-SDRAM stress probe (#64 follow-up)
  # with the default BRAM-only fetch policy — drives a self-contained
  # write/readback test that emits "PASS2" on completion.
  firmware ? "linuxBootSim",
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
  isLinuxBootSim = firmware == "linuxBootSim";
  isSdramHighStress = firmware == "sdramHighStress";
  isMdStress = firmware == "mdStress";
in
  stdenv.mkDerivation {
    pname =
      if isSdramHighStress
      then "riski5-sim-sdramhighstress"
      else if isMdStress
      then "riski5-sim-mdstress"
      else "riski5-sim";
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

    # ghcWithClash FIRST: it provides `clash` + its plugin packages
    # (ghc-typelits-knownnat, -natnormalise, -extra) via
    # ghcWithPackages. verilambda-shim-gen is also a Haskell exe;
    # if it lands in front of ghcWithClash its package DB shadows
    # ours and Clash fails with
    # `Could not find module GHC.TypeLits.KnownNat.Solver`.
    nativeBuildInputs = [
      ghcWithClash
      verilator
      python3
      verilambda-shim-gen
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

      # Firmware overlay: pick which Hello* module CoreMark.hs
      # re-exports based on the @firmware@ Nix arg. This is the
      # same trick pkgs/riski5-core/package.nix uses for silicon
      # variants — the unchanged @-DFIRMWARE_COREMARK@ CPP path in
      # app/Top.hs picks up CoreMark.coreMarkFirmwareWords which
      # we alias to whichever real firmware module we want baked
      # into BRAM.
      chmod -R u+w firmware/phase1

      ${lib.optionalString isLinuxBootSim ''
        cat > firmware/phase1/CoreMark.hs <<'EOF'
        -- SPDX-FileCopyrightText: 2026 Mika Tammi
        -- SPDX-License-Identifier: MIT OR BSD-3-Clause
        --
        -- Overlaid by the riski5-sim (firmware="linuxBootSim")
        -- Nix build: re-exports LinuxBootSim's firmware under
        -- CoreMark so the unchanged -DFIRMWARE_COREMARK path in
        -- app/Top.hs bakes the Linux boot stub into BRAM. The
        -- stub polls @SDRAM[0x807FFFF4]@ for a "go" sentinel,
        -- then JALRs to @0x80000000@. The sim harness pre-loads
        -- kernel + DTB into SDRAM and writes the sentinel.
        {-# LANGUAGE DataKinds #-}
        {-# LANGUAGE NoStarIsType #-}

        module CoreMark (
          coreMarkFirmwareWords,
        ) where

        import Clash.Prelude (BitVector)
        import LinuxBootSim (linuxBootSimFirmwareWords)

        coreMarkFirmwareWords :: [BitVector 32]
        coreMarkFirmwareWords = linuxBootSimFirmwareWords
        EOF
        sed -i 's/^        //' firmware/phase1/CoreMark.hs

        # Linux variant: turn on SDRAM fetch routing so the kernel
        # can execute from 0x80000000+.
        cat > firmware/phase1/FetchPolicy.hs <<'EOF'
        -- SPDX-FileCopyrightText: 2026 Mika Tammi
        -- SPDX-License-Identifier: MIT OR BSD-3-Clause
        module FetchPolicy (
          enableSramFetch,
          enableSdramFetch,
        ) where

        import Prelude (Bool (..))

        enableSramFetch :: Bool
        enableSramFetch = False

        enableSdramFetch :: Bool
        enableSdramFetch = True
        EOF
        sed -i 's/^        //' firmware/phase1/FetchPolicy.hs
      ''}

      ${lib.optionalString isSdramHighStress ''
        cat > firmware/phase1/CoreMark.hs <<'EOF'
        -- SPDX-FileCopyrightText: 2026 Mika Tammi
        -- SPDX-License-Identifier: MIT OR BSD-3-Clause
        --
        -- Overlaid by the riski5-sim (firmware="sdramHighStress")
        -- Nix build: re-exports HelloSdramHighStress's firmware
        -- under CoreMark so the unchanged -DFIRMWARE_COREMARK path
        -- in app/Top.hs bakes the BRAM-resident high-SDRAM stress
        -- probe into BRAM. The probe writes addr^0xDEADBEEF into
        -- the upper 2 MB of SDRAM, reads back, then re-reads after
        -- a delay; emits "PASS2" on success.
        {-# LANGUAGE DataKinds #-}
        {-# LANGUAGE NoStarIsType #-}

        module CoreMark (
          coreMarkFirmwareWords,
        ) where

        import Clash.Prelude (BitVector)
        import HelloSdramHighStress (helloSdramHighStressFirmwareWords)

        coreMarkFirmwareWords :: [BitVector 32]
        coreMarkFirmwareWords = helloSdramHighStressFirmwareWords
        EOF
        sed -i 's/^        //' firmware/phase1/CoreMark.hs
        # FetchPolicy stays at the BRAM-only default — this firmware
        # is data-path-only, no SDRAM fetch involved.
      ''}

      ${lib.optionalString isMdStress ''
        cat > firmware/phase1/CoreMark.hs <<'EOF'
        -- SPDX-FileCopyrightText: 2026 Mika Tammi
        -- SPDX-License-Identifier: MIT OR BSD-3-Clause
        --
        -- Overlaid by the riski5-sim (firmware="mdStress") Nix
        -- build: re-exports HelloMdStress's firmware under
        -- CoreMark so the unchanged -DFIRMWARE_COREMARK path in
        -- app/Top.hs bakes the M-extension byte-level stress
        -- probe into BRAM. The probe runs `BMUHDSR.MUHDSR.…` in
        -- a tight loop using known operands. Used to discriminate
        -- whether the silicon-only "10th MUL produces wrong value"
        -- bug (#58/#60) reproduces against the Clash-emitted RTL
        -- in Verilator (= RTL bug) or only against Quartus-
        -- synthesised silicon (= synthesis edge case).
        {-# LANGUAGE DataKinds #-}
        {-# LANGUAGE NoStarIsType #-}

        module CoreMark (
          coreMarkFirmwareWords,
        ) where

        import Clash.Prelude (BitVector)
        import HelloMdStress (helloMdStressFirmwareWords)

        coreMarkFirmwareWords :: [BitVector 32]
        coreMarkFirmwareWords = helloMdStressFirmwareWords
        EOF
        sed -i 's/^        //' firmware/phase1/CoreMark.hs
        # FetchPolicy stays at the BRAM-only default — M-FU lives
        # in the core, no SDRAM/SRAM involvement.
      ''}

      echo "### riski5-sim (${firmware}): overlaid firmware/phase1/CoreMark.hs"
      cat firmware/phase1/CoreMark.hs
      if [[ -f firmware/phase1/FetchPolicy.hs ]]; then
        echo "### riski5-sim (${firmware}): FetchPolicy.hs"
        cat firmware/phase1/FetchPolicy.hs
      fi

      # 1. Clash → riski5.v. Same invocation as riski5-core but
      #    with -DFIRMWARE_COREMARK so the overlaid CoreMark.hs
      #    feeds LinuxBootMaster's firmware into Top.hs's BRAM
      #    initialiser instead of MemTest.
      #    IMPORTANT: must run BEFORE ip-generate. The Altera
      #    ip-generate launches a Perl subprocess through the
      #    bubblewrap-wrapped quartus-ii-13 FHS env, which leaks
      #    stale GHC_PACKAGE_PATH / PERL5LIB / similar search-path
      #    variables into the outer shell (an Altera FHS script
      #    quirk; same behaviour is visible with a non-Nix Quartus
      #    install as well). Running clash first avoids GHC ever
      #    seeing the polluted environment.
      clash --verilog -fclash-hdlsyn Quartus \
        -XGHC2021 -XImplicitPrelude -DFIRMWARE_COREMARK \
        -DSOC_CLOCK_HZ=40000000 \
        -DSOC_SDRAM_CLOCK_HZ=40000000 \
        -DSOC_SDRAM_PERIOD_PS=25000 \
        ${lib.optionalString (!isMdStress) "-DSILICON_MULCOMB_ONLY"} \
        -isrc -iapp -ifirmware/phase1 \
        Top

      # 2. Generate the JTAG UART IP Verilog. Same args as
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
      #
      # UNOPTFLAT fires because the Clash-emitted core has a
      # combinational path from uart_wdata/uart_be (derived from
      # the decoded store-instruction) back through the bus mux
      # — Verilator's strict circular-comb detector flags this
      # even though in practice the path is sequentially broken
      # by PC+reg registers. Pipelining the core (phase 2+) will
      # eliminate the warning naturally.
      #
      # We no longer need `--language 1364-2005` because the
      # SystemVerilog-reserved-keyword collisions that appeared
      # in Clash's first emitted Verilog (a `byte` signal from
      # Riski5.Lcd + Riski5.Core) have been renamed at source
      # — see the Haskell-side comments in both modules.
      # Performance flags:
      #   --O3            : Verilator's own optimisation pass — aggressive
      #                     function inlining + branch combining inside the
      #                     generated C++. Pure throughput win.
      #   -CFLAGS -O3 -fPIC -march=tigerlake -mtune=tigerlake :
      #                     C++ compiler optimisation pinned to the
      #                     dev workstation's CPU (Intel Core i5-1135G7,
      #                     Tiger Lake — family 6 / model 140 = 0x8C —
      #                     with AVX-512, AVX-VNNI, etc.). Pinning to a
      #                     concrete -march keeps the build reproducible
      #                     across machines (vs -march=native, which
      #                     varies by host) while still letting GCC emit
      #                     the wider Tiger Lake ISA. -fPIC stays for
      #                     the static lib's relocatability.
      # NOT enabled:
      #   --threads N     : multi-threaded sim. Tested at --threads 8 —
      #                     it made the riski5 SoC 3.7× SLOWER (0.59 MHz
      #                     → 0.16 MHz at 50 M cycles). Verilator's
      #                     per-eval thread-barrier sync dominates for
      #                     designs with <10 K combinational gates, and
      #                     ours is well below that threshold. Stay
      #                     single-threaded.
      # --trace stays on because the C++ shim references VerilatedVcd
      # symbols unconditionally (verilambda_riski5_sim_top_trace_open
      # / _close / _dump). Removing --trace would break the shim.
      # Per-eval() overhead is negligible when the harness never calls
      # dump(), so this is a small price for keeping the shim portable.
      verilator --cc --build --trace --O3 \
        -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
        --converge-limit 100 \
        -CFLAGS '-O3 -fPIC -march=tigerlake -mtune=tigerlake' \
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
