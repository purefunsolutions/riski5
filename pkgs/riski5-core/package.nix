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
  python3,
  quartus-ii-13,
  # Optional: a derivation providing coremark.bin (typically
  # self'.packages.coremark). When non-null, the build overlays
  # a generated firmware/phase1/CoreMark.hs with the real CoreMark
  # bytes baked in and passes -DFIRMWARE_COREMARK to Clash so
  # Top.hs's CPP conditional picks 'coreMarkFirmwareWords' as the
  # imem image. When null, the build is unchanged from the
  # phase-2-P2-A memtest default.
  coremarkPkg ? null,
  # Build the SRAM-execution debug variant: overlays
  # @firmware/phase1/CoreMark.hs@ with a one-file re-export of
  # @HelloSramExec.helloSramExecFirmwareWords@ and reuses the
  # existing @-DFIRMWARE_COREMARK@ build path. Keeping Top.hs
  # __bit-identical__ across variants is load-bearing: even
  # comment-only line-number shifts in Top.hs were producing
  # functionally-different Quartus placements and non-deterministic
  # bitstream regressions during the 2026-04-24 SRAM-exec probe —
  # see @docs/perf/sram-exec-probe-2026-04-24.md@.
  # Only one of @coremarkPkg != null@ and @sramExec@ should be set
  # at a time.
  sramExec ? false,
}: let
  ghcWithClash = haskellPackages.ghcWithPackages (ps:
    with ps; [
      clash-ghc
      clash-prelude
      clash-lib
      containers
      mtl
    ]);
  isCoremark = coremarkPkg != null;
  isSramExec = sramExec && !isCoremark;
in
  stdenv.mkDerivation {
    pname =
      if isCoremark then "riski5-core-coremark"
      else if isSramExec then "riski5-core-sramexec"
      else "riski5-core";
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

    nativeBuildInputs = [ghcWithClash quartus-ii-13 python3];

    dontStrip = true;
    dontPatchELF = true;
    dontFixup = true;

    buildPhase = ''
            runHook preBuild

            export HOME=$(mktemp -d)

            ${lib.optionalString isCoremark ''
              # CoreMark variant (CM-4): overlay firmware/phase1/CoreMark.hs
              # with the real cross-compiled CoreMark 1.01 image from the
              # 'coremark' flake output. The generator pads to exactly
              # ProgSize (4096) 32-bit words with NOPs so 'listToVecTH'
              # gets a length-correct list.
              chmod -R u+w firmware/phase1
              python3 ${./../coremark/gen-coremark-hs.py} \
                ${coremarkPkg}/coremark.bin \
                firmware/phase1/CoreMark.hs
              echo "### CoreMark variant: generated firmware/phase1/CoreMark.hs"
              head -20 firmware/phase1/CoreMark.hs
              echo "..."
              wc -l firmware/phase1/CoreMark.hs
            ''}

            ${lib.optionalString isSramExec ''
              # SRAM-execution debug variant: overlay CoreMark.hs with a
              # re-export of HelloSramExec.helloSramExecFirmwareWords.
              # The -DFIRMWARE_COREMARK path in Top.hs then picks this
              # up through the existing CoreMark import — no Top.hs
              # edits, no Quartus placement shift.
              chmod -R u+w firmware/phase1
              cat > firmware/phase1/CoreMark.hs <<'EOF'
              -- SPDX-FileCopyrightText: 2026 Mika Tammi
              -- SPDX-License-Identifier: MIT OR BSD-3-Clause
              --
              -- Overlaid by the sramExec Nix build: re-exports
              -- HelloSramExec's firmware under the CoreMark name so
              -- the unchanged -DFIRMWARE_COREMARK path in app/Top.hs
              -- bakes the SRAM-exec probe into imem.
              {-# LANGUAGE DataKinds #-}
              {-# LANGUAGE NoStarIsType #-}

              module CoreMark (
                coreMarkFirmwareWords,
              ) where

              import Clash.Prelude (BitVector)
              import HelloSramExec (helloSramExecFirmwareWords)

              coreMarkFirmwareWords :: [BitVector 32]
              coreMarkFirmwareWords = helloSramExecFirmwareWords
              EOF
              # Strip the leading whitespace Nix's heredoc introduces;
              # the re-wrap uses 14 leading spaces per line above.
              sed -i 's/^              //' firmware/phase1/CoreMark.hs
              echo "### sramExec variant: overlaid firmware/phase1/CoreMark.hs"
              cat firmware/phase1/CoreMark.hs

              # Flip FetchPolicy.enableSramFetch = True so Riski5.Soc.soc
              # actually routes @pcFetch in SRAM range@ to the shared SRAM
              # controller. The committed default is False (keeps the
              # CoreMark bitstream bit-identical to the pre-arbiter build
              # — see docs/perf/sram-exec-probe-2026-04-24.md).
              cat > firmware/phase1/FetchPolicy.hs <<'EOF'
              -- SPDX-FileCopyrightText: 2026 Mika Tammi
              -- SPDX-License-Identifier: MIT OR BSD-3-Clause
              --
              -- Overlaid by the sramExec Nix build: turns on the
              -- fetch-side SRAM routing inside Riski5.Soc.soc so the
              -- probe firmware can execute from 0x2000_0000+.
              module FetchPolicy (
                enableSramFetch,
              ) where

              import Prelude (Bool (..))

              enableSramFetch :: Bool
              enableSramFetch = True
              EOF
              sed -i 's/^              //' firmware/phase1/FetchPolicy.hs
              echo "### sramExec variant: overlaid firmware/phase1/FetchPolicy.hs"
              cat firmware/phase1/FetchPolicy.hs
            ''}

            # Clash emits Verilog into ./verilog/Top.topEntity/ based on
            # the Synthesize annotation in app/Top.hs (named "riski5").
            # Top.hs imports MemTest (or CoreMark under
            # -DFIRMWARE_COREMARK) from firmware/phase1/, so include that
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
              ${lib.optionalString (isCoremark || isSramExec) "-DFIRMWARE_COREMARK"} \
              -isrc -iapp -ifirmware/phase1 \
              Top

            # Quartus expects Riski5.qpf / Riski5.qsf / Riski5.sdc at the
            # build root. The .qsf references verilog/Top.topEntity/riski5.v
            # as its source file — matching what Clash just produced.
            cp pkgs/riski5-core/Riski5.qpf .
            cp pkgs/riski5-core/Riski5.qsf .
            cp pkgs/riski5-core/Riski5.sdc .

            # Generate the Altera JTAG UART IP. ip-generate reads the
            # component's _hw.tcl plus user-supplied parameters and emits
            # a synthesisable Verilog blob under ./altera-ip/jtag-uart/.
            # Register the generated file as a VERILOG_FILE in the .qsf so
            # Quartus links it with the rest of the design. The module
            # name is riski5_jtag_uart (matches the --output-name below and
            # the instantiation in riski5_top.v).
            #
            # Parameters:
            #  - readBufferDepth=64, writeBufferDepth=64: match the real
            #    Altera default (Nios II reference designs ship 64-byte
            #    FIFOs). 64 bytes per direction = 128 bytes total, well
            #    below the 1-M4K threshold so no block RAM is consumed.
            mkdir -p altera-ip/jtag-uart
            ip-generate \
              --component-file=${quartus-ii-13}/share/altera13.0sp1/ip/altera/sopc_builder_ip/altera_avalon_jtag_uart/altera_avalon_jtag_uart_hw.tcl \
              --output-directory=altera-ip/jtag-uart \
              --output-name=riski5_jtag_uart \
              --file-set=QUARTUS_SYNTH \
              --language=VERILOG \
              --system-info=DEVICE_FAMILY=CYCLONEII \
              --system-info=DEVICE=EP2C35F672C6 \
              --component-parameter=readBufferDepth=64 \
              --component-parameter=writeBufferDepth=64
            echo 'set_global_assignment -name VERILOG_FILE "altera-ip/jtag-uart/riski5_jtag_uart.v"' >> Riski5.qsf

            # Generate the Altera SDRAM Controller IP for the DE2's single
            # 16-bit SDR SDRAM chip (ISSI IS42S16400-class: 4 M × 16, 4
            # banks, 12-bit row × 8-bit column × 2-bit bank × 16-bit data =
            # 8 MB total). dataWidth=16 matches the physical chip; the
            # Avalon-MM slave exposed to the riski5 SoC is therefore also
            # 16-bit wide. Our Clash-side `Riski5.Sdram` module does the
            # 32↔16 width adaptation — two back-to-back 16-bit Avalon
            # transactions per 32-bit LW/SW, exactly like `Riski5.Sram`
            # does for the async SRAM. At dataWidth=32 the IP would expect
            # two 16-bit chips in parallel, which the DE2 doesn't have.
            #
            # Timing parameters are sized for the -7 speed grade of the
            # DE2's chip and a 40 MHz (Dom30 — name kept even after the
            # phase-2 PLL retarget) clock, leaving generous margin:
            #
            #   casLatency       = 2   — fine below ~133 MHz for a -7 part
            #   TRCD             = 20  ns (≥ 15 ns data-sheet min)
            #   TRP              = 20  ns (≥ 15 ns)
            #   TRFC             = 70  ns (Altera default; ≥ 60 ns needed)
            #   TWR              = 14  ns (data-sheet 14 ns absolute)
            #   TMRD             = 2   cycles
            #   TAC              = 5.5 ns (data-sheet-typical)
            #   refreshPeriod    = 15.625 µs (64 ms / 4096 rows)
            #   powerUpDelay     = 100 µs (initialisation NOP window)
            #   initRefreshCommands = 2
            #   clockRate        = 30_000_000 Hz
            #
            # Geometry:
            #   rowWidth   = 12   → 4096 rows
            #   columnWidth = 8   → 256 cols
            #   numberOfBanks = 4
            #   size (bytes) = 8 * 1024 * 1024 = 8388608
            #   addressWidth = 22 (byte-address bits covering 4 M × 16-bit
            #                      words = 8 MB; the az_addr bus that the
            #                      IP exposes is 22 bits wide indexed by
            #                      16-bit words, which we derive from
            #                      addr[22:1] in the Clash-side adapter)
            #   bankWidth    = 2
            #
            # `registerDataIn=true` puts an output flop on the za_data path
            # so Quartus can place it in an I/O register for better timing
            # on the DRAM_DQ return leg.
            mkdir -p altera-ip/sdram
            ip-generate \
              --component-file=${quartus-ii-13}/share/altera13.0sp1/ip/altera/sopc_builder_ip/altera_avalon_new_sdram_controller/altera_avalon_new_sdram_controller_hw.tcl \
              --output-directory=altera-ip/sdram \
              --output-name=riski5_sdram \
              --file-set=QUARTUS_SYNTH \
              --language=VERILOG \
              --system-info=DEVICE_FAMILY=CYCLONEII \
              --system-info=DEVICE=EP2C35F672C6 \
              --component-parameter=casLatency=2 \
              --component-parameter=columnWidth=8 \
              --component-parameter=rowWidth=12 \
              --component-parameter=dataWidth=16 \
              --component-parameter=numberOfBanks=4 \
              --component-parameter=numberOfChipSelects=1 \
              --component-parameter=refreshPeriod=15.625 \
              --component-parameter=initRefreshCommands=2 \
              --component-parameter=initNOPDelay=100.0 \
              --component-parameter=powerUpDelay=100.0 \
              --component-parameter=TAC=5.5 \
              --component-parameter=TRCD=20.0 \
              --component-parameter=TRFC=70.0 \
              --component-parameter=TRP=20.0 \
              --component-parameter=TWR=14.0 \
              --component-parameter=TMRD=2 \
              --component-parameter=clockRate=30000000 \
              --component-parameter=size=8388608 \
              --component-parameter=addressWidth=22 \
              --component-parameter=bankWidth=2 \
              --component-parameter=generateSimulationModel=false \
              --component-parameter=pinsSharedViaTriState=false \
              --component-parameter=registerDataIn=true \
              --component-parameter=model=custom
            echo 'set_global_assignment -name VERILOG_FILE "altera-ip/sdram/riski5_sdram.v"' >> Riski5.qsf

            # Bidirectional pin wrapper + external ALTPLL + Altera JTAG UART
            # instantiation. The Clash top now takes clk30 / rst30_n as
            # inputs (rather than owning altpllSync internally), so this
            # wrapper owns the PLL and the IP. Both the riski5 core and the
            # JTAG UART share the same 50 MHz clock — one source of truth.
            mkdir -p verilog/riski5_top
            cat > verilog/riski5_top/riski5_top.v <<'EOF'
      // SPDX-License-Identifier: MIT OR BSD-3-Clause
      //
      // Top-level wrapper around the Clash-emitted `riski5` module.
      //
      // Responsibilities:
      //   1. Derive the 50 MHz core clock (clk30) from CLOCK_50 via a
      //      directly-instantiated altpll.
      //   2. Build rst30_n = KEY0 & pll_locked so the design holds reset
      //      until the PLL has locked and the user has released KEY0.
      //   3. Resolve the bidirectional SRAM_DQ bus from the core's
      //      SRAM_DQ_{O,OE,I} triplet.
      //   4. Instantiate the Altera altera_avalon_jtag_uart IP
      //      (module `riski5_jtag_uart`, produced by ip-generate earlier
      //      in this buildPhase) and bridge our 5-signal UART bus into
      //      its Avalon-MM slave interface.
      //
      // The JTAG UART rides the USB-Blaster JTAG tap — no external pins.

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
          output wire        SRAM_LB_N,
          // SDR SDRAM — 8 MB IS42S16400-class, driven by the Altera
          // altera_avalon_new_sdram_controller IP instantiated below.
          output wire [11:0] DRAM_ADDR,
          output wire [1:0]  DRAM_BA,
          output wire        DRAM_CAS_N,
          output wire        DRAM_CKE,
          output wire        DRAM_CLK,
          output wire        DRAM_CS_N,
          inout  wire [15:0] DRAM_DQ,
          output wire        DRAM_LDQM,
          output wire        DRAM_UDQM,
          output wire        DRAM_RAS_N,
          output wire        DRAM_WE_N
      );

        // ----- PLL: CLOCK_50 (50 MHz) → clk30 (50 MHz) -----------------
        wire [4:0] altpll_clk_vec;
        wire       clk30 = altpll_clk_vec[0];
        wire       pll_locked;
        altpll u_altpll (
            .areset (1'b0),
            .inclk  ({1'b0, CLOCK_50}),
            .clk    (altpll_clk_vec),
            .locked (pll_locked),
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
        defparam u_altpll.bandwidth_type        = "AUTO";
        defparam u_altpll.clk0_divide_by        = 5;
        defparam u_altpll.clk0_duty_cycle       = 50;
        defparam u_altpll.clk0_multiply_by      = 4;
        defparam u_altpll.clk0_phase_shift      = "0";
        defparam u_altpll.compensate_clock      = "CLK0";
        defparam u_altpll.inclk0_input_frequency = 20000;
        defparam u_altpll.intended_device_family = "Cyclone II";
        defparam u_altpll.lpm_type              = "altpll";
        defparam u_altpll.operation_mode        = "NORMAL";
        defparam u_altpll.port_clk0             = "PORT_USED";
        defparam u_altpll.port_inclk0           = "PORT_USED";
        defparam u_altpll.port_locked           = "PORT_USED";
        defparam u_altpll.port_areset           = "PORT_USED";
        defparam u_altpll.width_clock           = 5;

        // Active-low reset: asserted (low) until the PLL locks AND KEY0
        // has been released (KEY0 is active-low on the DE2).
        wire rst30_n = KEY0 & pll_locked;

        // ----- Bidirectional SRAM DQ resolution -----------------------
        wire [15:0] sram_dq_o;
        wire        sram_dq_oe;
        assign SRAM_DQ = sram_dq_oe ? sram_dq_o : 16'bz;

        // ----- UART bus tap ⇄ Altera IP Avalon-MM slave ---------------
        // Our bus carries byte addresses; the IP's av_address is 1 bit
        // (word offset — 0 = DATA, 1 = CONTROL) because reads/writes are
        // always 32-bit. Pick bit [2] of the byte address to produce that.
        // Altera's Avalon-MM uses active-low read/write strobes, so we
        // invert our active-high sel/be/re to get those.
        wire        uart_sel;
        wire [31:0] uart_addr;
        wire [31:0] uart_wdata;
        wire [3:0]  uart_be;
        wire        uart_re;
        wire [31:0] uart_rdata;

        wire [31:0] jtag_uart_readdata;
        wire        jtag_uart_waitrequest;
        wire        jtag_uart_irq;
        wire        jtag_uart_dataavailable;
        wire        jtag_uart_readyfordata;
        wire        jtag_uart_wr       = uart_sel & (uart_be != 4'b0);
        wire        jtag_uart_rd       = uart_sel & uart_re;
        wire        jtag_uart_write_n  = ~jtag_uart_wr;
        wire        jtag_uart_read_n   = ~jtag_uart_rd;

        riski5_jtag_uart u_jtag_uart (
            .clk            (clk30),
            .rst_n          (rst30_n),
            .av_chipselect  (uart_sel),
            .av_address     (uart_addr[2]),
            .av_read_n      (jtag_uart_read_n),
            .av_write_n     (jtag_uart_write_n),
            .av_writedata   (uart_wdata),
            .av_readdata    (jtag_uart_readdata),
            .av_waitrequest (jtag_uart_waitrequest),
            .av_irq         (jtag_uart_irq),
            .dataavailable  (jtag_uart_dataavailable),
            .readyfordata   (jtag_uart_readyfordata)
        );
        // Feed read-data back to the core. UART_READY is the complement
        // of av_waitrequest: the Altera IP asserts waitrequest for the
        // first cycle of every Avalon-MM transaction while it latches
        // av_writedata one cycle later than the master presents it. Our
        // SoC's stall mechanism honours the low pulse so the core holds
        // uart_wdata stable at the cycle the IP's TX FIFO captures it.
        assign uart_rdata  = jtag_uart_readdata;
        wire   uart_ready  = ~jtag_uart_waitrequest;

        // ----- SDRAM bus tap ⇄ Altera IP Avalon-MM slave --------------
        // The Clash-side Riski5.Sdram adapter produces the 16-bit
        // master-side signals (CS, 22-bit word address, 16-bit write
        // data, 2-bit byte-enable, and active-high read / write
        // strobes). Altera's Avalon-MM slave expects active-low
        // *_n strobes, so we invert at this boundary. The IP's
        // za_data / za_valid / za_waitrequest feed back to the Clash
        // adapter via the three SDRAM_* input ports on the core.
        wire        sdram_cs;
        wire [21:0] sdram_addr_bus;
        wire [15:0] sdram_wdata;
        wire [1:0]  sdram_be;
        wire        sdram_rd;
        wire        sdram_wr;

        wire [15:0] sdram_ip_readdata;
        wire        sdram_ip_valid;
        wire        sdram_ip_waitrequest;

        // DRAM_DQ is inout on both the top-level port and the IP's
        // zs_dq port — the Altera IP owns the tristate enable logic
        // internally, so we just wire them together directly. (SRAM
        // needs our own resolution because the core drives those
        // pins from pure logic without an Avalon-MM IP in between.)

        // DRAM_CLK is forwarded from the core clock. At 50 MHz the
        // setup/hold margin at the SDRAM pins is ~10 ns either way,
        // well above the IS42S16400-7B's 1.5 / 0.8 ns requirements,
        // so we can share clk30 directly without a phase-shifted PLL
        // tap. Revisit if the target clock climbs past ~60 MHz.
        assign DRAM_CLK = clk30;

        riski5_sdram u_sdram (
            .clk            (clk30),
            .reset_n        (rst30_n),
            // Avalon-MM slave (master-side driven by Clash adapter)
            .az_cs          (sdram_cs),
            .az_addr        (sdram_addr_bus),
            .az_data        (sdram_wdata),
            .az_be_n        (~sdram_be),
            .az_rd_n        (~sdram_rd),
            .az_wr_n        (~sdram_wr),
            .za_data        (sdram_ip_readdata),
            .za_valid       (sdram_ip_valid),
            .za_waitrequest (sdram_ip_waitrequest),
            // SDRAM-chip side — directly to the board pads
            .zs_addr        (DRAM_ADDR),
            .zs_ba          (DRAM_BA),
            .zs_cas_n       (DRAM_CAS_N),
            .zs_cke         (DRAM_CKE),
            .zs_cs_n        (DRAM_CS_N),
            .zs_dq          (DRAM_DQ),
            .zs_dqm         ({DRAM_UDQM, DRAM_LDQM}),
            .zs_ras_n       (DRAM_RAS_N),
            .zs_we_n        (DRAM_WE_N)
        );
        wire sdram_ready = ~sdram_ip_waitrequest;

        // ----- Clash riski5 core --------------------------------------
        wire [31:0] debug_pcfetch;
        wire [7:0]  debug_flags;

        riski5 u_riski5 (
            .CLOCK_30    (clk30),
            .RESET_30_N  (rst30_n),
            .KEY         (KEY),
            .SW          (SW),
            .SRAM_DQ_I   (SRAM_DQ),
            .UART_RDATA  (uart_rdata),
            .UART_READY  (uart_ready),
            .SDRAM_RDATA (sdram_ip_readdata),
            .SDRAM_VALID (sdram_ip_valid),
            .SDRAM_READY (sdram_ready),
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
            .SRAM_LB_N   (SRAM_LB_N),
            .UART_SEL    (uart_sel),
            .UART_ADDR   (uart_addr),
            .UART_WDATA  (uart_wdata),
            .UART_BE     (uart_be),
            .UART_RE     (uart_re),
            .SDRAM_CS    (sdram_cs),
            .SDRAM_ADDR  (sdram_addr_bus),
            .SDRAM_WDATA (sdram_wdata),
            .SDRAM_BE    (sdram_be),
            .SDRAM_RD    (sdram_rd),
            .SDRAM_WR    (sdram_wr),
            .DEBUG_PCFETCH (debug_pcfetch),
            .DEBUG_FLAGS   (debug_flags)
        );

        // ----- altsource_probe — read pcFetchS via JTAG --------------
        // 32-bit probe carrying the core's pcFetchS. Sample with
        // @quartus_stp@'s @read_probe_data@ over JTAG. No physical
        // pin — the JTAG hub on the FPGA reads the latched value
        // directly. Useful for diagnosing the @sramexec@ silicon
        // halt: read pcFetch after the firmware halts to learn
        // which step in the SRAM-to-BRAM redirect path got stuck.
        altsource_probe #(
            .lpm_type                 ("altsource_probe"),
            .lpm_hint                 ("CBX_AUTO_BLACKBOX=ALL"),
            .source_width             (0),
            .probe_width              (32),
            .instance_id              ("PCFE"),
            .sld_ir_width             (3),
            .source_initial_value     ("0"),
            .sld_auto_instance_index  ("YES"),
            .sld_instance_index       (0),
            .enable_metastability     ("NO")
        ) u_pcfetch_probe (
            .probe        (debug_pcfetch),
            .source       (),
            .source_clk   (1'b0),
            .source_ena   (1'b0)
        );

        // ----- altsource_probe — read packed diagnostic flags --------
        // 8-bit probe carrying SoC-level stall / ready / accepted
        // flags. See `Riski5.Soc.SocOut.soDbgFlags` for the bit
        // layout. Read via @quartus_stp@'s @read_probe_data@ on
        // instance index 1. Together with the pcFetch probe, this
        // tells us whether the pipeline is stalled, why, and which
        // slave's ready signal is lagging at the moment of a
        // silicon hang.
        altsource_probe #(
            .lpm_type                 ("altsource_probe"),
            .lpm_hint                 ("CBX_AUTO_BLACKBOX=ALL"),
            .source_width             (0),
            .probe_width              (8),
            .instance_id              ("DBGF"),
            .sld_ir_width             (3),
            .source_initial_value     ("0"),
            .sld_auto_instance_index  ("YES"),
            .sld_instance_index       (1),
            .enable_metastability     ("NO")
        ) u_flags_probe (
            .probe        (debug_flags),
            .source       (),
            .source_clk   (1'b0),
            .source_ena   (1'b0)
        );

      endmodule
      EOF
            echo 'set_global_assignment -name VERILOG_FILE "verilog/riski5_top/riski5_top.v"' >> Riski5.qsf

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
