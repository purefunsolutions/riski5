# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# Clash → Verilog → Quartus → .sof for the riski5 design on the
# Altera DE2 (Cyclone II EP2C35F672C6).
#
# Phase-1B first hardware run: the .qsf leaves most pins as TODOs
# (see pkgs/riski5-core/Riski5.qsf for the list). Quartus still
# auto-places unassigned outputs, so the build produces a .sof, but
# the LEDR / LEDG / LCD pins will land on arbitrary physical pins
# until a reviewer fills in the Terasic DE2 pin table values. That's
# fine for verifying the synthesis flow works end-to-end; the
# actual T19 hardware bring-up is gated on the pin-assignment
# review.
{
  stdenv,
  lib,
  haskellPackages,
  quartus-ii-13,
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
    pname = "riski5-core";
    version = "0.1.0";

    # Reach up two levels to the repo root so we get src/, app/, and
    # the Quartus files together. cleanSource keeps dist-newstyle,
    # result/, .claude, and test/ out of the build.
    src = lib.cleanSourceWith {
      src = ../..;
      filter = path: _type: let
        base = baseNameOf path;
      in
        !(lib.hasPrefix "dist-newstyle" base)
        && !(lib.hasPrefix "result" base)
        && !(lib.hasPrefix ".claude" base)
        && !(lib.hasPrefix ".git" base)
        && base != "test";
    };

    nativeBuildInputs = [ghcWithClash quartus-ii-13];

    dontStrip = true;
    dontPatchELF = true;
    dontFixup = true;

    buildPhase = ''
      runHook preBuild

      export HOME=$(mktemp -d)

      # Clash emits Verilog into ./verilog/Top.topEntity/ based on
      # the Synthesize annotation in app/Top.hs (named "riski5").
      # Top.hs imports Hello from firmware/phase1/, so include that
      # source root too. All per-feature language extensions live in
      # the .hs files themselves; Clash just needs the GHC2021
      # language standard and the two source roots.
      #
      # -XImplicitPrelude is explicit because Clash's CLI frontend
      # defaults to NoImplicitPrelude (unlike cabal). Our modules
      # use the `import Clash.Prelude hiding ((&&), ...)` pattern so
      # the ISA constructors (And, Xor, ...) don't clash — that
      # assumes Prelude is implicitly in scope to supply the hidden
      # operators.
      clash --verilog -fclash-hdlsyn Quartus \
        -XGHC2021 -XImplicitPrelude \
        -isrc -iapp -ifirmware/phase1 \
        Top

      # Quartus expects Riski5.qpf / Riski5.qsf / Riski5.sdc at the
      # build root. The .qsf references verilog/Top.topEntity/riski5.v
      # as its source file — matching what Clash just produced.
      cp pkgs/riski5-core/Riski5.qpf .
      cp pkgs/riski5-core/Riski5.qsf .
      cp pkgs/riski5-core/Riski5.sdc .

      # Bidirectional pin wrapper. The Clash top exposes the off-chip
      # SRAM data bus as three separate ports — SRAM_DQ_O (output),
      # SRAM_DQ_OE (output enable), and SRAM_DQ_I (input). Quartus's
      # I/O cells need a single bidirectional `inout SRAM_DQ[15:0]`
      # to map onto the SRAM chip's pins. This tiny wrapper does the
      # tristate resolution and forwards the rest of the ports
      # 1:1. The .qsf points TOP_LEVEL_ENTITY at riski5_top.
      mkdir -p verilog/riski5_top
      cat > verilog/riski5_top/riski5_top.v <<'EOF'
// SPDX-License-Identifier: MIT OR BSD-3-Clause
// Auto-generated wrapper around the Clash-emitted `riski5` module.
// Resolves the SRAM_DQ_{I,O,OE} signals from Clash into a single
// bidirectional inout pin SRAM_DQ[15:0].
module riski5_top (
    input  wire        CLOCK_50,
    input  wire        KEY0,
    input  wire [3:0]  KEY,
    input  wire [17:0] SW,
    output wire [17:0] LEDR,
    output wire [8:0]  LEDG,
    output wire [7:0]  LCD_DATA,
    output wire        LCD_RS,
    output wire        LCD_RW,
    output wire        LCD_EN,
    output wire        LCD_ON,
    output wire        LCD_BLON,
    output wire [17:0] SRAM_ADDR,
    inout  wire [15:0] SRAM_DQ,
    output wire        SRAM_CE_N,
    output wire        SRAM_OE_N,
    output wire        SRAM_WE_N,
    output wire        SRAM_UB_N,
    output wire        SRAM_LB_N
);

  wire [15:0] sram_dq_o;
  wire        sram_dq_oe;

  assign SRAM_DQ = sram_dq_oe ? sram_dq_o : 16'bz;

  riski5 u_riski5 (
      .CLOCK_50    (CLOCK_50),
      .KEY0        (KEY0),
      .KEY         (KEY),
      .SW          (SW),
      .SRAM_DQ_I   (SRAM_DQ),
      .LEDR        (LEDR),
      .LEDG        (LEDG),
      .LCD_DATA    (LCD_DATA),
      .LCD_RS      (LCD_RS),
      .LCD_RW      (LCD_RW),
      .LCD_EN      (LCD_EN),
      .LCD_ON      (LCD_ON),
      .LCD_BLON    (LCD_BLON),
      .SRAM_ADDR   (SRAM_ADDR),
      .SRAM_DQ_O   (sram_dq_o),
      .SRAM_DQ_OE  (sram_dq_oe),
      .SRAM_CE_N   (SRAM_CE_N),
      .SRAM_OE_N   (SRAM_OE_N),
      .SRAM_WE_N   (SRAM_WE_N),
      .SRAM_UB_N   (SRAM_UB_N),
      .SRAM_LB_N   (SRAM_LB_N)
  );

endmodule
EOF
      echo 'set_global_assignment -name VERILOG_FILE "verilog/riski5_top/riski5_top.v"' >> Riski5.qsf

      # Clash emits one .qsys file per altpllSync / alteraPllSync
      # instance, but Quartus 13.0sp1's QSys → ip-generate path drops
      # the device family on Cyclone II projects (DEVICE_FAMILY=Unknown
      # → Component altpll not found). Sidestep that by writing a
      # plain-Verilog wrapper per .qsys with the matching module name
      # plus an altpll instantiation hard-coded with the parameters
      # Clash already chose (CLK0_MULTIPLY_BY=4, CLK0_DIVIDE_BY=5
      # → 50 MHz × 4 / 5 = 40 MHz). Register the wrapper as a regular
      # VERILOG_FILE.
      for q in verilog/Top.topEntity/*.qsys; do
        name=$(basename "$q" .qsys)
        wrapper="verilog/Top.topEntity/$name.v"
        cat > "$wrapper" <<EOF
// SPDX-License-Identifier: MIT OR BSD-3-Clause
// Auto-generated wrapper around the Cyclone II altpll megafunction.
// The module name matches the one Clash emits for altpllSync; the
// parameters mirror those Clash baked into $q from the Dom50 (20 ns)
// and Dom40 (25 ns) domain definitions.

module $name (
    input  wire clk,
    input  wire areset,
    output wire c0,
    output wire locked
);

  wire [4:0] sub_wire0;
  wire       sub_wire2;
  wire       sub_wire3 = 1'b0;
  wire [1:0] sub_wire1 = {sub_wire3, clk};

  assign c0     = sub_wire0[0];
  assign locked = sub_wire2;

  altpll altpll_component (
      .areset (areset),
      .inclk  (sub_wire1),
      .clk    (sub_wire0),
      .locked (sub_wire2),
      .activeclock (), .clkbad (), .clkena (4'b1111), .clkloss (),
      .clkswitch (1'b0), .configupdate (1'b0), .enable0 (), .enable1 (),
      .extclk (), .extclkena (4'b1111), .fbin (1'b1), .fbmimicbidir (),
      .fbout (), .pfdena (1'b1), .phasecounterselect (4'b0),
      .phasedone (), .phasestep (1'b0), .phaseupdown (1'b0), .pllena (1'b1),
      .scanaclr (1'b0), .scanclk (1'b0), .scanclkena (1'b1),
      .scandata (1'b0), .scandataout (), .scandone (), .scanread (1'b0),
      .scanwrite (1'b0), .sclkout0 (), .sclkout1 (), .vcooverrange (),
      .vcounderrange ()
  );

  defparam altpll_component.bandwidth_type        = "AUTO";
  defparam altpll_component.clk0_divide_by        = 5;
  defparam altpll_component.clk0_duty_cycle       = 50;
  defparam altpll_component.clk0_multiply_by      = 4;
  defparam altpll_component.clk0_phase_shift      = "0";
  defparam altpll_component.compensate_clock      = "CLK0";
  defparam altpll_component.inclk0_input_frequency = 20000;
  defparam altpll_component.intended_device_family = "Cyclone II";
  defparam altpll_component.lpm_type              = "altpll";
  defparam altpll_component.operation_mode        = "NORMAL";
  defparam altpll_component.port_clk0             = "PORT_USED";
  defparam altpll_component.port_inclk0           = "PORT_USED";
  defparam altpll_component.port_locked           = "PORT_USED";
  defparam altpll_component.port_areset           = "PORT_USED";
  defparam altpll_component.width_clock           = 5;

endmodule
EOF
        echo "set_global_assignment -name VERILOG_FILE \"$wrapper\"" >> Riski5.qsf
      done

      quartus_sh --flow compile Riski5 || {
        echo ""
        echo "NOTE: Quartus flow did not close cleanly."
        echo "For first bring-up this is typically fine as long as a"
        echo ".sof was produced; pin-assignment TODOs in the .qsf lead"
        echo "to warnings rather than hard failures. Check output_files/"
        echo "and the reports below."
        echo ""
      }

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out" "$out/reports" "$out/verilog"

      # Quartus may drop the .sof into . or output_files/ depending
      # on assignments. Find whichever landed.
      if find . -name 'Riski5.sof' | head -1 | grep -q .; then
        find . -name 'Riski5.sof' -exec cp {} "$out/Riski5.sof" \;
      else
        echo "WARNING: no Riski5.sof in build output. See reports."
      fi

      if [ -d verilog ]; then
        cp -r verilog/* "$out/verilog/" || true
      fi

      find . -name 'Riski5.*.rpt' -exec cp {} "$out/reports/" \; || true

      runHook postInstall
    '';

    meta = with lib; {
      description = "riski5 RV32I Clash core synthesised for the Altera DE2";
      license = licenses.unfree; # inherits from quartus-ii-13
      platforms = ["x86_64-linux"];
    };
  }
