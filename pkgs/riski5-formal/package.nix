# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# riski5-formal — Clash → riski5_formal.v → riscv-formal harness
# → SymbiYosys proofs.
#
# Pipeline:
#   1. Clash emits riski5_formal.v from src/Riski5/FormalTop.hs.
#      The Verilog exposes the core with flat RVFI ports; no SoC,
#      no peripherals.
#   2. We stage `$riscvFormal/cores/riski5/` with the generated
#      .v, our hand-written wrapper.sv, and a checks.cfg.
#   3. riscv-formal's genchecks.py reads the cfg and emits a
#      per-check sby job tree under cores/riski5/checks/.
#   4. `make -C checks -j $cores` runs SymbiYosys over each job.
#
# A failure leaves cexdata/status.txt non-empty and the
# derivation fails, dumping the SymbiYosys trace.vcd of any
# counterexample into $out for post-mortem analysis.
{
  stdenv,
  lib,
  haskellPackages,
  sby,
  yosys,
  z3,
  boolector,
  python3,
  gnumake,
  riscv-formal,
}: let
  ghcWithClash = haskellPackages.ghcWithPackages (ps:
    with ps; [
      clash-ghc
      clash-prelude
      clash-lib
      containers
      mtl
    ]);
in
  stdenv.mkDerivation {
    pname = "riski5-formal";
    version = "0.1.0";

    src = lib.cleanSourceWith {
      src = ../..;
      filter = path: _type: let
        base = baseNameOf path;
      in
        !(lib.hasPrefix "dist-newstyle" base)
        && !(lib.hasPrefix "result" base)
        && !(lib.hasPrefix ".claude" base)
        && !(lib.hasPrefix ".git" base);
    };

    nativeBuildInputs = [
      ghcWithClash
      sby
      yosys
      z3
      boolector
      python3
      gnumake
    ];

    # SymbiYosys looks for the solvers on PATH; nativeBuildInputs
    # puts them there automatically. No extra wiring needed.

    dontStrip = true;
    dontFixup = true;

    buildPhase = ''
      runHook preBuild

      export HOME=$(mktemp -d)

      # 1. Clash → riski5_formal.v.
      clash --verilog -fclash-hdlsyn Quartus \
        -XGHC2021 -XImplicitPrelude \
        -isrc \
        Riski5.FormalTop

      # 2. Stage a writable copy of the riscv-formal tree and
      #    drop our core directory into cores/riski5/. The tree
      #    comes from the `riscv-formal` package, which installs
      #    it under $out/share/riscv-formal/.
      cp -r ${riscv-formal}/share/riscv-formal riscv-formal
      chmod -R +w riscv-formal
      mkdir -p riscv-formal/cores/riski5
      cp pkgs/riski5-formal/wrapper.sv riscv-formal/cores/riski5/
      cp pkgs/riski5-formal/checks.cfg riscv-formal/cores/riski5/
      cp verilog/Riski5.FormalTop.formalTopEntity/riski5_formal.v \
         riscv-formal/cores/riski5/

      # Remember the absolute paths we'll need during install —
      # this build_dir path survives the `cd` into the check tree
      # below.
      export CORE_DIR=$PWD/riscv-formal/cores/riski5

      # 3. Generate the per-check sby job tree.
      cd "$CORE_DIR"
      python3 ../../checks/genchecks.py

      # 3b. Swap the SMT solver from boolector (genchecks.py
      # default) to z3 for the k-induction CSR-consistency
      # proofs (csrc_any_*). Boolector's bit-blaster stalls
      # on those quantifier-heavy inductive invariants; z3
      # closes them in seconds. The pure-bitvector per-
      # instruction formulas stay on boolector (2-3× faster
      # there). reg_ch0 stays on boolector too — same engine
      # + depth 10 that nerv uses — to avoid re-running z3's
      # slow path on a proof boolector closes naturally.
      # Per-check engine config isn't supported by riscv-
      # formal's checks.cfg, so we sed the generated .sby
      # files.
      for f in checks/csrc_any_*.sby; do
        test -f "$f" || continue
        sed -i 's/^smtbmc boolector$/smtbmc z3/' "$f"
      done

      # 3c. Bound liveness to a wallclock budget as a safety
      # net. The proof itself closes in ~5 seconds — the NOP
      # injected on `squashNext=True` in `Riski5.Core` means
      # squash lasts at most one cycle, so liveness holds
      # without any fairness assumption. The 120-second cap
      # is here in case a future Core.hs change accidentally
      # removes that NOP-injection and the proof has to chase
      # an unbounded counter-example.
      if [ -f checks/liveness_ch0.sby ]; then
        sed -i '/^\[options\]$/a timeout 120' checks/liveness_ch0.sby
      fi

      # 4. Run the whole check suite. `make -C checks` without a
      # specific target runs every generated .sby job — per-insn
      # proofs plus pc_fwd / pc_bwd / reg / causal / unique / ill.
      # `-k` keeps going after any failure so a single red check
      # doesn't mask the rest. The summary loop below pulls the
      # pass/fail status of every check into $out/summary.txt.
      make -C checks -j $NIX_BUILD_CORES -k || true

      # Collate pass/fail summary. `cexdata.sh` in riscv-formal
      # aggregates the per-check status.txt files — use the same
      # pattern even though we don't ship cexdata.sh, just walk
      # the checks tree ourselves.
      echo "# riski5 riscv-formal check summary" > "$CORE_DIR/summary.txt"
      for d in "$CORE_DIR"/checks/*_ch0; do
        test -d "$d" || continue
        status=$(cat "$d/status" 2>/dev/null || echo "MISSING")
        printf '%-30s %s\n' "$(basename "$d")" "$status" \
          >> "$CORE_DIR/summary.txt"
      done
      cat "$CORE_DIR/summary.txt"

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      # Copy the full checks tree into $out — sby's status
      # files, any counterexample VCDs, and the generated .sv
      # per-check jobs. Tiny on success, diagnostic on failure.
      cp -r "$CORE_DIR/checks" $out/checks
      cp "$CORE_DIR/summary.txt" $out/
      # Also the emitted RTL, for post-mortem.
      cp "$CORE_DIR/riski5_formal.v" $out/
      cp "$CORE_DIR/wrapper.sv" $out/
      cp "$CORE_DIR/checks.cfg" $out/
      runHook postInstall
    '';

    meta = with lib; {
      description = "YosysHQ/riscv-formal SymbiYosys proofs for the riski5 core";
      license = licenses.mit;
      platforms = ["x86_64-linux"];
    };
  }
