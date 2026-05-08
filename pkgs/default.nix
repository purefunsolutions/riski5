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

      # Verilator sim library variant for the high-SDRAM-stress
      # firmware. Same Verilog flow as riski5-sim, but bakes
      # HelloSdramHighStress into BRAM and keeps FetchPolicy at
      # the BRAM-only default. Drives a self-contained probe that
      # walks the upper 2 MB of SDRAM in three phases (write,
      # readback, re-read after delay) — hwsim peer of the silicon
      # riski5-core-sdramhighstress run, used to confirm the RTL
      # also produces PASS2 (#64 follow-up).
      riski5-sim-sdramhighstress = pkgs.callPackage ./riski5-sim/package.nix {
        inherit quartus-ii-13 verilambda-shim-gen;
        firmware = "sdramHighStress";
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

      # Bigger SDRAM-execute test than @sdramexec@: bakes
      # firmware/phase1/HelloSdramStress.hs which stages a
      # ~30-instruction SDRAM-resident loop that writes + reads
      # 4 SDRAM banks per iteration for 256 iterations, prints
      # one '.' per clean iter / 'F' on first failure. Useful
      # for bisecting "Linux kernel hang due to SDRAM corruption"
      # vs "kernel-specific bug" — task #17 follow-up to #146.
      riski5-core-sdramstress = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        sdramStress = true;
      };

      # Bisect variant for task #17. Same workload as sdramstress
      # (write+read 4 SDRAM banks per iteration), but the loop runs
      # from BRAM. Use to disambiguate SDRAM-data-path bugs from
      # SoC-arbiter / fetch+data multiplex bugs.
      riski5-core-sdramdatastress = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        sdramDataStress = true;
      };

      # Follow-up to task #64: walks the upper 2 MB of SDRAM
      # (0x80600000–0x80800000) at 1 KB stride and the proven-clean
      # lower 6 MB at 4 KB stride in three phases (write, immediate
      # read-back, re-read after delay) using the unique pattern
      # `addr ^ 0xDEADBEEF`. BRAM-resident; FetchPolicy stays at
      # BRAM-only. Discriminates whether the high-address SDRAM
      # corruption observed during Linux boot is silicon-only or
      # also reproducible in hwsim.
      riski5-core-sdramhighstress = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        sdramHighStress = true;
      };

      # Debug bitstream that bakes firmware/phase1/HelloAExt.hs into
      # imem. Probes whether 'Riski5.Core.FU.Amo' (the new RV32A FSM)
      # works against the real SRAM controller on silicon. Expected
      # JTAG-UART output: a periodic @BLSAX BLSAX …@ stream.
      riski5-core-aexttest = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        aExtTest = true;
      };

      # Task #29: AMO-stress silicon test. Bakes
      # firmware/phase1/HelloAmoStress.hs into imem. Mirrors the
      # SDRAM-stress probe but uses amoswap.w + verify-lw across 4
      # SDRAM banks per iteration (= AMO Read/Write phases under
      # SDRAM fetch contention). Top suspect for the Linux stack-
      # protector panic at PC=0x8002cd98 (atomic refcounts at the
      # panic sites; AMO FU is the newest silicon-bringup
      # component). Expected JTAG-UART output: @B......D@ runs of
      # dots; per-bank-failure 'A'/'B'/'C'/'D' + 'F' if AMO is
      # broken on silicon.
      riski5-core-amostress = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        amoStress = true;
      };

      # Task #58 follow-up: M-extension MUL/DIV silicon stress test.
      # Bakes firmware/phase1/HelloMdStress.hs into imem. BRAM-only
      # tight loop hammering MUL / MULHU / MULH / DIVU / DIV / REMU
      # with known operands → known answers; expected silicon stream
      # is `BMUHDSR.MUHDSR.…`. If silicon hangs (no '.' bytes after
      # the 'B' boot byte), the iterative MUL/DIV FSM is at fault —
      # closes the silicon-coverage gap CLAUDE.md calls out.
      riski5-core-mdstress = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        mdStress = true;
      };

      # Task #64 follow-up: cooperative-context-switch silicon stress.
      # Bakes firmware/phase1/HelloSchedStress.hs into imem. Two
      # tasks share an SRAM-backed 14-word context block (ra, sp,
      # s0..s11) and yield to each other via a switch_to() routine
      # mirroring the kernel's __switch_to. Expected steady-state
      # silicon stream: `BAb.Ab.Ab.…`. If silicon hangs after
      # `BA` (or any short prefix shorter than the third `Ab.`),
      # the synthesised core's wake-from-sleep path is broken —
      # exactly the symptom the 1B-cycle Linux trace narrowed
      # in #64.
      riski5-core-schedstress = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        schedStress = true;
      };

      # Task #60 follow-up: same M-extension stress firmware but at
      # 30 MHz uniform clock (slowClock=true → +8 ns/cycle headroom).
      # If silicon passes here but fails at 40 MHz, the iterative
      # MUL/DIV FSM bug is a TIMING violation rather than a logic bug.
      riski5-core-mdstress-slow = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        mdStress = true;
        slowClock = true;
      };
      flash-riski5-mdstress-slow = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-mdstress-slow;
      };

      # Task #32: LR/SC-stress silicon test (follow-up to #29 after
      # amostress came back clean — silicon AMO is solid). Bakes
      # firmware/phase1/HelloLrScStress.hs into imem. Same shape
      # as amostress but uses the lr.w + sc.w.rl cmpxchg retry
      # loop matching the kernel's arch_cmpxchg32_relaxed at the
      # panic site task_work_add (PC=0x8002cd98).
      riski5-core-lrscstress = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        lrScStress = true;
      };

      # Task #33: stack-stress silicon test (follow-up to #29 / #32
      # after both amo + LR/SC came back clean). Bakes
      # firmware/phase1/HelloStackStress.hs into imem. Mirrors
      # task_work_add's prologue/epilogue exactly: 4-register
      # save/restore (ra, s0, s1, t0) on SDRAM-resident stack
      # under fetch contention. If sw/lw to SDRAM stack has any
      # corner case, this variant prints 'F' + per-register label.
      riski5-core-stackstress = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        stackStress = true;
      };

      # Task #34: trap-during-stress silicon test (follow-up to #33
      # after bare stack came back clean). Bakes
      # firmware/phase1/HelloTrapStress.hs into imem. Same inner
      # loop as stackStress (4-reg prologue/epilogue mirroring
      # task_work_add) but runs WITH timer IRQs firing every ~256
      # cycles. If a trap landing mid-prologue / mid-epilogue
      # corrupts the SDRAM stack frame or live registers, this
      # variant prints 'F' + per-register label.
      riski5-core-trapstress = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        trapStress = true;
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
        # The B-* Copilot-eDSL → C → RV32 boot ROM. The variant's
        # buildPhase drops `${bootRomCopilot}/CoreMark.hs` straight
        # into firmware/phase1/CoreMark.hs.
        bootRomCopilot = self'.packages.riski5-boot-rom-rv32-nommu;
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

      # 6.12 LTS variant for #64 bisect — try a more conservative
      # kernel to see if the silent post-Mountpoint-cache wedge is
      # specific to 6.18 or shared across branches.
      linux-rv32-nommu-6-12 =
        pkgs.callPackage ./linux-rv32-nommu/package.nix {
          kernelChoice = "6.12";
        };
      linux-rv32-nommu-6-12-with-initramfs =
        pkgs.callPackage ./linux-rv32-nommu/package.nix {
          kernelChoice = "6.12";
          initramfs = self'.packages.initramfs-rv32-nommu;
        };

      # Linux 6.18 with debug pr_emerg()s in rest_init /
      # kernel_init_freeable / after kthreadd_done — see where #64
      # actually wedges past Mountpoint-cache.
      linux-rv32-nommu-debug =
        pkgs.callPackage ./linux-rv32-nommu/package.nix {
          initramfs = self'.packages.initramfs-rv32-nommu;
          debugSchedulerPrintks = true;
        };

      # Same kernel but with the L-7 BFLT init baked into a built-in
      # cpio initramfs (CONFIG_INITRAMFS_SOURCE). With this variant
      # the kernel auto-extracts /init at boot from its own ELF
      # __initramfs_start segment instead of relying on a separate
      # cpio loaded by the bootloader. Useful for #64 debug to
      # bypass any bootloader-side initramfs handover bug.
      linux-rv32-nommu-with-initramfs =
        pkgs.callPackage ./linux-rv32-nommu/package.nix {
          initramfs = self'.packages.initramfs-rv32-nommu;
        };

      # L-7: BFLT /init hello-world. Cross-compiles
      # firmware/phase2/init-rv32-nommu/init.S to a tiny BFLT
      # binary that the L-8 initramfs places at /init.
      init-rv32-nommu = pkgs.callPackage ./init-rv32-nommu/package.nix {};

      # Host-side JTAG-UART loader: spawns nios2-terminal,
      # writes kernel + DTB into its stdin pipe with a live
      # progress bar on stderr, then leaves nios2-terminal
      # attached so kernel printk streams to the user's shell.
      # Used by `nix run .#load-linux` and `.#load-sdram-jtag`.
      riski5-load-stream = pkgs.callPackage ./riski5-load-stream/package.nix {
        ghc = pkgs.haskellPackages.ghcWithPackages (ps: [ps.bytestring ps.process]);
      };

      # B-* (Boot ROM via Copilot eDSL): host-tool that emits
      # boot_rom_step.{c,h} from a Haskell stream specification.
      # See docs/boot-rom-copilot.md.
      riski5-boot-rom-gen =
        pkgs.callPackage ./riski5-boot-rom-gen/package.nix {
          ghc = pkgs.haskellPackages.ghcWithPackages (ps: [
            ps.copilot
            ps.copilot-c99
            ps.copilot-language
            ps.directory
            ps.filepath
          ]);
        };

      # B-* Boot ROM cross-compile pipeline: Copilot codegen →
      # riscv64-unknown-linux-gnu-gcc → objcopy → flat
      # binary. Output drives a future overlay of
      # firmware/phase1/LinuxBoot.hs once B-5 lands.
      riski5-boot-rom-rv32-nommu =
        pkgs.callPackage ./boot-rom-rv32-nommu/package.nix {
          inherit (self'.packages) riski5-boot-rom-gen;
        };

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

      # Flasher for the SDRAM-stress silicon test bitstream.
      flash-riski5-sdramstress = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-sdramstress;
      };

      # Flasher for the SDRAM-data-stress (BRAM exec) bisect.
      flash-riski5-sdramdatastress = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-sdramdatastress;
      };

      # Flasher for the high-SDRAM-stress bisect (#64 follow-up).
      flash-riski5-sdramhighstress = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-sdramhighstress;
      };

      # Flasher for the A-extension silicon test bitstream.
      flash-riski5-aexttest = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-aexttest;
      };

      # Flasher for the AMO-stress silicon test bitstream (task #29).
      flash-riski5-amostress = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-amostress;
      };

      # Flasher for the M-extension stress silicon test bitstream
      # (task #58 follow-up).
      flash-riski5-mdstress = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-mdstress;
      };

      # Flasher for the cooperative-context-switch stress bitstream
      # (task #64 follow-up).
      flash-riski5-schedstress = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-schedstress;
      };

      # Flasher for the LR/SC-stress silicon test bitstream (task #32).
      flash-riski5-lrscstress = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-lrscstress;
      };

      # Flasher for the stack-stress silicon test bitstream (task #33).
      flash-riski5-stackstress = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-stackstress;
      };

      # Flasher for the trap-during-stress silicon test bitstream (task #34).
      flash-riski5-trapstress = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-trapstress;
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

      # L-3b option A: minimal wait-for-go boot stub for the
      # JTAG-Master upload path. Pair with `nix run
      # .#load-sdram-master` for direct-to-SDRAM uploads bypassing
      # JTAG-UART.
      riski5-core-linux-master = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        linuxBootMaster = true;
      };
      flash-riski5-linux-master = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-linux-master;
      };

      # Task #58 silicon-debug variant: linux-master built with the
      # combinational MUL/DIV FU instead of the iterative 33-cycle
      # default. Used to test whether the post-BogoMIPS Linux silicon
      # hang is rooted in the iterative FSM (see TODO #58).
      riski5-core-linux-master-combmd = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        linuxBootMaster = true;
        combinationalMuldiv = true;
      };
      flash-riski5-linux-master-combmd = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-linux-master-combmd;
      };
      boot-linux-master-combmd = pkgs.callPackage ../apps/boot-linux-master.nix {
        inherit quartus-ii-13;
        inherit (self'.packages) linux-rv32-nommu riski5-dtb;
        riski5-core-linux-master = self'.packages.riski5-core-linux-master-combmd;
      };

      # Task #141 — slow-clock variants of every Linux-bringup
      # bitstream. The package builds at 30 MHz instead of 40 MHz
      # (PLL ratio 50×3/5) with the SDRAM IP regenerated for the
      # matching clockRate. Cheapest experiment for the SDRAM-IP
      # back-to-back-row-switch hypothesis: if Linux boots cleanly
      # with -slow but hangs without it, the IP is timing-bound at
      # 40 MHz and the multi-PLL split (separate clocks via async
      # FIFO) is justified. If both behave identically, the hang
      # is not chip- or IP-timing-bound.
      riski5-core-linux-master-slow = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        linuxBootMaster = true;
        slowClock = true;
      };
      flash-riski5-linux-master-slow = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-linux-master-slow;
      };
      boot-linux-master-slow = pkgs.callPackage ../apps/boot-linux-master.nix {
        inherit quartus-ii-13;
        inherit (self'.packages) linux-rv32-nommu riski5-dtb;
        riski5-core-linux-master = self'.packages.riski5-core-linux-master-slow;
      };

      # Task #36: 20 MHz silicon Linux test (verySlowClock=true).
      # One notch slower than slowClock — same single-clock-domain
      # mechanism, just multBy=2 → 50 × 2 / 5 = 20 MHz. Used to
      # check whether more timing margin alone gets Linux to boot
      # past the 30 MHz hang point right after sched_clock setup.
      riski5-core-linux-master-veryslow = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        linuxBootMaster = true;
        verySlowClock = true;
      };
      flash-riski5-linux-master-veryslow = pkgs.callPackage ../apps/flash-riski5.nix {
        inherit quartus-ii-13;
        riski5-core = self'.packages.riski5-core-linux-master-veryslow;
      };
      boot-linux-master-veryslow = pkgs.callPackage ../apps/boot-linux-master.nix {
        inherit quartus-ii-13;
        inherit (self'.packages) linux-rv32-nommu riski5-dtb;
        riski5-core-linux-master = self'.packages.riski5-core-linux-master-veryslow;
      };

      riski5-core-slow = pkgs.callPackage ./riski5-core/package.nix {
        inherit quartus-ii-13;
        slowClock = true;
      };

      # `nix run .#load-linux` — sends kernel + DTB to the
      # already-flashed linux-boot bitstream and attaches
      # nios2-terminal. With no args, uses the flake-built
      # kernel (linux-rv32-nommu) + DTB (riski5-dtb). Override
      # via `nix run .#load-linux -- kernel.bin dtb`.
      load-linux = pkgs.callPackage ../apps/load-linux.nix {
        inherit quartus-ii-13;
        inherit (self'.packages) riski5-load-stream linux-rv32-nommu riski5-dtb;
      };

      # `nix run .#boot-linux` — single-shot Linux silicon
      # bring-up: clears stale jtagd/nios2-terminal, flashes the
      # linuxBoot bitstream (FPGA reconfig = reset, replaces the
      # old "press KEY0" step), streams kernel + DTB, then
      # forwards keystrokes to the running kernel. Replaces the
      # flaky `flash-riski5-linux + load-linux` two-step.
      boot-linux = pkgs.callPackage ../apps/boot-linux.nix {
        inherit quartus-ii-13;
        inherit (self'.packages)
          riski5-core-linux
          riski5-load-stream
          linux-rv32-nommu
          riski5-dtb
          ;
      };

      # `nix run .#load-sdram-jtag -- <bin-path>` — host-side
      # counterpart to the L-3b SdramLoader bitstream. Sends a
      # length-prefixed binary blob via JTAG-UART; the on-board
      # firmware writes to SDRAM and JALRs. Generic loader for
      # the SdramLoader path (the Linux-specific equivalent is
      # `load-linux` above).
      load-sdram-jtag = pkgs.callPackage ../apps/load-sdram-jtag.nix {
        inherit quartus-ii-13;
        inherit (self'.packages) riski5-load-stream;
      };

      # `nix run .#load-sdram-master -- <bin> <base-hex>` —
      # direct-to-SDRAM upload via the JTAG-to-Avalon-Master bridge
      # IP (L-3b option A). Bypasses the JTAG-UART RX path entirely.
      # Expected throughput is the bridge IP's JTAG protocol rate
      # (~50-100 KB/s) vs. the JTAG-UART loader's ~1-2 KB/s on the
      # same USB-Blaster cable.
      load-sdram-master = pkgs.callPackage ../apps/load-sdram-master.nix {
        inherit quartus-ii-13;
      };

      # `nix run .#boot-linux-master` — single-shot Linux boot via
      # the JTAG-to-Avalon-Master path. Flashes the wait-for-go
      # boot stub, master_write_32's kernel + DTB into SDRAM, writes
      # the SRAM trigger, then opens nios2-terminal for the kernel
      # console. Faster alternative to `boot-linux` for cases where
      # the JTAG-UART loader's ~1-2 KB/s rate makes a 3.4 MB upload
      # impractical.
      boot-linux-master = pkgs.callPackage ../apps/boot-linux-master.nix {
        inherit quartus-ii-13;
        inherit (self'.packages) riski5-core-linux-master linux-rv32-nommu riski5-dtb;
      };

      console = pkgs.callPackage ../apps/console.nix {
        inherit quartus-ii-13;
      };

      # `nix run .#jam-counter-probe` — read JTAG-Avalon-Master
      # diagnostic counters via altsource_probe SLD (task #133).
      jam-counter-probe = pkgs.callPackage ../apps/jam-counter-probe.nix {
        inherit quartus-ii-13;
        inherit (pkgs) psmisc;
      };

      # `nix run .#sdram-state-probe` — read the SDRAM CDC bridge
      # state + IP signal probes (task #142, SDST + SDIO probes
      # added in commit c3500f1). Use after the silicon Linux hang
      # to learn whether the bridge or the IP is parked at the
      # moment the core stalls at PC=0x80000108.
      sdram-state-probe = pkgs.callPackage ../apps/sdram-state-probe.nix {
        inherit quartus-ii-13;
        inherit (pkgs) psmisc;
      };

      # `nix run .#sdram-write-pattern-test` — exercises the
      # JTAG-Master write path with known patterns and reports
      # PASS/FAIL per case (task #146). Catches the hi-half-word
      # write drop in seconds, no Linux boot needed.
      sdram-write-pattern-test = pkgs.callPackage ../apps/sdram-write-pattern-test.nix {
        inherit quartus-ii-13;
        inherit (pkgs) psmisc;
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
      flash-riski5-sdramstress = {
        type = "app";
        program = "${self'.packages.flash-riski5-sdramstress}/bin/flash-riski5";
      };
      flash-riski5-sdramdatastress = {
        type = "app";
        program = "${self'.packages.flash-riski5-sdramdatastress}/bin/flash-riski5";
      };
      flash-riski5-sdramhighstress = {
        type = "app";
        program = "${self'.packages.flash-riski5-sdramhighstress}/bin/flash-riski5";
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
      flash-riski5-linux-master = {
        type = "app";
        program = "${self'.packages.flash-riski5-linux-master}/bin/flash-riski5";
      };
      flash-riski5-linux-master-slow = {
        type = "app";
        program = "${self'.packages.flash-riski5-linux-master-slow}/bin/flash-riski5";
      };
      boot-linux-master-slow = {
        type = "app";
        program = "${self'.packages.boot-linux-master-slow}/bin/boot-linux-master";
      };
      load-linux = {
        type = "app";
        program = "${self'.packages.load-linux}/bin/load-linux";
      };
      boot-linux = {
        type = "app";
        program = "${self'.packages.boot-linux}/bin/boot-linux";
      };
      load-sdram-jtag = {
        type = "app";
        program = "${self'.packages.load-sdram-jtag}/bin/load-sdram-jtag";
      };
      load-sdram-master = {
        type = "app";
        program = "${self'.packages.load-sdram-master}/bin/load-sdram-master";
      };
      boot-linux-master = {
        type = "app";
        program = "${self'.packages.boot-linux-master}/bin/boot-linux-master";
      };
      console = {
        type = "app";
        program = "${self'.packages.console}/bin/console";
      };
      jam-counter-probe = {
        type = "app";
        program = "${self'.packages.jam-counter-probe}/bin/jam-counter-probe";
      };
      sdram-state-probe = {
        type = "app";
        program = "${self'.packages.sdram-state-probe}/bin/sdram-state-probe";
      };
      sdram-write-pattern-test = {
        type = "app";
        program = "${self'.packages.sdram-write-pattern-test}/bin/sdram-write-pattern-test";
      };
    };
  };
}
