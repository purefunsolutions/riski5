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
        # B-* (Boot ROM via Copilot eDSL): generate C from a
        # Haskell stream specification, then cross-compile to
        # RV32 with the L-5 toolchain. See docs/boot-rom-copilot.md.
        copilot
        copilot-c99
        copilot-language
        copilot-prettyprinter
      ]);
    quartus = inputs.alterade2-flake.packages.${system}.quartus-ii-13;
    # riscv32-none-elf binutils: as, ld, objcopy, objdump, nm.
    # Used by the Layer-1.5 Spike driver path — we emit an assembly
    # stub (one .word per retired instruction) + linker script, then
    # shell out to riscv32-none-elf-as / -ld to produce an ELF
    # Spike can load. Also lets the Hello firmware emit .elf for
    # ad-hoc Spike debugging.
    rv32Binutils = pkgs.pkgsCross.riscv32-embedded.buildPackages.binutils;
    # L-5: full riscv64 cross-toolchain. Used to build the rv32 Linux
    # kernel + initramfs userspace; the kernel build invokes
    # riscv64-unknown-linux-gnu-gcc with `-march=rv32ima -mabi=ilp32`
    # to target our hart. This single toolchain covers both rv32 and
    # rv64 (rv32 is selected per-target via -march/-mabi), matching
    # the riski5cuda recipe — no separate riscv32-linux GCC needed.
    rv64LinuxGcc = pkgs.pkgsCross.riscv64.buildPackages.gcc;
    rv64LinuxBinutils = pkgs.pkgsCross.riscv64.buildPackages.binutils;
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
        rv64LinuxGcc
        rv64LinuxBinutils
      ];
      shellHook = ''
        echo "riski5 devshell — Clash 1.8.4 + Quartus 13.0sp1 + Verilator + Spike"
        echo "  cabal build all          — build library + tests"
        echo "  cabal test               — run Hedgehog property suite"
        echo "  nix build .#riski5-core  — (future) synthesize .sof for DE2"
        echo "  nix run .#flash-riski5   — (future) flash to DE2 via USB Blaster"
        echo "  nix run .#console        — (future) open nios2-terminal"
        echo ""
        echo "Linux toolchain (L-5):"
        echo "  riscv64-unknown-linux-gnu-gcc -march=rv32ima -mabi=ilp32 ..."
      '';
    };
  };
}
