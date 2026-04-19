# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# Phase-1A scaffold: no derivations yet. The core, SoC, firmware, and
# flash app slot in as we progress through the T-tasks; see
# `TODO.md` for the current state.
{inputs, ...}: {
  perSystem = {system, ...}: let
    # Quartus II is unfree → allowUnfree. Clash in nixpkgs 25.11 has
    # skipped tests via alterade2-flake's overlay; we reuse the same
    # import so Clash evaluates.
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
  in {
    _module.args.pkgs = pkgs;

    packages = {};
    apps = {};
  };
}
