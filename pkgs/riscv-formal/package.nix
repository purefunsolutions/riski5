# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# YosysHQ/riscv-formal — the formal-verification framework for
# RISC-V cores. Consumed by `pkgs/riski5-formal/package.nix`,
# which stages $out/share/riscv-formal into a writable build dir,
# drops cores/riski5/ into it, then runs SymbiYosys via
# checks/genchecks.py + make.
#
# Not a real "build" — the upstream tree is Python + Verilog +
# SVA source, no compiled artefacts. This derivation just pins
# a commit and copies the tree into $out/share/riscv-formal with
# a conventional layout so multiple downstream consumers can
# share the same store path.
#
# Pin rationale (see docs/verification.md §Layer 2): the
# upstream README explicitly labels the interfaces "work in
# progress. The interfaces described here are likely to change"
# — there are no release tags to follow. We pin by commit
# hash and rebase periodically.
{
  stdenv,
  fetchFromGitHub,
  lib,
  python3,
}:
stdenv.mkDerivation {
  pname = "riscv-formal";
  version = "unstable-2026-03-19";

  src = fetchFromGitHub {
    owner = "YosysHQ";
    repo = "riscv-formal";
    rev = "2aa7b4934190baeb2ef62b2de414f104b489d3cc";
    hash = "sha256-LpkuVlVDknzO0xk8hXVYVmvHeAy8UMMfT3bSjQY5Lg8=";
  };

  # `checks/genchecks.py` is the only Python we invoke — make
  # sure it's on the shebang path of every consumer that picks
  # this derivation up via `nativeBuildInputs`.
  propagatedBuildInputs = [python3];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/riscv-formal
    cp -r . $out/share/riscv-formal/
    runHook postInstall
  '';

  meta = with lib; {
    description = "YosysHQ RISC-V Formal Verification Framework (RVFI + SymbiYosys checks)";
    homepage = "https://github.com/YosysHQ/riscv-formal";
    # Upstream LICENSE header: ISC.
    license = licenses.isc;
    platforms = platforms.unix;
  };
}
