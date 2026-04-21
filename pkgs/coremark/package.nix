# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# EEMBC CoreMark 1.01 cross-compiled for riski5 (RV32IM, bare-metal).
#
# CoreMark is the industry-standard embedded-CPU benchmark published
# by the Embedded Microprocessor Benchmark Consortium (EEMBC). The
# EEMBC score database at https://www.eembc.org/coremark/scores.php
# lets us compare riski5 against Cortex-M0 / PicoRV32 / VexRiscv /
# etc. on the same benchmark under identical rules.
#
# Pin: tag v1.01 (cfa9ab37…), the last release EEMBC cut before
# switching the upstream branch to the `main` head. Score comparability
# requires a fixed CoreMark source, so pin by commit not branch.
#
# --- What this derivation does ---
#
# 1. Fetches eembc/coremark@v1.01.
# 2. Drops the riski5 platform port (firmware/phase2/coremark-port/)
#    into the CoreMark tree as <portDir>. The port supplies
#    core_portme.{c,h,mak} + start.S + linker.ld; see CM-2 for the
#    port's design. Without the port present, the build fails at
#    the copy step — by design, so a missing port is a loud error
#    rather than a silently-broken artifact.
# 3. Invokes the upstream Makefile's `link` target with our port
#    directory, producing coremark.elf (renamed from the upstream
#    default coremark.exe).
# 4. Emits four artifacts in $out:
#      - coremark.elf    : the ELF that Clash's listToVecTH or a
#                          future JTAG loader consumes.
#      - coremark.bin    : `objcopy -O binary` of the same, handy
#                          for diffing against the MIF.
#      - coremark.mif    : 32-bit-word-per-line Quartus MIF that the
#                          imem M4K initial-contents path reads.
#      - coremark.dis    : full disassembly, for perf-debugging the
#                          hot loops.
#      - coremark.size   : riscv32-none-elf-size output so we can
#                          track .text / .rodata / .bss footprints
#                          across commits the way we track LEs/M4K.
#
# --- Iteration count ---
#
# EEMBC rules say a valid score must run > 10 seconds on the DUT.
# At 40 MHz and ~0.7–1.0 CoreMarks/MHz (Cortex-M0 class; measured
# number comes from CM-4), 10 s ≈ 300–500 iterations. Default is 400;
# override with `--arg iterations 800` at `nix build` time when the
# score dips and we need more wall-clock.
{
  stdenvNoCC,
  fetchFromGitHub,
  lib,
  pkgsCross,
  python3,
  gnumake,
  iterations ? 400,
  # Platform-port directory. Created in CM-2 under
  # firmware/phase2/coremark-port/. Pass a different path from
  # callPackage to test alternative ports.
  portDir ? ../../firmware/phase2/coremark-port,
}: let
  rvGcc = pkgsCross.riscv32-embedded.buildPackages.gcc;
  rvBinutils = pkgsCross.riscv32-embedded.buildPackages.binutils;
in
  stdenvNoCC.mkDerivation {
    pname = "riski5-coremark";
    version = "1.01";

    src = fetchFromGitHub {
      owner = "eembc";
      repo = "coremark";
      rev = "cfa9ab377835911f23d9b0831c7be302ed1f58de";
      hash = "sha256-Z4XJGQqEi0+f30D0l2ePJ7XEYOFB0Echd4CXcAJwTZ8=";
    };

    nativeBuildInputs = [rvGcc rvBinutils gnumake python3];

    # Drop the riski5 port alongside the upstream barebones/simple
    # ports at `riski5/` in the source tree, then point the Makefile
    # at it with PORT_DIR=riski5. CoreMark's top-level Makefile
    # includes $(PORT_DIR)/core_portme.mak, which is where our port
    # sets CC, CFLAGS, LFLAGS, and OEXT.
    postPatch = ''
      mkdir -p riski5
      cp -r ${portDir}/. riski5/
      chmod -R u+w riski5
    '';

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild
      make PORT_DIR=riski5 ITERATIONS=${toString iterations} link
      # Upstream names the final artifact coremark.exe even on
      # freestanding targets; rename to the .elf extension our
      # tooling (objcopy, flash helpers, Clash listToVecTH) expects.
      mv coremark.exe coremark.elf
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out

      cp coremark.elf $out/coremark.elf
      riscv32-none-elf-objdump -d coremark.elf > $out/coremark.dis
      riscv32-none-elf-objcopy -O binary coremark.elf $out/coremark.bin
      riscv32-none-elf-size    coremark.elf > $out/coremark.size

      python3 ${./bin-to-mif.py} $out/coremark.bin $out/coremark.mif
      runHook postInstall
    '';

    # Strip would run on the host; stdenvNoCC already avoids that,
    # but pin the intent: we want coremark.elf bit-identical to the
    # link output so disassembly line numbers stay stable across
    # debugging sessions.
    dontStrip = true;

    meta = with lib; {
      description = "EEMBC CoreMark 1.01 cross-compiled for riski5 (RV32IM, bare-metal)";
      homepage = "https://www.eembc.org/coremark/";
      # Upstream LICENSE file is Apache 2.0 with EEMBC publication
      # restrictions on reporting unmodified scores — covered by the
      # SPDX tag Apache-2.0 for source-license purposes; the reporting
      # rules are a separate legal layer we respect at CM-4.
      license = licenses.asl20;
      platforms = platforms.linux;
    };
  }
