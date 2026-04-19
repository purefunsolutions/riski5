# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
{inputs, ...}: {
  imports = with inputs; [
    flake-root.flakeModule
    treefmt-nix.flakeModule
  ];
  perSystem = {
    config,
    pkgs,
    ...
  }: {
    treefmt.config = {
      package = pkgs.treefmt;
      inherit (config.flake-root) projectRootFile;

      programs = {
        alejandra.enable = true;
        deadnix.enable = true;
        statix.enable = true;
        shellcheck.enable = true;
        fourmolu = {
          enable = true;
          package = pkgs.haskellPackages.fourmolu;
        };
        cabal-fmt.enable = true;
      };
    };

    formatter = config.treefmt.build.wrapper;
  };
}
