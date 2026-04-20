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

      flash-riski5 = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        inherit (self'.packages) riski5-core;
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
      console = {
        type = "app";
        program = "${self'.packages.console}/bin/console";
      };
    };
  };
}
