# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# riski5 flake-parts perSystem. Exposes the synthesised .sof build
# plus the flash + console helper apps.
{inputs, ...}: {
  perSystem = {
    self',
    system,
    ...
  }: let
    # Reuse alterade2-flake's nixpkgs overlay / Clash overrides so
    # our Haskell + Quartus toolchains are identical to the sibling
    # repo. In particular this inherits the allowUnfree / allowBroken
    # flags and the dontCheck overrides for clash-lib / clash-ghc /
    # clash-prelude.
    pkgs = import inputs.nixpkgs {
      inherit system;
      config = {
        allowUnfree = true;
        allowBroken = true;
      };
      overlays = [
        (_final: prev: {
          haskellPackages = prev.haskellPackages.override {
            overrides = _hself: hsuper: {
              clash-lib = prev.haskell.lib.dontCheck hsuper.clash-lib;
              clash-ghc = prev.haskell.lib.dontCheck hsuper.clash-ghc;
              clash-prelude = prev.haskell.lib.dontCheck hsuper.clash-prelude;
            };
          };
        })
      ];
    };

    inherit (inputs.alterade2-flake.packages.${system}) quartus-ii-13;
    inherit (inputs.verilambda.packages.${system}) verilambda-shim-gen;

    # YosysHQ/riscv-formal pinned as a Nix package. Tree lives
    # under $out/share/riscv-formal/ — see pkgs/riscv-formal/package.nix.
    riscv-formal = pkgs.callPackage ./riscv-formal/package.nix {};
  in {
    _module.args.pkgs = pkgs;

    packages = {
      riski5-core = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
      };

      # Verilator-compiled whole-SoC simulation library (Layer 1.75
      # of docs/verification.md). Consumed by the riski5-hwsim-check
      # derivation and, for local dev, by `cabal test --flag=hwsim`
      # with RISKI5_SIM_LIB_DIR=$(readlink -f result)/lib.
      riski5-sim = pkgs.callPackage ./riski5-sim/package.nix {
        inherit quartus-ii-13 verilambda-shim-gen;
      };

      # YosysHQ/riscv-formal harness — expose the pinned package
      # so consumers can point at it with `.#riscv-formal` too.
      inherit riscv-formal;

      # Layer 2 of docs/verification.md: SymbiYosys proofs of the
      # Clash-emitted riski5_formal.v against the RVFI spec's
      # per-instruction contracts.
      riski5-formal = pkgs.callPackage ./riski5-formal/package.nix {
        inherit riscv-formal;
      };

      # EEMBC CoreMark 1.01 cross-compiled for the riski5 silicon
      # target. Produces $out/coremark.{elf,bin,mif,dis,size} — the
      # MIF is the artefact a future riski5-core-coremark bitstream
      # variant (CM-4) loads into the imem M4K block. Kept as its
      # own flake output so `nix build .#coremark` is a standalone
      # check that the cross toolchain + platform port still build.
      coremark = pkgs.callPackage ./coremark/package.nix {};

      # CoreMark-baked bitstream (CM-4). Reuses the same
      # pkgs/riski5-core/package.nix machinery as the MemTest
      # default; the only difference is that @coremarkPkg@ here
      # makes the build overlay firmware/phase1/CoreMark.hs with
      # the real CoreMark bytes from the 'coremark' output above
      # and pass -DFIRMWARE_COREMARK to Clash.
      riski5-core-coremark = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        coremarkPkg = self'.packages.coremark;
      };

      # Debug bitstream that bakes firmware/phase1/HelloSramExec.hs
      # into the imem. Probes whether the core can execute
      # instructions fetched from SRAM. End-to-end working since
      # the SRAM-exec arc closed (CoreMark stable at 44.57 / 1.114,
      # silicon prints @BSBSBS…@ over JTAG-UART).
      riski5-core-sramexec = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        sramExec = true;
      };

      # Debug bitstream that bakes firmware/phase1/HelloSdramExec.hs
      # into the imem. Probes whether the core can execute
      # instructions fetched from SDRAM (the off-chip 8 MB IS42S16400
      # via the Altera SDRAM Controller IP, same IP that already
      # serves SDRAM data accesses). Architectural contract: writes
      # two encoded instructions into SDRAM[0x80000000..], JALRs
      # there, the SDRAM-resident @sw@ prints @S@ to the UART, the
      # @ebreak@ traps back to BRAM[0], firmware loops — yielding
      # @BSBSBS…@ on the JTAG-UART iff SDRAM execution works.
      # Last architectural piece before the core can run a Linux
      # kernel image (kernels live in SDRAM).
      riski5-core-sdramexec = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        sdramExec = true;
      };

      # Debug bitstream that bakes firmware/phase1/HelloAExt.hs into
      # imem. Probes whether 'Riski5.Core.FU.Amo' (the new RV32A FSM)
      # works against the real SRAM controller on silicon. Expected
      # JTAG-UART output: a periodic @BLSAX BLSAX …@ stream.
      riski5-core-aexttest = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        aExtTest = true;
      };

      # Debug bitstream that bakes firmware/phase1/HelloTimerIrq.hs
      # into imem. Probes the full CLINT → mip.MTIP → trap → handler
      # chain on real hardware. Expected output: @B......T......T…@.
      riski5-core-timerirqtest = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        timerIrqTest = true;
      };

      # L-3b: SDRAM-load bitstream. Bakes firmware/phase1/SdramLoader.hs
      # into imem. Boot firmware reads a length-prefixed binary blob
      # from the JTAG-UART RX FIFO, writes it to SDRAM at 0x80000000+,
      # then JALRs to 0x80000000. Use scripts/load-sdram-jtag.sh as
      # the host-side workflow:
      #     nix run .#flash-riski5-sdramload
      #     scripts/load-sdram-jtag.sh path/to/kernel.bin
      # Expected JTAG-UART output: 'L' (loader ready) → 'D' (load
      # complete) → kernel output.
      riski5-core-sdramload = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        sdramLoad = true;
      };

      # L-9: Linux-boot bitstream. Bakes firmware/phase1/LinuxBoot.hs
      # into imem — a combined SDRAM-loader + boot-protocol jumper.
      # On power-up it prints 'L', reads (kernel + DTB) from
      # JTAG-UART, writes to SDRAM, prints 'D', then JALRs into the
      # kernel at 0x80000000 with a0=0, a1=&dtb, sp=top of SRAM.
      # Use scripts/load-linux.sh as the host-side workflow.
      riski5-core-linux = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        linuxBoot = true;
      };

      # L-4: compiled device tree (DTB) for the riski5 SoC.
      # firmware/phase2/dts/riski5.dts → riski5.dtb via `dtc`.
      # Consumed by the Linux kernel build (L-6) which embeds it
      # into the kernel image as the "appended DTB", and by the
      # L-3b SDRAM-loader workflow when we eventually pad the
      # kernel image with the DTB at a known offset.
      riski5-dtb = pkgs.callPackage ./riski5-dtb/package.nix {};

      # L-6: rv32 nommu Linux kernel. Builds Linux 6.18 from
      # nixpkgs's pinned source with riski5-specific config overlay
      # (Altera JTAG-UART console, SiFive PLIC + CLINT bindings,
      # aggressive size cuts). Output: $out/Image (raw kernel
      # binary, ready to load via L-3b's loader) + $out/vmlinux
      # (ELF for Spike). Initramfs is layered later via the
      # L-7 / L-8 packages.
      #
      # Build is slow (~5 min). Trigger with `nix build
      # .#linux-rv32-nommu`.
      linux-rv32-nommu = pkgs.callPackage ./linux-rv32-nommu/package.nix {};

      # L-7: BFLT /init hello-world. Cross-compiles
      # firmware/phase2/init-rv32-nommu/init.S to a tiny BFLT
      # binary that the L-8 initramfs places at /init.
      init-rv32-nommu = pkgs.callPackage ./init-rv32-nommu/package.nix {};

      # L-8: minimal cpio initramfs containing the L-7 BFLT init
      # plus empty /proc /sys /dev mount-point dirs. Output:
      # $out/initramfs.cpio.
      initramfs-rv32-nommu = pkgs.callPackage ./initramfs-rv32-nommu/package.nix {
        inherit (self'.packages) init-rv32-nommu;
      };

      flash-riski5 = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        inherit (self'.packages) riski5-core;
      };

      # CoreMark-variant flasher. Same shell script as
      # flash-riski5, but points at Riski5.sof inside the
      # riski5-core-coremark output so `nix run .#flash-riski5-coremark`
      # always grabs the CoreMark-baked bitstream.
      flash-riski5-coremark = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-coremark;
      };

      # Flasher for the SRAM-execution debug bitstream.
      flash-riski5-sramexec = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-sramexec;
      };

      # Flasher for the SDRAM-execution debug bitstream.
      flash-riski5-sdramexec = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-sdramexec;
      };

      # Flasher for the A-extension silicon test bitstream.
      flash-riski5-aexttest = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-aexttest;
      };

      # Flasher for the timer-interrupt silicon test bitstream.
      flash-riski5-timerirqtest = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-timerirqtest;
      };

      # Flasher for the L-3b SDRAM-load bitstream.
      flash-riski5-sdramload = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-sdramload;
      };

      # Flasher for the L-9 Linux-boot bitstream.
      flash-riski5-linux = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-linux;
      };

      # `nix run .#load-linux` — sends kernel + DTB to the
      # already-flashed linux-boot bitstream and attaches
      # nios2-terminal. With no args, uses the flake-built
      # kernel (linux-rv32-nommu) + DTB (riski5-dtb). Override
      # via `nix run .#load-linux -- kernel.bin dtb`.
      load-linux = pkgs.callPackage ../apps/load-linux.nix {
        inherit quartus-ii-13;
        inherit (self'.packages) linux-rv32-nommu riski5-dtb;
      };

      # `nix run .#load-sdram-jtag -- <bin-path>` — host-side
      # counterpart to the L-3b SdramLoader bitstream. Sends a
      # length-prefixed binary blob via JTAG-UART; the on-board
      # firmware writes to SDRAM and JALRs. Generic loader for
      # the SdramLoader path (the Linux-specific equivalent is
      # `load-linux` above).
      load-sdram-jtag = pkgs.callPackage ../apps/load-sdram-jtag.nix {
        inherit quartus-ii-13;
      };

      console = pkgs.callPackage ../apps/console.nix {
        inherit quartus-ii-13;
      };

      default = self'.packages.riski5-core;
    };

    apps = {
      flash-riski5 = {
        type = "app";
        program = "${self'.packages.flash-riski5}/bin/flash-riski5";
      };
      flash-riski5-coremark = {
        type = "app";
        program = "${self'.packages.flash-riski5-coremark}/bin/flash-riski5";
      };
      flash-riski5-sramexec = {
        type = "app";
        program = "${self'.packages.flash-riski5-sramexec}/bin/flash-riski5";
      };
      flash-riski5-sdramexec = {
        type = "app";
        program = "${self'.packages.flash-riski5-sdramexec}/bin/flash-riski5";
      };
      flash-riski5-aexttest = {
        type = "app";
        program = "${self'.packages.flash-riski5-aexttest}/bin/flash-riski5";
      };
      flash-riski5-timerirqtest = {
        type = "app";
        program = "${self'.packages.flash-riski5-timerirqtest}/bin/flash-riski5";
      };
      flash-riski5-sdramload = {
        type = "app";
        program = "${self'.packages.flash-riski5-sdramload}/bin/flash-riski5";
      };
      flash-riski5-linux = {
        type = "app";
        program = "${self'.packages.flash-riski5-linux}/bin/flash-riski5";
      };
      load-linux = {
        type = "app";
        program = "${self'.packages.load-linux}/bin/load-linux";
      };
      load-sdram-jtag = {
        type = "app";
        program = "${self'.packages.load-sdram-jtag}/bin/load-sdram-jtag";
      };
      console = {
        type = "app";
        program = "${self'.packages.console}/bin/console";
      };
    };
  };
}
