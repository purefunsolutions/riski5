# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# riski5 flake-parts perSystem. Exposes the synthesised .sof build
# plus the flash + console helper apps.
{inputs, ...}: {
  perSystem = {
    self',
    system,
    ...
  }: let
    # Reuse alterade2-flake's nixpkgs overlay / Clash overrides so
    # our Haskell + Quartus toolchains are identical to the sibling
    # repo. In particular this inherits the allowUnfree / allowBroken
    # flags and the dontCheck overrides for clash-lib / clash-ghc /
    # clash-prelude.
    pkgs = import inputs.nixpkgs {
      inherit system;
      config = {
        allowUnfree = true;
        allowBroken = true;
      };
      overlays = [
        (_final: prev: {
          haskellPackages = prev.haskellPackages.override {
            overrides = _hself: hsuper: {
              clash-lib = prev.haskell.lib.dontCheck hsuper.clash-lib;
              clash-ghc = prev.haskell.lib.dontCheck hsuper.clash-ghc;
              clash-prelude = prev.haskell.lib.dontCheck hsuper.clash-prelude;
            };
          };
        })
      ];
    };

    inherit (inputs.alterade2-flake.packages.${system}) quartus-ii-13;
    inherit (inputs.verilambda.packages.${system}) verilambda-shim-gen;

    # YosysHQ/riscv-formal pinned as a Nix package. Tree lives
    # under $out/share/riscv-formal/ — see pkgs/riscv-formal/package.nix.
    riscv-formal = pkgs.callPackage ./riscv-formal/package.nix {};
  in {
    _module.args.pkgs = pkgs;

    packages = {
      riski5-core = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
      };

      # Verilator-compiled whole-SoC simulation library (Layer 1.75
      # of docs/verification.md). Consumed by the riski5-hwsim-check
      # derivation and, for local dev, by `cabal test --flag=hwsim`
      # with RISKI5_SIM_LIB_DIR=$(readlink -f result)/lib.
      riski5-sim = pkgs.callPackage ./riski5-sim/package.nix {
        inherit quartus-ii-13 verilambda-shim-gen;
      };

      # YosysHQ/riscv-formal harness — expose the pinned package
      # so consumers can point at it with `.#riscv-formal` too.
      inherit riscv-formal;

      # Layer 2 of docs/verification.md: SymbiYosys proofs of the
      # Clash-emitted riski5_formal.v against the RVFI spec's
      # per-instruction contracts.
      riski5-formal = pkgs.callPackage ./riski5-formal/package.nix {
        inherit riscv-formal;
      };

      # EEMBC CoreMark 1.01 cross-compiled for the riski5 silicon
      # target. Produces $out/coremark.{elf,bin,mif,dis,size} — the
      # MIF is the artefact a future riski5-core-coremark bitstream
      # variant (CM-4) loads into the imem M4K block. Kept as its
      # own flake output so `nix build .#coremark` is a standalone
      # check that the cross toolchain + platform port still build.
      coremark = pkgs.callPackage ./coremark/package.nix {};

      # CoreMark-baked bitstream (CM-4). Reuses the same
      # pkgs/riski5-core/package.nix machinery as the MemTest
      # default; the only difference is that @coremarkPkg@ here
      # makes the build overlay firmware/phase1/CoreMark.hs with
      # the real CoreMark bytes from the 'coremark' output above
      # and pass -DFIRMWARE_COREMARK to Clash.
      riski5-core-coremark = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        coremarkPkg = self'.packages.coremark;
      };

      # Debug bitstream that bakes firmware/phase1/HelloSramExec.hs
      # into the imem. Probes whether the core can execute
      # instructions fetched from SRAM — the current SoC hardwires
      # @imemDataS@ to BRAM with @pcFetch `mod` ProgSize@, so the
      # expected on-silicon behaviour is an infinite 'B' stream
      # (fetch at 0x2000_0000 wraps to BRAM[0] = firmware restart).
      # If the fetch path ever grows an SRAM route, this bitstream
      # is the regression probe.
      riski5-core-sramexec = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        sramExec = true;
      };

      flash-riski5 = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        inherit (self'.packages) riski5-core;
      };

      # CoreMark-variant flasher. Same shell script as
      # flash-riski5, but points at Riski5.sof inside the
      # riski5-core-coremark output so `nix run .#flash-riski5-coremark`
      # always grabs the CoreMark-baked bitstream.
      flash-riski5-coremark = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-coremark;
      };

      # Flasher for the SRAM-execution debug bitstream.
      flash-riski5-sramexec = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-sramexec;
      };

      console = pkgs.callPackage ../apps/console.nix {
        inherit quartus-ii-13;
      };

      default = self'.packages.riski5-core;
    };

    apps = {
      flash-riski5 = {
        type = "app";
        program = "${self'.packages.flash-riski5}/bin/flash-riski5";
      };
      flash-riski5-coremark = {
        type = "app";
        program = "${self'.packages.flash-riski5-coremark}/bin/flash-riski5";
      };
      flash-riski5-sramexec = {
        type = "app";
        program = "${self'.packages.flash-riski5-sramexec}/bin/flash-riski5";
      };
      console = {
        type = "app";
        program = "${self'.packages.console}/bin/console";
      };
    };
  };
}
