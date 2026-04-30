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
  # At most one of @coremarkPkg != null@, @sramExec@, and
  # @sdramExec@ should be set at a time.
  sramExec ? false,
  # Build the SDRAM-execution debug variant. Same overlay
  # mechanism as @sramExec@: re-exports
  # @HelloSdramExec.helloSdramExecFirmwareWords@ as
  # @CoreMark.coreMarkFirmwareWords@, and flips
  # @FetchPolicy.enableSdramFetch@ to @True@ so the SoC routes
  # @pcFetch in SDRAM range@ through the 'Riski5.Sdram' adapter.
  # The probe firmware writes two encoded instructions into
  # SDRAM[0x80000000+], JALRs there, the SDRAM-resident @sw@
  # prints @S@ to the UART, the @ebreak@ traps back to BRAM[0],
  # and the firmware loops — yielding @BSBSBS…@ on the JTAG-UART
  # iff SDRAM execution works end-to-end.
  sdramExec ? false,
  # Build the A-extension silicon-test variant. Overlay
  # @HelloAExt.helloAExtFirmwareWords@ into the imem and exercise
  # the @Riski5.Core.FU.Amo@ FSM against an SRAM word — see the
  # module header for the @BLSAX BLSAX …@ UART script the host
  # should observe iff LR.W / SC.W / AMOSWAP.W / AMOADD.W all
  # work end-to-end on real silicon. Same overlay mechanism as
  # @sramExec@; @FetchPolicy@ stays at the BRAM-only default
  # because we only need to fetch from BRAM (just data accesses
  # touch SRAM via the AMO bus phases).
  aExtTest ? false,
  # Build the timer-interrupt silicon-test variant. Overlay
  # @HelloTimerIrq.helloTimerIrqFirmwareWords@ into the imem.
  # Expected silicon stream: @B......T......T…@ — boot byte,
  # then '.'-runs separated by handler-emitted 'T' bytes. Tests
  # the full CLINT → @mip.MTIP@ → @interruptPending@ → trap →
  # handler → @mret@ chain on real hardware.
  timerIrqTest ? false,
  # L-3b: build the JTAG-UART → SDRAM loader variant. Overlay
  # @SdramLoader.sdramLoaderFirmwareWords@ into the imem. Boot
  # firmware reads a length-prefixed binary blob from
  # JTAG-UART RX, writes it to @0x8000_0000+@, then JALRs to
  # @0x8000_0000@. Expected silicon stream: 'L' (loader ready)
  # + 'D' (load complete) + whatever the loaded program prints.
  # See @scripts/load-sdram-jtag.sh@ for the host-side workflow.
  sdramLoad ? false,
  # L-9: combined Linux loader + boot-stub. Like sdramLoad but
  # loads two blobs (kernel + DTB) and JALRs into @0x8000_0000@
  # with the standard RISC-V nommu boot ABI applied (a0=0,
  # a1=&dtb, sp=top of SRAM). Use @scripts/load-linux.sh@ to
  # send a kernel + DTB pair via JTAG-UART. After 'D' marker,
  # kernel printk output streams via the same JTAG-UART tap.
  linuxBoot ? false,
  # L-3b option A: minimal "wait-for-go" boot stub paired with the
  # JTAG-to-Avalon-Master upload path (commit 57a9d88). Boot ROM is
  # `firmware/phase1/LinuxBootMaster.hs` — ~12 instructions that
  # spin on SRAM[+4] until the host writes a non-zero sentinel,
  # then jump to 0x80000000 with a0=0, a1=0x80000000+kbytes,
  # sp=0x20080000. Used together with `nix run .#load-sdram-master`.
  linuxBootMaster ? false,
  # B-* (Copilot Boot ROM): the riski5-boot-rom-rv32-nommu
  # derivation. Required iff `linuxBoot = true`. Provides a
  # ready-made CoreMark.hs the linuxBoot variant drops into
  # firmware/phase1/CoreMark.hs (replacing the Asm-eDSL
  # LinuxBoot indirection with the Copilot-eDSL → C → RV32
  # path).
  bootRomCopilot ? null,
  # Task #141 — diagnostic: drop the entire design from 40 MHz down
  # to 30 MHz by changing the ALTPLL ratio from 50×4/5 to 50×3/5,
  # and regenerate the Altera SDRAM Controller IP with the matching
  # @clockRate=30000000@. Single clock domain, no CDC, no second
  # PLL. The motivating hypothesis (compaction notes 2026-04-30):
  # Linux silicon hangs at PC=0x80000108 immediately after an
  # @amoadd.w@ writes to a different SDRAM row from the next IF
  # fetch — the IP's back-to-back ACTIVATE/PRECHARGE/ACTIVATE may
  # need more wall-clock time per command. Slowing the entire
  # design uniformly tests that hypothesis without requiring a
  # CDC bridge between clock domains. If Linux boots cleanly with
  # @slowClock=true@, the timing hypothesis is confirmed and the
  # next step is the proper multi-PLL split (CPU @ 40 MHz, SDRAM
  # IP @ 30 MHz with async-FIFO Avalon-MM bridge between them).
  # Pname gets a @-slow@ suffix when this is enabled, so both
  # variants are buildable side-by-side for A/B comparison.
  slowClock ? false,
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
  isSdramExec = sdramExec && !isCoremark && !isSramExec;
  isAExtTest = aExtTest && !isCoremark && !isSramExec && !isSdramExec;
  isTimerIrqTest = timerIrqTest && !isCoremark && !isSramExec && !isSdramExec && !isAExtTest;
  isSdramLoad = sdramLoad && !isCoremark && !isSramExec && !isSdramExec && !isAExtTest && !isTimerIrqTest;
  isLinuxBoot = linuxBoot && !isCoremark && !isSramExec && !isSdramExec && !isAExtTest && !isTimerIrqTest && !isSdramLoad;
  isLinuxBootMaster = linuxBootMaster && !isCoremark && !isSramExec && !isSdramExec && !isAExtTest && !isTimerIrqTest && !isSdramLoad && !isLinuxBoot;
  # Task #141: multi-PLL clock topology — two physically separate
  # ALTPLLs driven by two different on-board clock pins, so the SDRAM
  # IP and the bus + core domain run on independent VCOs.
  #
  #   u_altpll        — bus + core domain (input: CLOCK_50, PIN_N2)
  #     clk0:  clkBus      40 MHz, 0°    (slowClock=true → 30 MHz)
  #     clk1:  clkCore     40 MHz, 0°    (separate counter from clkBus
  #                                        so a future commit can
  #                                        change just clk1's multiplier
  #                                        and clock the RISC-V core
  #                                        faster than the bus)
  #
  #   u_altpll_sdram  — SDRAM IP domain (input: CLOCK_27, PIN_D13,
  #                                        the DE2's on-board 27 MHz
  #                                        oscillator)
  #     clk0:  clkSdram     30 MHz, 0°   (input × 10/9)
  #     clk1:  clkSdramOut  30 MHz, -3 ns → DRAM_CLK pin
  #
  # Two different input pins because Cyclone II forbids one clock
  # input feeding more than one PLL (Quartus 13.0sp1 reports
  # "Error 172024: Input clock CLOCK_50 cannot feed more than one
  # PLL"). The user explicitly authorised a third pin too — that
  # would be EXT_CLOCK / SMA on the DE2 for a dedicated u_altpll_core
  # PLL, gating on whether an external clock generator is connected.
  # Without that hardware, clkCore stays on u_altpll's clk1 counter
  # (still independently tunable, just sharing a VCO with clkBus).
  #
  # The Clash riski5 module currently runs entirely on clkBus
  # (CLOCK_BUS / RESET_BUS_N input ports). The SDRAM IP runs on
  # clkSdram with a Verilog-side toggle-handshake CDC bridge
  # (riski5_sdram_cdc_bridge) at the 16-bit Avalon-MM boundary.
  pllBusMultBy = if slowClock then 3 else 4;  # bus, core: 50 × M / 5
  pllCoreMultBy = if slowClock then 3 else 4; # tied to bus initially
  # SDRAM: input is 27 MHz (CLOCK_27), output 30 MHz, ratio 10/9.
  pllSdramMultBy = 10;
  pllSdramDivBy  = 9;
  sdramIpClockRate = 30000000;                # always 30 MHz under multi-PLL
  slowSuffix = lib.optionalString slowClock "-slow";
in
  stdenv.mkDerivation {
    pname =
      (if isCoremark then "riski5-core-coremark"
      else if isSramExec then "riski5-core-sramexec"
      else if isSdramExec then "riski5-core-sdramexec"
      else if isAExtTest then "riski5-core-aexttest"
      else if isTimerIrqTest then "riski5-core-timerirqtest"
      else if isSdramLoad then "riski5-core-sdramload"
      else if isLinuxBoot then "riski5-core-linux"
      else if isLinuxBootMaster then "riski5-core-linux-master"
      else "riski5-core") + slowSuffix;
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
              # @enableSdramFetch = False@ keeps the SDRAM block on the
              # data-only pass-through path so the only structural change
              # vs the CoreMark variant is the SRAM-fetch arbiter.
              cat > firmware/phase1/FetchPolicy.hs <<'EOF'
              -- SPDX-FileCopyrightText: 2026 Mika Tammi
              -- SPDX-License-Identifier: MIT OR BSD-3-Clause
              --
              -- Overlaid by the sramExec Nix build: turns on the
              -- fetch-side SRAM routing inside Riski5.Soc.soc so the
              -- probe firmware can execute from 0x2000_0000+.
              module FetchPolicy (
                enableSramFetch,
                enableSdramFetch,
              ) where

              import Prelude (Bool (..))

              enableSramFetch :: Bool
              enableSramFetch = True

              enableSdramFetch :: Bool
              enableSdramFetch = False
              EOF
              sed -i 's/^              //' firmware/phase1/FetchPolicy.hs
              echo "### sramExec variant: overlaid firmware/phase1/FetchPolicy.hs"
              cat firmware/phase1/FetchPolicy.hs
            ''}

            ${lib.optionalString isSdramExec ''
              # SDRAM-execution debug variant: overlay CoreMark.hs with a
              # re-export of HelloSdramExec.helloSdramExecFirmwareWords,
              # and flip FetchPolicy.enableSdramFetch = True so
              # Riski5.Soc.soc routes @pcFetch in SDRAM range@ to the
              # 32 ↔ 16 'Riski5.Sdram' adapter (which fronts the Altera
              # @altera_avalon_new_sdram_controller@ IP, the same IP
              # that already serves SDRAM data accesses today).
              # Same overlay mechanism as sramExec — keeps Top.hs
              # bit-identical across variants for Quartus-placement
              # stability (see docs/perf/sram-exec-probe-2026-04-24.md
              # for the original rationale).
              chmod -R u+w firmware/phase1
              cat > firmware/phase1/CoreMark.hs <<'EOF'
              -- SPDX-FileCopyrightText: 2026 Mika Tammi
              -- SPDX-License-Identifier: MIT OR BSD-3-Clause
              --
              -- Overlaid by the sdramExec Nix build: re-exports
              -- HelloSdramExec's firmware under the CoreMark name so
              -- the unchanged -DFIRMWARE_COREMARK path in app/Top.hs
              -- bakes the SDRAM-exec probe into imem.
              {-# LANGUAGE DataKinds #-}
              {-# LANGUAGE NoStarIsType #-}

              module CoreMark (
                coreMarkFirmwareWords,
              ) where

              import Clash.Prelude (BitVector)
              import HelloSdramExec (helloSdramExecFirmwareWords)

              coreMarkFirmwareWords :: [BitVector 32]
              coreMarkFirmwareWords = helloSdramExecFirmwareWords
              EOF
              sed -i 's/^              //' firmware/phase1/CoreMark.hs
              echo "### sdramExec variant: overlaid firmware/phase1/CoreMark.hs"
              cat firmware/phase1/CoreMark.hs

              cat > firmware/phase1/FetchPolicy.hs <<'EOF'
              -- SPDX-FileCopyrightText: 2026 Mika Tammi
              -- SPDX-License-Identifier: MIT OR BSD-3-Clause
              --
              -- Overlaid by the sdramExec Nix build: turns on the
              -- fetch-side SDRAM routing inside Riski5.Soc.soc so the
              -- probe firmware can execute from 0x8000_0000+.
              module FetchPolicy (
                enableSramFetch,
                enableSdramFetch,
              ) where

              import Prelude (Bool (..))

              enableSramFetch :: Bool
              enableSramFetch = False

              enableSdramFetch :: Bool
              enableSdramFetch = True
              EOF
              sed -i 's/^              //' firmware/phase1/FetchPolicy.hs
              echo "### sdramExec variant: overlaid firmware/phase1/FetchPolicy.hs"
              cat firmware/phase1/FetchPolicy.hs
            ''}

            ${lib.optionalString isAExtTest ''
              # A-extension silicon test variant. Overlay CoreMark.hs
              # with HelloAExt's words; FetchPolicy stays at the
              # BRAM-only default (only data accesses touch SRAM, not
              # fetches).
              chmod -R u+w firmware/phase1
              cat > firmware/phase1/CoreMark.hs <<'EOF'
              -- SPDX-FileCopyrightText: 2026 Mika Tammi
              -- SPDX-License-Identifier: MIT OR BSD-3-Clause
              --
              -- Overlaid by the aExtTest Nix build: re-exports
              -- HelloAExt's firmware under the CoreMark name so the
              -- unchanged -DFIRMWARE_COREMARK path in app/Top.hs
              -- bakes the A-extension probe into imem.
              {-# LANGUAGE DataKinds #-}
              {-# LANGUAGE NoStarIsType #-}

              module CoreMark (
                coreMarkFirmwareWords,
              ) where

              import Clash.Prelude (BitVector)
              import HelloAExt (helloAExtFirmwareWords)

              coreMarkFirmwareWords :: [BitVector 32]
              coreMarkFirmwareWords = helloAExtFirmwareWords
              EOF
              sed -i 's/^              //' firmware/phase1/CoreMark.hs
              echo "### aExtTest variant: overlaid firmware/phase1/CoreMark.hs"
              cat firmware/phase1/CoreMark.hs
            ''}

            ${lib.optionalString isTimerIrqTest ''
              # Timer-interrupt silicon test variant. Overlay
              # CoreMark.hs with HelloTimerIrq's words; FetchPolicy
              # stays at the BRAM-only default.
              chmod -R u+w firmware/phase1
              cat > firmware/phase1/CoreMark.hs <<'EOF'
              -- SPDX-FileCopyrightText: 2026 Mika Tammi
              -- SPDX-License-Identifier: MIT OR BSD-3-Clause
              --
              -- Overlaid by the timerIrqTest Nix build: re-exports
              -- HelloTimerIrq's firmware under the CoreMark name so
              -- the unchanged -DFIRMWARE_COREMARK path in app/Top.hs
              -- bakes the timer-interrupt probe into imem.
              {-# LANGUAGE DataKinds #-}
              {-# LANGUAGE NoStarIsType #-}

              module CoreMark (
                coreMarkFirmwareWords,
              ) where

              import Clash.Prelude (BitVector)
              import HelloTimerIrq (helloTimerIrqFirmwareWords)

              coreMarkFirmwareWords :: [BitVector 32]
              coreMarkFirmwareWords = helloTimerIrqFirmwareWords
              EOF
              sed -i 's/^              //' firmware/phase1/CoreMark.hs
              echo "### timerIrqTest variant: overlaid firmware/phase1/CoreMark.hs"
              cat firmware/phase1/CoreMark.hs
            ''}

            ${lib.optionalString isSdramLoad ''
              # L-3b SDRAM-load variant. Overlay CoreMark.hs with
              # SdramLoader's words; FetchPolicy stays at the BRAM-only
              # default (the loader executes from BRAM and only writes
              # to SDRAM via data accesses, so enableSdramFetch=False
              # is correct).
              chmod -R u+w firmware/phase1
              cat > firmware/phase1/CoreMark.hs <<'EOF'
              -- SPDX-FileCopyrightText: 2026 Mika Tammi
              -- SPDX-License-Identifier: MIT OR BSD-3-Clause
              --
              -- Overlaid by the sdramLoad Nix build: re-exports
              -- SdramLoader's firmware under the CoreMark name so
              -- the unchanged -DFIRMWARE_COREMARK path in app/Top.hs
              -- bakes the JTAG-UART → SDRAM loader into imem.
              {-# LANGUAGE DataKinds #-}
              {-# LANGUAGE NoStarIsType #-}

              module CoreMark (
                coreMarkFirmwareWords,
              ) where

              import Clash.Prelude (BitVector)
              import SdramLoader (sdramLoaderFirmwareWords)

              coreMarkFirmwareWords :: [BitVector 32]
              coreMarkFirmwareWords = sdramLoaderFirmwareWords
              EOF
              sed -i 's/^              //' firmware/phase1/CoreMark.hs
              echo "### sdramLoad variant: overlaid firmware/phase1/CoreMark.hs"
              cat firmware/phase1/CoreMark.hs
            ''}

            ${lib.optionalString isLinuxBoot ''
              # L-9 Linux-boot variant — Copilot-eDSL boot ROM.
              # The riski5-boot-rom-rv32-nommu derivation ran the
              # full Copilot → C → RV32 pipeline and emitted a
              # ready-made CoreMark.hs containing the boot ROM as
              # a [BitVector 32] literal. Drop it straight into
              # firmware/phase1/CoreMark.hs — same overlay slot
              # every other variant uses, keeps Quartus
              # placement stable, no Clash callsite changes.
              chmod -R u+w firmware/phase1
              cp ${
                if bootRomCopilot == null
                then throw "linuxBoot=true requires bootRomCopilot ≠ null"
                else "${bootRomCopilot}/CoreMark.hs"
              } firmware/phase1/CoreMark.hs
              echo "### linuxBoot variant: copied Copilot-built CoreMark.hs"
              echo "### (head)"
              head -10 firmware/phase1/CoreMark.hs
              echo "### word count"
              grep -c "^  ," firmware/phase1/CoreMark.hs
            ''}

            ${lib.optionalString isLinuxBootMaster ''
              # L-3b option A: minimal "wait-for-go" boot stub paired
              # with the JTAG-to-Avalon-Master upload path. Boot ROM
              # comes from firmware/phase1/LinuxBootMaster.hs — same
              # CoreMark.hs overlay mechanism every variant uses, but
              # we re-export `linuxBootMasterFirmwareWords` under the
              # `coreMarkFirmwareWords` name so app/Top.hs's existing
              # -DFIRMWARE_COREMARK code path bakes it into imem.
              chmod -R u+w firmware/phase1
              cat > firmware/phase1/CoreMark.hs <<'EOF'
              -- SPDX-FileCopyrightText: 2026 Mika Tammi
              -- SPDX-License-Identifier: MIT OR BSD-3-Clause
              --
              -- Overlaid by the linuxBootMaster Nix build: re-exports
              -- LinuxBootMaster's wait-for-go stub under the CoreMark
              -- name so the unchanged -DFIRMWARE_COREMARK path in
              -- app/Top.hs bakes the L-3b-option-A bootloader into
              -- imem.
              {-# LANGUAGE DataKinds #-}
              {-# LANGUAGE NoStarIsType #-}

              module CoreMark (
                coreMarkFirmwareWords,
              ) where

              import LinuxBootMaster (linuxBootMasterFirmwareWords)
              import Clash.Prelude (BitVector)

              coreMarkFirmwareWords :: [BitVector 32]
              coreMarkFirmwareWords = linuxBootMasterFirmwareWords
              EOF
              sed -i 's/^              //' firmware/phase1/CoreMark.hs
              echo "### linuxBootMaster variant: overlaid firmware/phase1/CoreMark.hs"
              cat firmware/phase1/CoreMark.hs

              # The kernel image lives in SDRAM at 0x8000_0000. After
              # the boot stub JRs there the core's IF stage must fetch
              # from SDRAM, so flip enableSdramFetch=True (the
              # committed default is False, which leaves kernel fetches
              # wrapping back into BRAM and immediately re-running the
              # boot stub — the cause of the original MBMBMB symptom).
              cat > firmware/phase1/FetchPolicy.hs <<'EOF'
              -- SPDX-FileCopyrightText: 2026 Mika Tammi
              -- SPDX-License-Identifier: MIT OR BSD-3-Clause
              --
              -- Overlaid by the linuxBootMaster Nix build: turns on
              -- SDRAM fetch routing in Riski5.Soc.soc so that, after
              -- LinuxBootMaster's boot stub JRs to 0x8000_0000, the
              -- core's IF stage reaches the kernel image in SDRAM
              -- instead of wrapping back into the BRAM-resident stub.
              module FetchPolicy (
                enableSramFetch,
                enableSdramFetch,
              ) where

              import Prelude (Bool (..))

              enableSramFetch :: Bool
              enableSramFetch = False

              enableSdramFetch :: Bool
              enableSdramFetch = True
              EOF
              sed -i 's/^              //' firmware/phase1/FetchPolicy.hs
              echo "### linuxBootMaster variant: overlaid firmware/phase1/FetchPolicy.hs"
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
              ${lib.optionalString (isCoremark || isSramExec || isSdramExec || isAExtTest || isTimerIrqTest || isSdramLoad || isLinuxBoot || isLinuxBootMaster) "-DFIRMWARE_COREMARK"} \
              -isrc -iapp -ifirmware/phase1 \
              Top

            # Compile our Clash JTAG-Avalon-Master replacement
            # (Riski5.JtagAvalonMaster, task #133). The output module
            # `riski5_jtag_avalon_master` is wrapped under the original
            # Altera name `altera_avalon_packets_to_master` by the
            # hand-rolled shim at altera-ip/jtag-master-shim/. The
            # composition wrapper from `ip-generate altera_jtag_avalon_master`
            # below sees the Altera-named module as before; the buggy
            # Altera state machine is silently swapped out.
            clash --verilog -fclash-hdlsyn Quartus \
              -XGHC2021 -XImplicitPrelude \
              -isrc \
              Riski5.JtagAvalonMaster

            # Quartus expects Riski5.qpf / Riski5.qsf / Riski5.sdc at the
            # build root. The .qsf references verilog/Top.topEntity/riski5.v
            # as its source file — matching what Clash just produced.
            cp pkgs/riski5-core/Riski5.qpf .
            cp pkgs/riski5-core/Riski5.qsf .
            cp pkgs/riski5-core/Riski5.sdc .

            # Register the Clash JTAG-Avalon-Master replacement Verilog
            # so Quartus picks it up alongside the main `riski5` core.
            echo 'set_global_assignment -name VERILOG_FILE "verilog/Riski5.JtagAvalonMaster.topEntity/riski5_jtag_avalon_master.v"' >> Riski5.qsf
            # And the thin shim that re-exports it under the Altera-IP
            # module name (`altera_avalon_packets_to_master`), so the
            # `ip-generate altera_jtag_avalon_master` composition wrapper
            # below can instantiate it without any change.
            mkdir -p altera-ip/jtag-master-shim
            cp pkgs/riski5-core/altera-ip/jtag-master-shim/altera_avalon_packets_to_master.v \
               altera-ip/jtag-master-shim/altera_avalon_packets_to_master.v
            echo 'set_global_assignment -name VERILOG_FILE "altera-ip/jtag-master-shim/altera_avalon_packets_to_master.v"' >> Riski5.qsf

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
            # DE2's chip and the 30 MHz @clkSdram@ clock, leaving
            # generous margin:
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
            #   clockRate        = 30_000_000 Hz (matches @clkSdram@ —
            #                       the SDRAM IP runs in its own clock
            #                       domain at 30 MHz under the multi-PLL
            #                       topology, with a Verilog-side
            #                       toggle-handshake CDC bridge between
            #                       the Clash adapter (clkBus) and the
            #                       IP slave port; see task #141)
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
              --component-parameter=clockRate=${toString sdramIpClockRate} \
              --component-parameter=size=8388608 \
              --component-parameter=addressWidth=22 \
              --component-parameter=bankWidth=2 \
              --component-parameter=generateSimulationModel=false \
              --component-parameter=pinsSharedViaTriState=false \
              --component-parameter=registerDataIn=true \
              --component-parameter=model=custom
            echo 'set_global_assignment -name VERILOG_FILE "altera-ip/sdram/riski5_sdram.v"' >> Riski5.qsf

            # Generate Altera's JTAG-to-Avalon-Master bridge IP (L-3 design
            # option A, deferred when L-3b chose option B / firmware loader).
            # This is the IP that drives the L-3a `JTAG_LOAD_*` inputs of the
            # Clash module so a host-side `master_write_32` Tcl command (via
            # `quartus_stp`) writes 32-bit words straight into SDRAM via the
            # SoC's bus mux. Bypasses the JTAG-UART RX path entirely —
            # expected ~50-100 KB/s vs. the ~1-2 KB/s the JTAG-UART loader
            # achieves on this rig (see docs/perf/jtag-uart-link-2026-04-28.md).
            #
            # FIFO_DEPTHS=2 is the IP default; the bridge uses internal
            # streaming FIFOs to absorb JTAG-side bursts. FAST_VER is left
            # off (experimental status in the IP's _hw.tcl).
            mkdir -p altera-ip/jtag-master
            ip-generate \
              --component-file=${quartus-ii-13}/share/altera13.0sp1/ip/altera/sopc_builder_ip/altera_jtag_avalon_master/altera_jtag_avalon_master_hw.tcl \
              --output-directory=altera-ip/jtag-master \
              --output-name=riski5_jtag_master \
              --file-set=QUARTUS_SYNTH \
              --language=VERILOG \
              --system-info=DEVICE_FAMILY=CYCLONEII \
              --system-info=DEVICE=EP2C35F672C6 \
              --component-parameter=USE_PLI=0 \
              --component-parameter=FAST_VER=1 \
              --component-parameter=FIFO_DEPTHS=64
            # Pull all Verilog files the bridge IP emits — it composes
            # several sub-modules, each in its own file under submodules/.
            #
            # EXCEPT: skip altera_avalon_packets_to_master.v — that's
            # the buggy state machine task #133 replaces with our
            # Clash module (compiled above; included via the shim).
            # If we let Quartus see both, the linker would complain
            # about duplicate `module altera_avalon_packets_to_master`.
            for f in altera-ip/jtag-master/riski5_jtag_master.v \
                     altera-ip/jtag-master/submodules/*.v; do
              case "$(basename "$f")" in
                altera_avalon_packets_to_master.v) continue ;;
              esac
              echo "set_global_assignment -name VERILOG_FILE \"$f\"" >> Riski5.qsf
            done

            # Bidirectional pin wrapper + external ALTPLLs + Altera
            # JTAG UART + Altera SDRAM Controller IP + Verilog CDC
            # bridge. The Clash top takes clkBus / rstBus_n as inputs
            # (rather than owning altpllSync internally) so this
            # wrapper owns the two PLLs (bus + SDRAM domains) and
            # bridges Avalon-MM traffic into the SDRAM IP across the
            # clock-domain boundary.
            mkdir -p verilog/riski5_top
            cat > verilog/riski5_top/riski5_top.v <<'EOF'
      // SPDX-License-Identifier: MIT OR BSD-3-Clause
      //
      // Top-level wrapper around the Clash-emitted `riski5` module.
      //
      // Responsibilities:
      //   1. Derive three independent clocks (clkBus 40 MHz, clkCore
      //      40 MHz, clkSdram 30 MHz + clkSdramOut at -3 ns) from the
      //      on-board 50 MHz CLOCK_50 via two altpll megafunctions.
      //   2. Build rstBus_n = KEY[0] & both-PLLs-locked, plus a 2-FF
      //      reset synchroniser into the clkSdram domain so all
      //      domains see clean reset deassertion.
      //   3. Resolve the bidirectional SRAM_DQ bus from the core's
      //      SRAM_DQ_{O,OE,I} triplet.
      //   4. Instantiate the Altera altera_avalon_jtag_uart IP
      //      (module `riski5_jtag_uart`, produced by ip-generate earlier
      //      in this buildPhase) and bridge our 5-signal UART bus into
      //      its Avalon-MM slave interface.
      //
      // The JTAG UART rides the USB-Blaster JTAG tap — no external pins.

      // ═══════════════════════════════════════════════════════════════
      //  riski5_sdram_cdc_bridge
      //
      //  Toggle-handshake clock-domain-crossing bridge between the
      //  Clash module's clkBus-domain SDRAM master signals and the
      //  Altera SDRAM Controller IP's clkSdram-domain Avalon-MM slave
      //  port. Generic 16-bit Avalon-MM slave bridge — addr 22 bits,
      //  wdata/rdata 16 bits, byteenable 2 bits.
      //
      //  Master-side state machine (clkBus, posedge clkBus):
      //    M_IDLE:    waiting for m_cs.
      //               m_waitrequest = 0 (free for new request).
      //               When m_cs goes high, latch addr/wdata/be/rd/wr,
      //               toggle req_toggle_bus, transition to M_BUSY.
      //    M_BUSY:    waiting for slave-side done_toggle.
      //               m_waitrequest = 1 (master holds inputs stable).
      //               When done_edge_bus fires, capture cap_rdata into
      //               m_rdata, transition to M_DONE_W (writes) or
      //               M_DONE_R (reads).
      //    M_DONE_W:  m_waitrequest = 0 (master advances next cycle).
      //               Transition back to M_IDLE.
      //    M_DONE_R:  m_waitrequest = 0 (adapter SReadLoReq → SReadLoWait
      //               next cycle), schedule m_valid pulse for next cycle
      //               so the adapter (now in SReadLoWait) captures rdata.
      //               Transition back to M_IDLE.
      //
      //  Slave-side state machine (clkSdram, posedge clkSdram):
      //    S_IDLE:        waiting for req_edge from master toggle sync.
      //                   On edge, sample m_lat_* into s_lat_*_buf,
      //                   transition to S_REQ.
      //    S_REQ:         drive IP slave port from s_lat_*_buf.
      //                   When IP drops s_waitrequest, transition to
      //                   S_AWAIT_VALID (reads) or S_DONE (writes).
      //    S_AWAIT_VALID: wait for IP's s_valid pulse, capture s_rdata
      //                   into cap_rdata_sdram. Transition to S_DONE.
      //    S_DONE:        toggle done_toggle_sdram so master sees the
      //                   completion. Transition back to S_IDLE.
      //
      //  Cross-domain signals (sampled across the boundary while the
      //  source side holds them stable, so set_false_path applies in
      //  STA — the SDC adds the necessary constraints):
      //    m_lat_*    (clkBus → clkSdram)  — request payload
      //    cap_rdata_sdram (clkSdram → clkBus) — read response payload
      //    req_toggle_bus  (clkBus → clkSdram) — through 2-FF synchroniser
      //    done_toggle_sdram (clkSdram → clkBus) — through 2-FF synchroniser
      // ═══════════════════════════════════════════════════════════════
      module riski5_sdram_cdc_bridge (
          // Master side (clkBus domain)
          input  wire        clkBus,
          input  wire        rstBus_n,
          input  wire        m_cs,
          input  wire [21:0] m_addr,
          input  wire [15:0] m_wdata,
          input  wire [1:0]  m_be,
          input  wire        m_rd,
          input  wire        m_wr,
          output reg  [15:0] m_rdata,
          output reg         m_valid,
          output wire        m_waitrequest,

          // Slave side (clkSdram domain) — drives the IP's az_* port
          input  wire        clkSdram,
          input  wire        rstSdram_n,
          output wire        s_cs,
          output wire [21:0] s_addr,
          output wire [15:0] s_wdata,
          output wire [1:0]  s_be,
          output wire        s_rd,
          output wire        s_wr,
          input  wire [15:0] s_rdata,
          input  wire        s_valid,
          input  wire        s_waitrequest
      );

          // ─── Master-side state ────────────────────────────────────
          localparam [1:0] M_IDLE    = 2'd0;
          localparam [1:0] M_BUSY    = 2'd1;
          localparam [1:0] M_DONE_W  = 2'd2;
          localparam [1:0] M_DONE_R  = 2'd3;

          reg [1:0]  m_state;
          reg [21:0] m_lat_addr;
          reg [15:0] m_lat_wdata;
          reg [1:0]  m_lat_be;
          reg        m_lat_rd;
          reg        m_lat_wr;
          reg        req_toggle_bus;
          reg        done_sync_0, done_sync_1, done_prev_bus;
          wire       done_edge_bus = done_sync_1 ^ done_prev_bus;
          reg [15:0] cap_rdata_sync_0, cap_rdata_sync_1;

          // ─── Slave-side state (forward declared for cross-refs) ──
          reg        done_toggle_sdram;
          reg [15:0] cap_rdata_sdram;

          always @(posedge clkBus or negedge rstBus_n) begin
              if (!rstBus_n) begin
                  m_state <= M_IDLE;
                  m_lat_addr <= 22'b0;
                  m_lat_wdata <= 16'b0;
                  m_lat_be <= 2'b0;
                  m_lat_rd <= 1'b0;
                  m_lat_wr <= 1'b0;
                  req_toggle_bus <= 1'b0;
                  done_sync_0 <= 1'b0;
                  done_sync_1 <= 1'b0;
                  done_prev_bus <= 1'b0;
                  cap_rdata_sync_0 <= 16'b0;
                  cap_rdata_sync_1 <= 16'b0;
                  m_rdata <= 16'b0;
                  m_valid <= 1'b0;
              end else begin
                  // 2-FF synchronise done toggle from clkSdram
                  done_sync_0 <= done_toggle_sdram;
                  done_sync_1 <= done_sync_0;
                  done_prev_bus <= done_sync_1;

                  // 2-FF sample cap_rdata from clkSdram. Only meaningful
                  // when done_edge fires; otherwise it just tracks the
                  // last completed read.
                  cap_rdata_sync_0 <= cap_rdata_sdram;
                  cap_rdata_sync_1 <= cap_rdata_sync_0;

                  // Default: no valid pulse this cycle.
                  m_valid <= 1'b0;

                  case (m_state)
                      M_IDLE: begin
                          if (m_cs) begin
                              m_lat_addr <= m_addr;
                              m_lat_wdata <= m_wdata;
                              m_lat_be <= m_be;
                              m_lat_rd <= m_rd;
                              m_lat_wr <= m_wr;
                              req_toggle_bus <= ~req_toggle_bus;
                              m_state <= M_BUSY;
                          end
                      end
                      M_BUSY: begin
                          if (done_edge_bus) begin
                              if (m_lat_rd) begin
                                  m_rdata <= cap_rdata_sync_1;
                                  m_state <= M_DONE_R;
                              end else begin
                                  m_state <= M_DONE_W;
                              end
                          end
                      end
                      M_DONE_W: begin
                          // Drop waitrequest this cycle; back to idle.
                          m_state <= M_IDLE;
                      end
                      M_DONE_R: begin
                          // waitrequest already dropped this cycle (state
                          // is M_DONE_R, not M_BUSY). The adapter sees
                          // waitrequest=0 and advances to SReadLoWait.
                          // Pulse m_valid in the NEXT cycle (registered),
                          // when adapter is in SReadLoWait and ready to
                          // capture rdata.
                          m_valid <= 1'b1;
                          m_state <= M_IDLE;
                      end
                      default: m_state <= M_IDLE;
                  endcase
              end
          end

          // m_waitrequest is high while a transaction is in flight.
          // Drops in M_DONE_W / M_DONE_R for one cycle so the adapter
          // advances; back to high when M_IDLE if no new cs comes.
          assign m_waitrequest = (m_state == M_BUSY);

          // ─── Slave-side state machine ─────────────────────────────
          localparam [1:0] S_IDLE        = 2'd0;
          localparam [1:0] S_REQ         = 2'd1;
          localparam [1:0] S_AWAIT_VALID = 2'd2;
          localparam [1:0] S_DONE        = 2'd3;

          reg [1:0]  s_state;
          reg        req_sync_0_sdr, req_sync_1_sdr, req_prev_sdr;
          wire       req_edge_sdr = req_sync_1_sdr ^ req_prev_sdr;
          reg [21:0] s_lat_addr_buf;
          reg [15:0] s_lat_wdata_buf;
          reg [1:0]  s_lat_be_buf;
          reg        s_lat_rd_buf;
          reg        s_lat_wr_buf;

          always @(posedge clkSdram or negedge rstSdram_n) begin
              if (!rstSdram_n) begin
                  s_state <= S_IDLE;
                  req_sync_0_sdr <= 1'b0;
                  req_sync_1_sdr <= 1'b0;
                  req_prev_sdr <= 1'b0;
                  done_toggle_sdram <= 1'b0;
                  cap_rdata_sdram <= 16'b0;
                  s_lat_addr_buf <= 22'b0;
                  s_lat_wdata_buf <= 16'b0;
                  s_lat_be_buf <= 2'b0;
                  s_lat_rd_buf <= 1'b0;
                  s_lat_wr_buf <= 1'b0;
              end else begin
                  // 2-FF synchronise req toggle from clkBus
                  req_sync_0_sdr <= req_toggle_bus;
                  req_sync_1_sdr <= req_sync_0_sdr;
                  req_prev_sdr <= req_sync_1_sdr;

                  case (s_state)
                      S_IDLE: begin
                          if (req_edge_sdr) begin
                              // Sample latched signals from master domain.
                              // Stable because master holds them in M_BUSY.
                              s_lat_addr_buf <= m_lat_addr;
                              s_lat_wdata_buf <= m_lat_wdata;
                              s_lat_be_buf <= m_lat_be;
                              s_lat_rd_buf <= m_lat_rd;
                              s_lat_wr_buf <= m_lat_wr;
                              s_state <= S_REQ;
                          end
                      end
                      S_REQ: begin
                          // Drive IP. Wait for !waitrequest to advance.
                          if (!s_waitrequest) begin
                              if (s_lat_rd_buf) begin
                                  s_state <= S_AWAIT_VALID;
                              end else begin
                                  s_state <= S_DONE;
                              end
                          end
                      end
                      S_AWAIT_VALID: begin
                          if (s_valid) begin
                              cap_rdata_sdram <= s_rdata;
                              s_state <= S_DONE;
                          end
                      end
                      S_DONE: begin
                          done_toggle_sdram <= ~done_toggle_sdram;
                          s_state <= S_IDLE;
                      end
                      default: s_state <= S_IDLE;
                  endcase
              end
          end

          // Drive IP slave port combinationally from the latched-and-
          // held registers when in S_REQ. Outside S_REQ the strobes
          // (cs / rd / wr) go inactive so the IP sees a clean idle
          // between transactions; address / wdata / be can keep their
          // last value (the IP only samples them on cs+!waitrequest).
          assign s_cs    = (s_state == S_REQ);
          assign s_addr  = s_lat_addr_buf;
          assign s_wdata = s_lat_wdata_buf;
          assign s_be    = s_lat_be_buf;
          assign s_rd    = (s_state == S_REQ) & s_lat_rd_buf;
          assign s_wr    = (s_state == S_REQ) & s_lat_wr_buf;

      endmodule

      module riski5_top (
          input  wire        CLOCK_50,
          input  wire        CLOCK_27,
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

        // ----- Multi-PLL clock topology (task #141) ------------------
        // CLOCK_50 (50 MHz off-chip osc) → two ALTPLLs producing four
        // independent clock outputs across three logical clock domains:
        //
        //   u_altpll       (bus + core)
        //     clk0  clkBus      40 MHz, 0°   — Avalon-MM bus, peripherals,
        //                                       JTAG-UART, JTAG-Master,
        //                                       Clash riski5 module
        //     clk1  clkCore     40 MHz, 0°   — RISC-V core domain.
        //                                       Currently tied electrically
        //                                       to clkBus (Clash core+bus
        //                                       refactor is a follow-up
        //                                       commit). The PLL output
        //                                       is generated separately
        //                                       so a future change to
        //                                       clk1_multiply_by alone
        //                                       can clock the core faster
        //                                       than the bus without
        //                                       rewiring this file.
        //
        //   u_altpll_sdram (SDRAM IP)
        //     clk0  clkSdram     30 MHz, 0°  — Altera SDRAM Controller
        //                                       IP slave clock
        //     clk1  clkSdramOut  30 MHz, -3 ns → DRAM_CLK pin (chip
        //                                       samples 3 ns after the
        //                                       FPGA-side IP drives
        //                                       signals; standard Altera
        //                                       deployment pattern, was
        //                                       task #132's fix)
        //
        // The Clash riski5 module input ports are CLOCK_BUS / RESET_BUS_N
        // (renamed from the previous CLOCK_SYS / RESET_SYS_N). Cross-
        // domain Avalon-MM traffic to the SDRAM IP goes through the
        // riski5_sdram_cdc_bridge module defined further below (toggle
        // handshake on req/done flags + 2-FF synchronizers + stable
        // latched signals across the boundary).
        //
        // The slowClock=true Nix flag drops the bus + core PLL outputs
        // from 40 MHz to 30 MHz; the SDRAM PLL stays at 30 MHz. All
        // three clocks then run at the same nominal frequency from
        // independent PLLs (still independent CDC paths, since the
        // PLLs free-run from the same crystal but with no defined
        // phase relationship between u_altpll and u_altpll_sdram).
        wire [4:0] altpll_clk_vec;
        wire [4:0] altpll_sdram_clk_vec;
        wire       clkBus       = altpll_clk_vec[0];
        wire       clkCore      = altpll_clk_vec[1];
        wire       clkSdram     = altpll_sdram_clk_vec[0];
        wire       clkSdramOut  = altpll_sdram_clk_vec[1];
        wire       pll_bus_locked;
        wire       pll_sdram_locked;
        altpll u_altpll (
            .areset (1'b0),
            .inclk  ({1'b0, CLOCK_50}),
            .clk    (altpll_clk_vec),
            .locked (pll_bus_locked),
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
        defparam u_altpll.bandwidth_type         = "AUTO";
        defparam u_altpll.clk0_divide_by         = 5;
        defparam u_altpll.clk0_duty_cycle        = 50;
        defparam u_altpll.clk0_multiply_by       = ${toString pllBusMultBy};
        defparam u_altpll.clk0_phase_shift       = "0";
        defparam u_altpll.clk1_divide_by         = 5;
        defparam u_altpll.clk1_duty_cycle        = 50;
        defparam u_altpll.clk1_multiply_by       = ${toString pllCoreMultBy};
        defparam u_altpll.clk1_phase_shift       = "0";
        defparam u_altpll.compensate_clock       = "CLK0";
        defparam u_altpll.inclk0_input_frequency = 20000;
        defparam u_altpll.intended_device_family = "Cyclone II";
        defparam u_altpll.lpm_type               = "altpll";
        defparam u_altpll.operation_mode         = "NORMAL";
        defparam u_altpll.port_clk0              = "PORT_USED";
        defparam u_altpll.port_clk1              = "PORT_USED";
        defparam u_altpll.port_inclk0            = "PORT_USED";
        defparam u_altpll.port_locked            = "PORT_USED";
        defparam u_altpll.port_areset            = "PORT_USED";
        defparam u_altpll.width_clock            = 5;

        altpll u_altpll_sdram (
            .areset (1'b0),
            .inclk  ({1'b0, CLOCK_27}),
            .clk    (altpll_sdram_clk_vec),
            .locked (pll_sdram_locked),
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
        defparam u_altpll_sdram.bandwidth_type         = "AUTO";
        defparam u_altpll_sdram.clk0_divide_by         = ${toString pllSdramDivBy};
        defparam u_altpll_sdram.clk0_duty_cycle        = 50;
        defparam u_altpll_sdram.clk0_multiply_by       = ${toString pllSdramMultBy};
        defparam u_altpll_sdram.clk0_phase_shift       = "0";
        defparam u_altpll_sdram.clk1_divide_by         = ${toString pllSdramDivBy};
        defparam u_altpll_sdram.clk1_duty_cycle        = 50;
        defparam u_altpll_sdram.clk1_multiply_by       = ${toString pllSdramMultBy};
        defparam u_altpll_sdram.clk1_phase_shift       = "-3000";
        defparam u_altpll_sdram.compensate_clock       = "CLK0";
        defparam u_altpll_sdram.inclk0_input_frequency = 37037;  // 27 MHz period (ps)
        defparam u_altpll_sdram.intended_device_family = "Cyclone II";
        defparam u_altpll_sdram.lpm_type               = "altpll";
        defparam u_altpll_sdram.operation_mode         = "NORMAL";
        defparam u_altpll_sdram.port_clk0              = "PORT_USED";
        defparam u_altpll_sdram.port_clk1              = "PORT_USED";
        defparam u_altpll_sdram.port_inclk0            = "PORT_USED";
        defparam u_altpll_sdram.port_locked            = "PORT_USED";
        defparam u_altpll_sdram.port_areset            = "PORT_USED";
        defparam u_altpll_sdram.width_clock            = 5;

        // Combined async-low reset for the bus + core domain. Asserted
        // (low) while either PLL hasn't locked or KEY[0] is held.
        wire rstBus_n  = KEY[0] & pll_bus_locked & pll_sdram_locked;
        wire rstCore_n = rstBus_n; // tied while clkCore=clkBus electrically

        // Reset for the clkSdram domain. Async assert from rstBus_n,
        // sync deassert in clkSdram domain via 2-FF synchroniser.
        (* preserve *) reg [1:0] rstSdram_sync_chain;
        always @(posedge clkSdram or negedge rstBus_n) begin
            if (!rstBus_n)
                rstSdram_sync_chain <= 2'b00;
            else
                rstSdram_sync_chain <= {rstSdram_sync_chain[0], 1'b1};
        end
        wire rstSdram_n = rstSdram_sync_chain[1];

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
            .clk            (clkBus),
            .rst_n          (rstBus_n),
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
        // ----- SDRAM bus signals -------------------------------------
        // Clash master-side (clkBus domain), driven by Riski5.Sdram
        // adapter inside the riski5 module.
        wire        sdram_cs;
        wire [21:0] sdram_addr_bus;
        wire [15:0] sdram_wdata;
        wire [1:0]  sdram_be;
        wire        sdram_rd;
        wire        sdram_wr;

        // SDRAM IP slave-side (clkSdram domain), driven by CDC bridge.
        wire        sdram_ip_az_cs;
        wire [21:0] sdram_ip_az_addr;
        wire [15:0] sdram_ip_az_data;
        wire [1:0]  sdram_ip_az_be;
        wire        sdram_ip_az_rd;
        wire        sdram_ip_az_wr;

        // SDRAM IP slave-side reply signals (clkSdram domain), consumed
        // by the CDC bridge and forwarded to the master side.
        wire [15:0] sdram_ip_readdata;
        wire        sdram_ip_valid;
        wire        sdram_ip_waitrequest;

        // DRAM_DQ is inout on both the top-level port and the IP's
        // zs_dq port — the Altera IP owns the tristate enable logic
        // internally, so we just wire them together directly. (SRAM
        // needs our own resolution because the core drives those
        // pins from pure logic without an Avalon-MM IP in between.)

        // DRAM_CLK is driven from u_altpll_sdram|clk[1] (-3 ns phase
        // shift relative to clkSdram). Standard Altera SDRAM
        // Controller deployment: the chip samples 3 ns AFTER the
        // FPGA-side IP drives signals, covering Tco + board trace
        // delay. The phase shift originally landed in task #132
        // when DRAM_CLK driven directly from the bus clock left the
        // chip-pin setup/hold margin marginal under back-to-back
        // JTAG-Master writes; that pattern is preserved here, just
        // sourced from the SDRAM PLL instead.
        assign DRAM_CLK = clkSdramOut;

        // ----- SDRAM CDC bridge: clkBus ↔ clkSdram -------------------
        // The Clash riski5 module produces sdram_cs / sdram_addr_bus /
        // sdram_wdata / sdram_be / sdram_rd / sdram_wr in the clkBus
        // domain. The Altera SDRAM Controller IP slave port lives in
        // the clkSdram domain. The bridge below uses a toggle-handshake
        // CDC pattern: master side latches the request and toggles
        // req_toggle_bus; slave side 2-FF synchronises the toggle,
        // detects the rising edge, samples the latched signals (stable
        // across the cross-domain combinational path because the
        // master holds them through M_BUSY), drives the IP's slave
        // port until !waitrequest (and for reads, until valid pulses
        // with rdata), captures rdata into a stable register, and
        // toggles done_toggle_sdram back. Master then 2-FF synchs the
        // done toggle, drops bridge_waitrequest for one cycle so the
        // adapter advances, and (for reads) pulses bridge_valid in the
        // following cycle with the captured rdata.
        wire [15:0] sdram_bridge_rdata;
        wire        sdram_bridge_valid;
        wire        sdram_bridge_waitrequest;

        riski5_sdram_cdc_bridge u_sdram_cdc (
            // Master side (clkBus domain)
            .clkBus       (clkBus),
            .rstBus_n     (rstBus_n),
            .m_cs         (sdram_cs),
            .m_addr       (sdram_addr_bus),
            .m_wdata      (sdram_wdata),
            .m_be         (sdram_be),
            .m_rd         (sdram_rd),
            .m_wr         (sdram_wr),
            .m_rdata      (sdram_bridge_rdata),
            .m_valid      (sdram_bridge_valid),
            .m_waitrequest(sdram_bridge_waitrequest),
            // Slave side (clkSdram domain)
            .clkSdram     (clkSdram),
            .rstSdram_n   (rstSdram_n),
            .s_cs         (sdram_ip_az_cs),
            .s_addr       (sdram_ip_az_addr),
            .s_wdata      (sdram_ip_az_data),
            .s_be         (sdram_ip_az_be),
            .s_rd         (sdram_ip_az_rd),
            .s_wr         (sdram_ip_az_wr),
            .s_rdata      (sdram_ip_readdata),
            .s_valid      (sdram_ip_valid),
            .s_waitrequest(sdram_ip_waitrequest)
        );

        // The Clash module's three SDRAM_* return inputs see the
        // bridge's master-side outputs, NOT the IP directly:
        //   SDRAM_RDATA  ← sdram_bridge_rdata  (latched in clkBus)
        //   SDRAM_VALID  ← sdram_bridge_valid  (1-cycle pulse)
        //   SDRAM_READY  ← ~sdram_bridge_waitrequest
        wire sdram_ready = ~sdram_bridge_waitrequest;

        riski5_sdram u_sdram (
            .clk            (clkSdram),
            .reset_n        (rstSdram_n),
            // Avalon-MM slave (driven by CDC bridge)
            .az_cs          (sdram_ip_az_cs),
            .az_addr        (sdram_ip_az_addr),
            .az_data        (sdram_ip_az_data),
            .az_be_n        (~sdram_ip_az_be),
            .az_rd_n        (~sdram_ip_az_rd),
            .az_wr_n        (~sdram_ip_az_wr),
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

        // ----- Clash riski5 core --------------------------------------
        wire [31:0]  debug_pcfetch;
        wire [7:0]   debug_flags;
        wire [127:0] debug_frozen_pc;     // 4 × 32-bit pc snapshots
        wire [31:0]  debug_frozen_flags;  // 4 × 8-bit flag snapshots
        wire         debug_reset_capture;
        wire [1:0]   debug_capture_offset; // unused — kept to match port shape

        // ----- L-3 JTAG-load wires ----------------------------------
        // Sources (JTAG → fabric): drive the SDRAM IP slave-side mux
        // inside Riski5.Soc when JTAG_LOAD_MODE is asserted.
        // Probes  (fabric → JTAG): SDRAM read result + busy.
        //
        // L-3b option A landed: these wires are now driven by the
        // Altera JTAG-to-Avalon-Master IP's master interface, which
        // a host-side `master_write_32` Tcl command (via
        // `quartus_stp` System Console) drives over JTAG. The bridge
        // bypasses the JTAG-UART RX path, so kernel + DTB upload
        // throughput is set by the bridge IP's JTAG protocol
        // (~50-100 KB/s) rather than the JTAG-UART RX FIFO
        // (~1-2 KB/s on this rig — see
        // docs/perf/jtag-uart-link-2026-04-28.md).
        wire [31:0]  jam_master_address;
        wire [31:0]  jam_master_readdata;
        wire         jam_master_read;
        wire         jam_master_write;
        wire [31:0]  jam_master_writedata;
        wire         jam_master_waitrequest;
        wire         jam_master_readdatavalid;
        wire [3:0]   jam_master_byteenable;
        wire         jam_master_reset_reset;

        // Bridge → JTAG_LOAD_* fabric inputs.
        wire         jtag_load_mode  = jam_master_read | jam_master_write;
        wire [31:0]  jtag_load_addr  = jam_master_address;
        wire [31:0]  jtag_load_wdata = jam_master_writedata;
        wire         jtag_load_we    = jam_master_write;
        wire         jtag_load_rd    = jam_master_read;
        wire [31:0]  jtag_load_rdata;
        wire         jtag_load_busy;

        // JTAG_LOAD_BUSY drives master_waitrequest and is the FSM-
        // ready inverted (see Riski5.Soc.jtagLoadBusyS). The master
        // therefore holds master_read / master_address asserted
        // through the full SDRAM-controller multi-cycle read
        // (SReadLoReq → SReadLoWait → SReadHiReq → SReadHiWait),
        // and waitrequest only drops on the SReadHiWait cycle when
        // the IP's za_valid pulses with the assembled 32-bit word.
        assign jam_master_waitrequest = jtag_load_busy;
        assign jam_master_readdata    = jtag_load_rdata;
        // readdatavalid combinational with read-accept: pulses the
        // SAME cycle as waitrequest=0 with master_read=1. This is
        // required because @sdramRdataS@ is only meaningful in
        // SReadHiWait when @validS@ is true — the next cycle the
        // FSM has transitioned to SIdle and rdataS reverts to 0.
        // An earlier @reg jam_read_pending@ that delayed the pulse
        // by one cycle latched the post-transition zero, making
        // every master_read_32 return 0.
        assign jam_master_readdatavalid = jam_master_read & ~jam_master_waitrequest;

        riski5_jtag_master u_jtag_master (
            .clk_clk              (clkBus),
            .clk_reset_reset      (~rstBus_n),
            .master_address       (jam_master_address),
            .master_readdata      (jam_master_readdata),
            .master_read          (jam_master_read),
            .master_write         (jam_master_write),
            .master_writedata     (jam_master_writedata),
            .master_waitrequest   (jam_master_waitrequest),
            .master_readdatavalid (jam_master_readdatavalid),
            .master_byteenable    (jam_master_byteenable),
            .master_reset_reset   (jam_master_reset_reset)
        );

        riski5 u_riski5 (
            .CLOCK_BUS   (clkBus),
            .RESET_BUS_N (rstBus_n),
            .KEY         (KEY),
            .SW          (SW),
            .SRAM_DQ_I   (SRAM_DQ),
            .UART_RDATA  (uart_rdata),
            .UART_READY  (uart_ready),
            .UART_IRQ    (jtag_uart_irq),
            .SDRAM_RDATA (sdram_bridge_rdata),
            .SDRAM_VALID (sdram_bridge_valid),
            .SDRAM_READY (sdram_ready),
            .DEBUG_RESET_CAPTURE  (debug_reset_capture),
            .DEBUG_CAPTURE_OFFSET (debug_capture_offset),
            .JTAG_LOAD_MODE  (jtag_load_mode),
            .JTAG_LOAD_ADDR  (jtag_load_addr),
            .JTAG_LOAD_WDATA (jtag_load_wdata),
            .JTAG_LOAD_WE    (jtag_load_we),
            .JTAG_LOAD_RD    (jtag_load_rd),
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
            .DEBUG_PCFETCH      (debug_pcfetch),
            .DEBUG_FLAGS        (debug_flags),
            .DEBUG_FROZEN_PC    (debug_frozen_pc),
            .DEBUG_FROZEN_FLAGS (debug_frozen_flags),
            .JTAG_LOAD_RDATA    (jtag_load_rdata),
            .JTAG_LOAD_BUSY     (jtag_load_busy)
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

        // ----- altsource_probe — 4-cycle frozen pcFetch waveform ----
        // 128-bit probe carrying the core's pcFetchS captured at the
        // freeze-on-trigger cycle and 3 cycles after, concatenated
        // MSB-first: bits [127:96] = pc_K (trigger cycle), [95:64] =
        // pc_{K+1}, [63:32] = pc_{K+2}, [31:0] = pc_{K+3}. Holds
        // until @CAPR@'s 1-bit source pulses 1 to re-arm. Used for
        // SDRAM-exec multi-byte residual investigation.
        //
        // The wide-probe approach replaced an earlier source-driven
        // mux on a 2-bit @OFFS@ probe: multi-bit altsource_probe
        // sources didn't propagate reliably through Quartus 13.0sp1's
        // JTAG hub on this design, but probes (FPGA → JTAG) work
        // fine at any reasonable width.
        altsource_probe #(
            .lpm_type                 ("altsource_probe"),
            .lpm_hint                 ("CBX_AUTO_BLACKBOX=ALL"),
            .source_width             (0),
            .probe_width              (128),
            .instance_id              ("FRZP"),
            .sld_ir_width             (3),
            .source_initial_value     ("0"),
            .sld_auto_instance_index  ("YES"),
            .sld_instance_index       (2),
            .enable_metastability     ("NO")
        ) u_frozen_pc_probe (
            .probe        (debug_frozen_pc),
            .source       (),
            .source_clk   (1'b0),
            .source_ena   (1'b0)
        );

        // ----- altsource_probe — 4-cycle frozen flags waveform ------
        // 32-bit probe carrying the 4 frozen flag bytes concatenated:
        // bits [31:24] = flags_K, [23:16] = flags_{K+1},
        // [15:8] = flags_{K+2}, [7:0] = flags_{K+3}. Same per-byte
        // bit layout as @DBGF@ with bit [7] repurposed as
        // @capturedS@.
        altsource_probe #(
            .lpm_type                 ("altsource_probe"),
            .lpm_hint                 ("CBX_AUTO_BLACKBOX=ALL"),
            .source_width             (0),
            .probe_width              (32),
            .instance_id              ("FRZF"),
            .sld_ir_width             (3),
            .source_initial_value     ("0"),
            .sld_auto_instance_index  ("YES"),
            .sld_instance_index       (3),
            .enable_metastability     ("NO")
        ) u_frozen_flags_probe (
            .probe        (debug_frozen_flags),
            .source       (),
            .source_clk   (1'b0),
            .source_ena   (1'b0)
        );

        // ----- altsource_probe — capture re-arm pulse ----------------
        // 1-bit source that software writes to clear the capture
        // FSM and re-arm the snapshot for the next trigger. The
        // @source_clk@ is tied to the design clock so the pulse is
        // synchronous to the rest of the SoC.
        altsource_probe #(
            .lpm_type                 ("altsource_probe"),
            .lpm_hint                 ("CBX_AUTO_BLACKBOX=ALL"),
            .source_width             (1),
            .probe_width              (0),
            .instance_id              ("CAPR"),
            .sld_ir_width             (3),
            .source_initial_value     ("0"),
            .sld_auto_instance_index  ("YES"),
            .sld_instance_index       (4),
            .enable_metastability     ("NO")
        ) u_capture_reset_source (
            .probe        (),
            .source       (debug_reset_capture),
            .source_clk   (clkBus),
            .source_ena   (1'b1)
        );

        // ----- altsource_probe — capture cycle-offset selector ------
        // 2-bit source that was intended to multiplex between the 4
        // freeze-trigger snapshots, but multi-bit altsource_probe
        // sources don't propagate reliably through this design's
        // JTAG hub on Quartus 13.0sp1. Replaced by the wide-probe
        // approach above (FRZP is now 128-bit, FRZF is 32-bit, all
        // 4 cycles read in one JTAG transaction). The source-probe
        // instance is kept here so the riski5 module's
        // @DEBUG_CAPTURE_OFFSET@ port has a driver (otherwise
        // Quartus would fail elaboration); the value ends up unused
        // inside the SoC.
        altsource_probe #(
            .lpm_type                 ("altsource_probe"),
            .lpm_hint                 ("CBX_AUTO_BLACKBOX=ALL"),
            .source_width             (2),
            .probe_width              (0),
            .instance_id              ("OFFS"),
            .sld_ir_width             (3),
            .source_initial_value     ("0"),
            .sld_auto_instance_index  ("YES"),
            .sld_instance_index       (5),
            .enable_metastability     ("NO")
        ) u_capture_offset_source (
            .probe        (),
            .source       (debug_capture_offset),
            .source_clk   (clkBus),
            .source_ena   (1'b1)
        );

        // ----- IP-side commit counter -------------------------------
        // Counts every cycle the JTAG-UART IP would actually commit a
        // byte to its FIFO, using the IP's own commit condition:
        // @av_chipselect & ~av_write_n & av_waitrequest@. This sits
        // OUTSIDE the Clash core so it observes the master-bus
        // values the IP itself sees, sidestepping any subtle Clash
        // signal renaming or pipeline timing assumptions.
        //
        // The counter resets via @CAPR@ (= @debug_reset_capture@)
        // along with the freeze-on-trigger FSM, so software can
        // pulse @CAPR@, wait, and read the counter to learn how
        // many bytes the IP committed in that interval. Compare
        // against the iteration count (from PCFE / DBGF probes
        // inferring the firmware's loop frequency) to determine
        // whether the silicon multi-byte residual is master-side
        // multi-commit or something further out (FIFO drain
        // doubling, JTAG transport).
        wire ip_commit_pulse = uart_sel & jtag_uart_wr & jtag_uart_waitrequest;
        reg [31:0] ip_commit_counter = 32'b0;
        always @(posedge clkBus or negedge rstBus_n) begin
            if (!rstBus_n)
                ip_commit_counter <= 32'b0;
            else if (debug_reset_capture)
                ip_commit_counter <= 32'b0;
            else if (ip_commit_pulse)
                ip_commit_counter <= ip_commit_counter + 32'b1;
        end

        altsource_probe #(
            .lpm_type                 ("altsource_probe"),
            .lpm_hint                 ("CBX_AUTO_BLACKBOX=ALL"),
            .source_width             (0),
            .probe_width              (32),
            .instance_id              ("CMTC"),
            .sld_ir_width             (3),
            .source_initial_value     ("0"),
            .sld_auto_instance_index  ("YES"),
            .sld_instance_index       (6),
            .enable_metastability     ("NO")
        ) u_commit_counter_probe (
            .probe        (ip_commit_counter),
            .source       (),
            .source_clk   (1'b0),
            .source_ena   (1'b0)
        );

        // Iteration-counter — increments once per BRAM-resident @sw@
        // for @B@. We approximate "iterations" by counting the cycles
        // where the IP committed a byte that happened to be 'B'
        // (= 0x42). Same reset semantics as the IP commit counter.
        wire byte_is_b = (uart_wdata[7:0] == 8'h42);
        reg [31:0] iter_counter = 32'b0;
        always @(posedge clkBus or negedge rstBus_n) begin
            if (!rstBus_n)
                iter_counter <= 32'b0;
            else if (debug_reset_capture)
                iter_counter <= 32'b0;
            else if (ip_commit_pulse & byte_is_b)
                iter_counter <= iter_counter + 32'b1;
        end

        altsource_probe #(
            .lpm_type                 ("altsource_probe"),
            .lpm_hint                 ("CBX_AUTO_BLACKBOX=ALL"),
            .source_width             (0),
            .probe_width              (32),
            .instance_id              ("ITRC"),
            .sld_ir_width             (3),
            .source_initial_value     ("0"),
            .sld_auto_instance_index  ("YES"),
            .sld_instance_index       (7),
            .enable_metastability     ("NO")
        ) u_iter_counter_probe (
            .probe        (iter_counter),
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
