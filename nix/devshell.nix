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
    # riscv32-none-elf binutils: as, ld, objcopy, objdump, nm.
    # Used by the Layer-1.5 Spike driver path — we emit an assembly
    # stub (one .word per retired instruction) + linker script, then
    # shell out to riscv32-none-elf-as / -ld to produce an ELF
    # Spike can load. Also lets the Hello firmware emit .elf for
    # ad-hoc Spike debugging.
    rv32Binutils = pkgs.pkgsCross.riscv32-embedded.buildPackages.binutils;
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
        # Spike is the official RISC-V "golden" ISS from riscv-software-src.
        # Layer 1.5 of docs/verification.md uses it as the third oracle in
        # a three-way differential test — Spike ↔ Riski5.Reference ↔
        # Clash core — so a bug shared between our two implementations
        # can't hide behind their agreement.
        pkgs.spike
        # dtc is needed at Spike runtime: Spike's default boot ROM at
        # 0x1000 reads the entry address from a device-tree blob it
        # generates via dtc and places in memory. Without dtc on PATH
        # Spike refuses to start ("Failed to run dtc").
        pkgs.dtc
        rv32Binutils
      ];
      shellHook = ''
        echo "riski5 devshell — Clash 1.8.4 + Quartus 13.0sp1 + Verilator + Spike"
        echo "  cabal build all          — build library + tests"
        echo "  cabal test               — run Hedgehog property suite"
        echo "  nix build .#riski5-core  — (future) synthesize .sof for DE2"
        echo "  nix run .#flash-riski5   — (future) flash to DE2 via USB Blaster"
        echo "  nix run .#console        — (future) open nios2-terminal"
      '';
    };
  };
}
