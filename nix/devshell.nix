# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
{inputs, ...}: {
  perSystem = {
    system,
    pkgs,
    ...
  }: let
    ghcWithClash = pkgs.haskellPackages.ghcWithPackages (ps:
      with ps; [
        clash-ghc
        clash-prelude
        clash-lib
      ]);
    quartus = inputs.alterade2-flake.packages.${system}.quartus-ii-13;
  in {
    devShells.default = pkgs.mkShell {
      name = "riski5-dev";
      packages = [
        quartus
        ghcWithClash
        pkgs.cabal-install
        pkgs.haskell-language-server
        pkgs.haskellPackages.fourmolu
        pkgs.haskellPackages.cabal-fmt
        pkgs.hlint
        pkgs.treefmt
        pkgs.verilator
        pkgs.gtkwave
      ];
      shellHook = ''
        echo "riski5 devshell — Clash 1.8.4 + Quartus 13.0sp1 + Verilator"
        echo "  cabal build all          — build library + tests"
        echo "  cabal test               — run Hedgehog property suite"
        echo "  nix build .#riski5-core  — (future) synthesize .sof for DE2"
        echo "  nix run .#flash-riski5   — (future) flash to DE2 via USB Blaster"
        echo "  nix run .#console        — (future) open nios2-terminal"
      '';
    };
  };
}
