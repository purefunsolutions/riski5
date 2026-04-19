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
  in {
    _module.args.pkgs = pkgs;

    packages = {
      riski5-core = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
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
