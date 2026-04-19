# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
{
  description = "riski5 — Clash RV32I soft core + SoC for the Altera DE2";

  inputs = {
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    flake-root.url = "github:srid/flake-root";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Sibling flakes during active development. Switch the URLs to the
    # GitHub refs (github:mikatammi/alterade2-flake,
    # github:purefunsolutions/verilambda) once those are stable enough
    # to pin.
    alterade2-flake = {
      url = "path:/home/mika/alterade2-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    verilambda = {
      url = "path:/home/mika/verilambda";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [
        ./pkgs
        ./nix
      ];
      systems = [
        "x86_64-linux"
      ];
    };
}
