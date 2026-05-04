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
  # Build the SDRAM-stress silicon-test variant. Bigger than
  # @sdramExec@ (which just `sw 'S'`), much smaller than the
  # Linux kernel. The BRAM bootstrap stages a ~30-instruction
  # SDRAM-resident loop into @SDRAM[0x80000000..0x80000200)@,
  # JALRs there, the loop writes a per-iteration value to 4
  # SDRAM addresses each in a different bank, reads each back
  # and verifies, prints @.@ per clean iteration / @F@ on the
  # first mismatch, loops 256 times then @D@ and JALRs back to
  # BRAM (where it loops the whole sequence). Same overlay
  # mechanism as @sdramExec@; flips @FetchPolicy.enableSdramFetch
  # = True@ so the SoC routes @pcFetch in SDRAM range@ through
  # the 'Riski5.Sdram' adapter.
  sdramStress ? false,
  # Bisecting twin of sdramStress: the SAME stress workload (write
  # + read 4 SDRAM banks per iteration for 256 iterations), but the
  # loop runs from BRAM (no @JALR@ to SDRAM, no @enableSdramFetch@).
  # Use to disambiguate "SDRAM data path is broken" from "the
  # SoC's fetch+data SDRAM arbiter is broken". Same overlay
  # mechanism as @sramExec@; @FetchPolicy@ stays at the BRAM-only
  # default.
  sdramDataStress ? false,
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
  # Build the AMO-stress silicon-test variant (task #29). Overlay
  # @HelloAmoStress.helloAmoStressFirmwareWords@ into the imem.
  # BRAM bootstrap stages an SDRAM-resident inner loop that runs
  # @amoswap.w + verify-lw@ across 4 SDRAM banks per iteration,
  # prints @.@ per clean iteration / per-bank label + @F@ on
  # failure. Top suspect for the Linux stack-protector panic at
  # PC=0x8002cd98 (atomic refcounts, AMO FU is the newest
  # silicon-bringup component). Same overlay mechanism as
  # @sdramStress@; flips @FetchPolicy.enableSdramFetch=True@ so
  # the AMO inner loop fetches from SDRAM under contention with
  # the AMO Read/Write data-port phases.
  amoStress ? false,
  # Build the LR/SC-stress silicon-test variant (task #32 follow-
  # up to #29). Overlay
  # @HelloLrScStress.helloLrScStressFirmwareWords@ into the imem.
  # Same shape as @amoStress@ but uses the @lr.w + sc.w.rl@
  # cmpxchg retry pattern (matching the kernel's
  # @arch_cmpxchg32_relaxed@) instead of @amoswap.w@. The kernel
  # panic site at PC=0x8002cd98 (task_work_add) uses LR/SC, NOT
  # amoswap — and amoswap's silicon variant came back clean
  # (@docs/perf/amostress-silicon-2026-05-02.log@), so this
  # variant probes a different AMO sub-path.
  lrScStress ? false,
  # Build the stack-stress silicon-test variant (task #33).
  # Overlay
  # @HelloStackStress.helloStackStressFirmwareWords@ into the
  # imem. Mirrors task_work_add's exact prologue/epilogue (4-reg
  # save/restore on SDRAM-resident stack) under fetch contention
  # — third major suspect after AMO + LR/SC came back clean.
  # If any of the four sw/lw pairs returns the wrong value
  # under any concurrent fetch+data SDRAM bus pattern, this
  # variant prints 'F' + a per-register label.
  stackStress ? false,
  # Build the trap-during-stress silicon-test variant (task #34).
  # Overlay
  # @HelloTrapStress.helloTrapStressFirmwareWords@ into the imem.
  # Same inner loop as @stackStress@ (4-reg prologue/epilogue
  # mirroring task_work_add) but runs WITH timer IRQs firing every
  # ~256 cycles. Probes whether a trap landing mid-prologue or
  # mid-epilogue corrupts the SDRAM stack frame or the live ABI
  # registers — fourth major suspect after AMO + LR/SC + bare
  # stack came back clean. The handler uses @mscratch@ + SRAM
  # scratch (not SDRAM) so it doesn't add SDRAM contention to the
  # inner loop's contention.
  trapStress ? false,
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
  # Task #36 — drop one notch further than slowClock: 50 × 2 / 5 =
  # 20 MHz on the bus / core / DRAM_CLK. Same single-clock-domain
  # mechanism as @slowClock@; takes precedence when both are set.
  # Motivating hypothesis: slowClock (30 MHz) gets the kernel five
  # printks further than the 40 MHz hang at SLUB init (now hangs
  # right after sched_clock setup). If 20 MHz boots completely,
  # the bug is purely timing margin and the next step is the proper
  # multi-PLL split (CPU @ 40 MHz, SDRAM IP @ 30 MHz with FIFO
  # bridge). If it still hangs around the same place, the timing
  # margin is partly to blame but there's a non-timing factor too.
  verySlowClock ? false,
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
  isSdramStress = sdramStress && !isCoremark && !isSramExec && !isSdramExec;
  isSdramDataStress = sdramDataStress && !isCoremark && !isSramExec && !isSdramExec && !isSdramStress;
  isAExtTest = aExtTest && !isCoremark && !isSramExec && !isSdramExec && !isSdramStress && !isSdramDataStress;
  isAmoStress = amoStress && !isCoremark && !isSramExec && !isSdramExec && !isSdramStress && !isSdramDataStress && !isAExtTest;
  isLrScStress = lrScStress && !isCoremark && !isSramExec && !isSdramExec && !isSdramStress && !isSdramDataStress && !isAExtTest && !isAmoStress;
  isStackStress = stackStress && !isCoremark && !isSramExec && !isSdramExec && !isSdramStress && !isSdramDataStress && !isAExtTest && !isAmoStress && !isLrScStress;
  isTrapStress = trapStress && !isCoremark && !isSramExec && !isSdramExec && !isSdramStress && !isSdramDataStress && !isAExtTest && !isAmoStress && !isLrScStress && !isStackStress;
  isTimerIrqTest = timerIrqTest && !isCoremark && !isSramExec && !isSdramExec && !isSdramStress && !isSdramDataStress && !isAExtTest && !isAmoStress && !isLrScStress && !isStackStress && !isTrapStress;
  isSdramLoad = sdramLoad && !isCoremark && !isSramExec && !isSdramExec && !isSdramStress && !isSdramDataStress && !isAExtTest && !isAmoStress && !isLrScStress && !isStackStress && !isTrapStress && !isTimerIrqTest;
  isLinuxBoot = linuxBoot && !isCoremark && !isSramExec && !isSdramExec && !isSdramStress && !isSdramDataStress && !isAExtTest && !isAmoStress && !isLrScStress && !isStackStress && !isTrapStress && !isTimerIrqTest && !isSdramLoad;
  isLinuxBootMaster = linuxBootMaster && !isCoremark && !isSramExec && !isSdramExec && !isSdramStress && !isSdramDataStress && !isAExtTest && !isAmoStress && !isLrScStress && !isStackStress && !isTrapStress && !isTimerIrqTest && !isSdramLoad && !isLinuxBoot;
  # Task #146 (single-PLL, with phase-shifted DRAM_CLK output):
  # the second PLL (u_altpll_sdram on CLOCK_27) was removed when
  # the Altera SDRAM Controller IP and the toggle-handshake CDC
  # bridge were dropped. The pure-Clash SDR SDRAM controller in
  # 'Riski5.SdrController' runs on clkBus (the same 40 MHz clock
  # as the rest of the SoC) and drives DRAM_* pins directly.
  #
  #   u_altpll        — bus + core + DRAM-CLK output (input: CLOCK_50)
  #     clk0:  clkBus      40 MHz, 0°    (slowClock=true → 30 MHz)
  #     clk1:  clkCore     40 MHz, 0°    (separate counter from clkBus
  #                                        so a future commit can
  #                                        change just clk1's multiplier
  #                                        and clock the RISC-V core
  #                                        faster than the bus)
  #     clk2:  clkDramOut  40 MHz, +90°  (= +6250 ps at 40 MHz / 25 ns
  #                                        period). Routed straight to
  #                                        DRAM_CLK so the chip's clock
  #                                        edge falls in the middle of
  #                                        the FPGA's stable DQ /
  #                                        command window after the
  #                                        I/O-cell Tco. Required after
  #                                        QSF was changed to put all
  #                                        DRAM_* outputs in I/O-cell
  #                                        flops (FAST_OUTPUT_REGISTER):
  #                                        with both DQ and command on
  #                                        the same Tco budget, a chip
  #                                        clock aligned with the FPGA
  #                                        edge would catch the
  #                                        outputs mid-transition.
  # bus, core, DRAM_CLK: 50 × M / 5 → 40 MHz (default), 30 MHz
  # (slowClock), 20 MHz (verySlowClock). verySlowClock takes
  # precedence over slowClock when both are set.
  pllBusMultBy =
    if verySlowClock then 2
    else if slowClock then 3
    else 4;
  pllCoreMultBy =
    if verySlowClock then 2
    else if slowClock then 3
    else 4;
  # Phase D-1 of multi-PLL split: dedicated u_altpll_core PLL for
  # the RISC-V core. Currently produces clkCore at the same rate
  # as clkBus (both 40 MHz default) so behaviour is unchanged from
  # Phase C. Future Phase D-2 lands the actual Soc.hs core/bus
  # split via the existing Riski5.CoreCdcBridge from Phase B,
  # which will then let pllCoreMultBy diverge from pllBusMultBy
  # to crank the core independently.
  pllCoreDivBy = 5;
  # SDRAM domain (Phase C of multi-PLL split). Independent PLL
  # u_altpll_sdram in the wrapper Verilog. Default M=8, D=5 →
  # 50 × 8 / 5 = 80 MHz, a safe step-up from the prior 40 MHz
  # combined-domain rate.
  #
  # Why 80 MHz instead of the chip's 133 MHz spec rate: the first
  # silicon test of 133 MHz showed the DRAM_DQ → controller-reg
  # input path failing setup by -5.247 ns. The chip's t_AC = 5.4 ns
  # (CLK→DQ valid max) leaves only 2.1 ns of slack at 7.5 ns
  # period for trace + I/O setup, and the DE2 board adds ~0.5 ns
  # of trace delay. Source-synchronous timing at 133 MHz simply
  # doesn't fit in the IS42S16400-7TL + DE2 envelope without
  # FAST_INPUT_REGISTER tuning we haven't done yet.
  #
  # 80 MHz / 12.5 ns period gives ~7 ns of slack on the DQ input
  # path — comfortable. Linux-boot timing-margin experiments in
  # task #35 / #36 showed the silicon Linux hang shifts with bus
  # rate; doubling SDRAM rate to 80 MHz while keeping bus at
  # 40 MHz tests the multi-PLL hypothesis cleanly.
  #
  # Push to higher rates by overriding pllSdramMultBy at the Nix
  # invocation. M=10/D=5 → 100 MHz; M=13/D=5 → 130 MHz; M=8/D=3 →
  # 133.33 MHz. Each requires its own STA validation.
  pllSdramMultBy = 5;
  pllSdramDivBy = 5;
  # SDRAM clock period in picoseconds, derived from the M/D pair.
  # Used both for SDC constraints and for computing the +90° phase
  # shift on DRAM_CLK. At 50 × 8 / 3 = 133.33 MHz, period = 7500 ps,
  # quarter-period = 1875 ps.
  sdramPeriodPs = 50000 * pllSdramDivBy / pllSdramMultBy;
  # SDRAM clock frequency in Hz, passed to Clash as -DSOC_SDRAM_CLOCK_HZ
  # so defaultDe2ConfigForClockHz computes refresh + init NOPs from
  # the actual SDRAM rate.
  sdramClockHz = 50000000 * pllSdramMultBy / pllSdramDivBy;
  # +90° phase shift = quarter-period delay on DRAM_CLK output.
  # Now computed from the SDRAM period rather than the bus period
  # (the chip's clock follows the controller's clock domain post
  # Phase C). At 133 MHz / 7.5 ns period → +1875 ps.
  pllDramPhaseShiftPs = toString (sdramPeriodPs / 4);
  slowSuffix =
    if verySlowClock then "-veryslow"
    else if slowClock then "-slow"
    else "";
in
  stdenv.mkDerivation {
    pname =
      (if isCoremark then "riski5-core-coremark"
      else if isSramExec then "riski5-core-sramexec"
      else if isSdramExec then "riski5-core-sdramexec"
      else if isSdramStress then "riski5-core-sdramstress"
      else if isSdramDataStress then "riski5-core-sdramdatastress"
      else if isAExtTest then "riski5-core-aexttest"
      else if isAmoStress then "riski5-core-amostress"
      else if isLrScStress then "riski5-core-lrscstress"
      else if isStackStress then "riski5-core-stackstress"
      else if isTrapStress then "riski5-core-trapstress"
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

            ${lib.optionalString isSdramStress ''
              # SDRAM-stress silicon test variant. Same overlay
              # mechanism as sdramExec but bigger SDRAM-resident
              # workload — exercises mixed read/write/fetch across
              # 4 banks for 256 iterations. Useful for bisecting
              # between "Linux-specific bug" and "SDRAM execution
              # is unreliable" hangs (task #17 follow-up to #146).
              chmod -R u+w firmware/phase1
              cat > firmware/phase1/CoreMark.hs <<'EOF'
              -- SPDX-FileCopyrightText: 2026 Mika Tammi
              -- SPDX-License-Identifier: MIT OR BSD-3-Clause
              --
              -- Overlaid by the sdramStress Nix build: re-exports
              -- HelloSdramStress's firmware under the CoreMark
              -- name so the unchanged -DFIRMWARE_COREMARK path in
              -- app/Top.hs bakes the SDRAM-stress probe into imem.
              {-# LANGUAGE DataKinds #-}
              {-# LANGUAGE NoStarIsType #-}

              module CoreMark (
                coreMarkFirmwareWords,
              ) where

              import Clash.Prelude (BitVector)
              import HelloSdramStress (helloSdramStressFirmwareWords)

              coreMarkFirmwareWords :: [BitVector 32]
              coreMarkFirmwareWords = helloSdramStressFirmwareWords
              EOF
              sed -i 's/^              //' firmware/phase1/CoreMark.hs
              echo "### sdramStress variant: overlaid firmware/phase1/CoreMark.hs"
              cat firmware/phase1/CoreMark.hs

              cat > firmware/phase1/FetchPolicy.hs <<'EOF'
              -- SPDX-FileCopyrightText: 2026 Mika Tammi
              -- SPDX-License-Identifier: MIT OR BSD-3-Clause
              --
              -- Overlaid by the sdramStress Nix build: turns on
              -- the fetch-side SDRAM routing inside Riski5.Soc.soc
              -- so the inner stress loop can execute from
              -- 0x8000_0000+.
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
              echo "### sdramStress variant: overlaid firmware/phase1/FetchPolicy.hs"
              cat firmware/phase1/FetchPolicy.hs
            ''}

            ${lib.optionalString isSdramDataStress ''
              # SDRAM-data-stress bisect variant: same workload as
              # sdramStress, but the loop runs from BRAM (no JALR
              # to SDRAM, FetchPolicy stays at the BRAM-only
              # default). Use to disambiguate "SDRAM data path is
              # broken" from "SoC's fetch+data SDRAM arbiter is
              # broken" — task #17 follow-up.
              chmod -R u+w firmware/phase1
              cat > firmware/phase1/CoreMark.hs <<'EOF'
              -- SPDX-FileCopyrightText: 2026 Mika Tammi
              -- SPDX-License-Identifier: MIT OR BSD-3-Clause
              --
              -- Overlaid by the sdramDataStress Nix build:
              -- re-exports HelloSdramDataStress's firmware under
              -- the CoreMark name so the unchanged
              -- -DFIRMWARE_COREMARK path in app/Top.hs bakes the
              -- BRAM-resident SDRAM-data-stress probe into imem.
              {-# LANGUAGE DataKinds #-}
              {-# LANGUAGE NoStarIsType #-}

              module CoreMark (
                coreMarkFirmwareWords,
              ) where

              import Clash.Prelude (BitVector)
              import HelloSdramDataStress (helloSdramDataStressFirmwareWords)

              coreMarkFirmwareWords :: [BitVector 32]
              coreMarkFirmwareWords = helloSdramDataStressFirmwareWords
              EOF
              sed -i 's/^              //' firmware/phase1/CoreMark.hs
              echo "### sdramDataStress variant: overlaid firmware/phase1/CoreMark.hs"
              cat firmware/phase1/CoreMark.hs
              # FetchPolicy stays at BRAM-only default — important
              # for the bisect (no SDRAM arbiter instantiated).
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

            ${lib.optionalString isAmoStress ''
              # AMO-stress silicon test variant (task #29). Same
              # overlay mechanism as sdramStress but bigger: the
              # BRAM bootstrap stages an SDRAM-resident inner loop
              # that runs amoswap.w + verify-lw across 4 SDRAM
              # banks per iteration, prints '.' per clean iter,
              # per-bank label + 'F' on first failure. Top suspect
              # for the Linux stack-protector panic at PC=0x8002cd98.
              chmod -R u+w firmware/phase1
              cat > firmware/phase1/CoreMark.hs <<'EOF'
              -- SPDX-FileCopyrightText: 2026 Mika Tammi
              -- SPDX-License-Identifier: MIT OR BSD-3-Clause
              --
              -- Overlaid by the amoStress Nix build: re-exports
              -- HelloAmoStress's firmware under the CoreMark name
              -- so the unchanged -DFIRMWARE_COREMARK path in
              -- app/Top.hs bakes the AMO-stress probe into imem.
              {-# LANGUAGE DataKinds #-}
              {-# LANGUAGE NoStarIsType #-}

              module CoreMark (
                coreMarkFirmwareWords,
              ) where

              import Clash.Prelude (BitVector)
              import HelloAmoStress (helloAmoStressFirmwareWords)

              coreMarkFirmwareWords :: [BitVector 32]
              coreMarkFirmwareWords = helloAmoStressFirmwareWords
              EOF
              sed -i 's/^              //' firmware/phase1/CoreMark.hs
              echo "### amoStress variant: overlaid firmware/phase1/CoreMark.hs"
              cat firmware/phase1/CoreMark.hs

              cat > firmware/phase1/FetchPolicy.hs <<'EOF'
              -- SPDX-FileCopyrightText: 2026 Mika Tammi
              -- SPDX-License-Identifier: MIT OR BSD-3-Clause
              --
              -- Overlaid by the amoStress Nix build: turns on the
              -- fetch-side SDRAM routing inside Riski5.Soc.soc so
              -- the AMO inner loop can execute from 0x8000_0000+
              -- (concurrent with the AMO Read/Write data-port
              -- phases — exactly the contention shape we're
              -- testing).
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
              echo "### amoStress variant: overlaid firmware/phase1/FetchPolicy.hs"
              cat firmware/phase1/FetchPolicy.hs
            ''}

            ${lib.optionalString isLrScStress ''
              # LR/SC-stress silicon test variant (task #32, follow-up
              # to #29). Same overlay mechanism as amoStress but uses
              # HelloLrScStress's lr.w + sc.w.rl cmpxchg retry loop —
              # mirrors the kernel's arch_cmpxchg32_relaxed pattern at
              # the panic site task_work_add (PC=0x8002cd98).
              chmod -R u+w firmware/phase1
              cat > firmware/phase1/CoreMark.hs <<'EOF'
              -- SPDX-FileCopyrightText: 2026 Mika Tammi
              -- SPDX-License-Identifier: MIT OR BSD-3-Clause
              --
              -- Overlaid by the lrScStress Nix build: re-exports
              -- HelloLrScStress's firmware under the CoreMark name
              -- so the unchanged -DFIRMWARE_COREMARK path in
              -- app/Top.hs bakes the LR/SC-stress probe into imem.
              {-# LANGUAGE DataKinds #-}
              {-# LANGUAGE NoStarIsType #-}

              module CoreMark (
                coreMarkFirmwareWords,
              ) where

              import Clash.Prelude (BitVector)
              import HelloLrScStress (helloLrScStressFirmwareWords)

              coreMarkFirmwareWords :: [BitVector 32]
              coreMarkFirmwareWords = helloLrScStressFirmwareWords
              EOF
              sed -i 's/^              //' firmware/phase1/CoreMark.hs
              echo "### lrScStress variant: overlaid firmware/phase1/CoreMark.hs"
              cat firmware/phase1/CoreMark.hs

              cat > firmware/phase1/FetchPolicy.hs <<'EOF'
              -- SPDX-FileCopyrightText: 2026 Mika Tammi
              -- SPDX-License-Identifier: MIT OR BSD-3-Clause
              --
              -- Overlaid by the lrScStress Nix build: turns on the
              -- fetch-side SDRAM routing so the LR/SC inner loop can
              -- execute from 0x8000_0000+ (concurrent with the LR.W
              -- Read + SC.W Write data-port phases).
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
              echo "### lrScStress variant: overlaid firmware/phase1/FetchPolicy.hs"
              cat firmware/phase1/FetchPolicy.hs
            ''}

            ${lib.optionalString isStackStress ''
              # Stack-stress silicon test variant (task #33). Same
              # overlay mechanism as amoStress but uses
              # HelloStackStress's multi-register sw/lw + verify
              # pattern matching task_work_add's prologue/epilogue
              # exactly. Third major suspect after AMO + LR/SC came
              # back clean — probes whether SDRAM-resident stack
              # save/restore has a corner case under fetch
              # contention.
              chmod -R u+w firmware/phase1
              cat > firmware/phase1/CoreMark.hs <<'EOF'
              -- SPDX-FileCopyrightText: 2026 Mika Tammi
              -- SPDX-License-Identifier: MIT OR BSD-3-Clause
              --
              -- Overlaid by the stackStress Nix build: re-exports
              -- HelloStackStress's firmware under the CoreMark
              -- name so the unchanged -DFIRMWARE_COREMARK path in
              -- app/Top.hs bakes the stack-stress probe into imem.
              {-# LANGUAGE DataKinds #-}
              {-# LANGUAGE NoStarIsType #-}

              module CoreMark (
                coreMarkFirmwareWords,
              ) where

              import Clash.Prelude (BitVector)
              import HelloStackStress (helloStackStressFirmwareWords)

              coreMarkFirmwareWords :: [BitVector 32]
              coreMarkFirmwareWords = helloStackStressFirmwareWords
              EOF
              sed -i 's/^              //' firmware/phase1/CoreMark.hs
              echo "### stackStress variant: overlaid firmware/phase1/CoreMark.hs"
              cat firmware/phase1/CoreMark.hs

              cat > firmware/phase1/FetchPolicy.hs <<'EOF'
              -- SPDX-FileCopyrightText: 2026 Mika Tammi
              -- SPDX-License-Identifier: MIT OR BSD-3-Clause
              --
              -- Overlaid by the stackStress Nix build: turns on
              -- fetch-side SDRAM routing so the stack-stress inner
              -- loop can execute from 0x8000_0000+ (concurrent
              -- with the multi-register sw/lw data-port phases).
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
              echo "### stackStress variant: overlaid firmware/phase1/FetchPolicy.hs"
              cat firmware/phase1/FetchPolicy.hs
            ''}

            ${lib.optionalString isTrapStress ''
              # Trap-during-stress silicon test variant (task #34).
              # Same overlay mechanism as stackStress but uses
              # HelloTrapStress's combined timer-IRQ + multi-register
              # sw/lw + verify pattern. Probes whether a timer trap
              # landing inside task_work_add's prologue / epilogue /
              # cmpxchg corrupts the SDRAM stack frame or live ABI
              # registers — fourth major suspect after AMO + LR/SC +
              # bare stack came back clean.
              chmod -R u+w firmware/phase1
              cat > firmware/phase1/CoreMark.hs <<'EOF'
              -- SPDX-FileCopyrightText: 2026 Mika Tammi
              -- SPDX-License-Identifier: MIT OR BSD-3-Clause
              --
              -- Overlaid by the trapStress Nix build: re-exports
              -- HelloTrapStress's firmware under the CoreMark
              -- name so the unchanged -DFIRMWARE_COREMARK path in
              -- app/Top.hs bakes the trap-stress probe into imem.
              {-# LANGUAGE DataKinds #-}
              {-# LANGUAGE NoStarIsType #-}

              module CoreMark (
                coreMarkFirmwareWords,
              ) where

              import Clash.Prelude (BitVector)
              import HelloTrapStress (helloTrapStressFirmwareWords)

              coreMarkFirmwareWords :: [BitVector 32]
              coreMarkFirmwareWords = helloTrapStressFirmwareWords
              EOF
              sed -i 's/^              //' firmware/phase1/CoreMark.hs
              echo "### trapStress variant: overlaid firmware/phase1/CoreMark.hs"
              cat firmware/phase1/CoreMark.hs

              cat > firmware/phase1/FetchPolicy.hs <<'EOF'
              -- SPDX-FileCopyrightText: 2026 Mika Tammi
              -- SPDX-License-Identifier: MIT OR BSD-3-Clause
              --
              -- Overlaid by the trapStress Nix build: turns on
              -- fetch-side SDRAM routing so the trap-stress inner
              -- loop can execute from 0x8000_0000+ (concurrent
              -- with the multi-register sw/lw data-port phases
              -- and the timer trap-handler vector fetches).
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
              echo "### trapStress variant: overlaid firmware/phase1/FetchPolicy.hs"
              cat firmware/phase1/FetchPolicy.hs
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
              ${lib.optionalString (isCoremark || isSramExec || isSdramExec || isSdramStress || isSdramDataStress || isAExtTest || isAmoStress || isLrScStress || isStackStress || isTrapStress || isTimerIrqTest || isSdramLoad || isLinuxBoot || isLinuxBootMaster) "-DFIRMWARE_COREMARK"} \
              -DSOC_CLOCK_HZ=${toString (50000000 * pllBusMultBy / 5)} \
              -DSOC_SDRAM_CLOCK_HZ=${toString sdramClockHz} \
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
            #   casLatency       = 3   — required at 108 MHz for the
            #                              IS42S16400-7 part (CL=2 only
            #                              rated to 100 MHz; CL=3 rated
            #                              to 143 MHz)
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
            # Task #146: the Altera SDRAM Controller IP was found to
            # silently drop every upper-16-bit half-word write on the
            # JTAG-Master upload path (25 / 29 fail in
            # `nix run .#sdram-write-pattern-test`). The bug only
            # surfaces under the JTAG-Master path's fast back-to-back
            # writes; the chip itself and the FPGA pins are fine. We
            # replaced the encrypted Altera IP with a pure-Clash SDR
            # SDRAM controller in 'Riski5.SdrController'. The Clash
            # module now drives the chip-side DRAM_* pins directly
            # at 40 MHz on the bus clock — no IP, no CDC bridge, no
            # second PLL. See docs/sdram-hi-half-write-bug.md for
            # the full triage.

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


      module riski5_top (
          input  wire        CLOCK_50,
          input  wire        CLOCK_27,
          input  wire        TD_CLK27,    // unused; assigned per DE2 manual §4.4
          output wire        TD_RESET,    // drive HIGH to keep TV Decoder running
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

        // ----- Single-PLL clock topology (task #146 cleanup) ---------
        // CLOCK_50 (50 MHz off-chip osc) → one ALTPLL producing three
        // outputs in a single logical clock domain:
        //
        //   u_altpll       (bus + core + DRAM_CLK output)
        //     clk0  clkBus      40 MHz, 0°    — Avalon-MM bus, peripherals,
        //                                        JTAG-UART, JTAG-Master,
        //                                        Clash riski5 module,
        //                                        Riski5.SdrController
        //     clk1  clkCore     40 MHz, 0°    — RISC-V core domain.
        //                                        Currently tied electrically
        //                                        to clkBus (Clash core+bus
        //                                        refactor is a follow-up
        //                                        commit).
        //     clk2  clkDramOut  40 MHz, +90°  — physical DRAM_CLK output
        //                                        only. Quarter-period delay
        //                                        so the chip's clock edge
        //                                        falls in the middle of the
        //                                        FPGA's stable DQ / command
        //                                        window after the I/O-cell
        //                                        Tco. NOT a fabric clock —
        //                                        no logic clocked from this.
        //
        // Task #146 removed the second PLL (u_altpll_sdram), the Altera
        // SDRAM Controller IP (u_sdram), and the toggle-handshake CDC
        // bridge (riski5_sdram_cdc_bridge). The pure-Clash SDR SDRAM
        // controller in 'Riski5.SdrController' runs on clkBus and
        // drives the DRAM_* chip pins directly.
        // ===== PLL #1 — bus domain (Phase D split clkCore off into PLL #3) ==
        wire [4:0] altpll_bus_clk_vec;
        wire       clkBus       = altpll_bus_clk_vec[0];
        wire       pll_bus_locked;
        altpll u_altpll_bus (
            .areset (1'b0),
            .inclk  ({1'b0, CLOCK_50}),
            .clk    (altpll_bus_clk_vec),
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
        defparam u_altpll_bus.bandwidth_type         = "AUTO";
        defparam u_altpll_bus.clk0_divide_by         = 5;
        defparam u_altpll_bus.clk0_duty_cycle        = 50;
        defparam u_altpll_bus.clk0_multiply_by       = ${toString pllBusMultBy};
        defparam u_altpll_bus.clk0_phase_shift       = "0";
        defparam u_altpll_bus.compensate_clock       = "CLK0";
        defparam u_altpll_bus.inclk0_input_frequency = 20000;
        defparam u_altpll_bus.intended_device_family = "Cyclone II";
        defparam u_altpll_bus.lpm_type               = "altpll";
        defparam u_altpll_bus.operation_mode         = "NORMAL";
        defparam u_altpll_bus.port_clk0              = "PORT_USED";
        defparam u_altpll_bus.port_inclk0            = "PORT_USED";
        defparam u_altpll_bus.port_locked            = "PORT_USED";
        defparam u_altpll_bus.port_areset            = "PORT_USED";
        defparam u_altpll_bus.width_clock            = 5;

        // ===== PLL #3 — core domain (Phase D-1 of multi-PLL split) =======
        // Dedicated PLL for the RISC-V core. Currently produces clkCore
        // at the same rate as clkBus (both 40 MHz default) so behaviour
        // is unchanged — until Phase D-2 lands the actual Soc.hs core/
        // bus split via Riski5.CoreCdcBridge, the riski5 module sees
        // both clocks but doesn't yet domain-split internally. The
        // separate PLL means Quartus's STA reports per-clock Fmax for
        // the core domain independently, and once the bridge wires up
        // we can crank pllCoreMultBy without affecting the bus rate.
        wire [4:0] altpll_core_clk_vec;
        wire       clkCore     = altpll_core_clk_vec[0];
        wire       pll_core_locked;
        altpll u_altpll_core (
            .areset (1'b0),
            .inclk  ({1'b0, CLOCK_50}),
            .clk    (altpll_core_clk_vec),
            .locked (pll_core_locked),
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
        defparam u_altpll_core.bandwidth_type         = "AUTO";
        defparam u_altpll_core.clk0_divide_by         = ${toString pllCoreDivBy};
        defparam u_altpll_core.clk0_duty_cycle        = 50;
        defparam u_altpll_core.clk0_multiply_by       = ${toString pllCoreMultBy};
        defparam u_altpll_core.clk0_phase_shift       = "0";
        defparam u_altpll_core.compensate_clock       = "CLK0";
        defparam u_altpll_core.inclk0_input_frequency = 20000;
        defparam u_altpll_core.intended_device_family = "Cyclone II";
        defparam u_altpll_core.lpm_type               = "altpll";
        defparam u_altpll_core.operation_mode         = "NORMAL";
        defparam u_altpll_core.port_clk0              = "PORT_USED";
        defparam u_altpll_core.port_inclk0            = "PORT_USED";
        defparam u_altpll_core.port_locked            = "PORT_USED";
        defparam u_altpll_core.port_areset            = "PORT_USED";
        defparam u_altpll_core.width_clock            = 5;

        // ===== PLL #2 — SDRAM domain (Phase C of multi-PLL split) ========
        // Independent PLL drives clkSdram (default 133.33 MHz, IS42S16400
        // chip-spec) plus clkDramOut (+90° phase shift) routed to the
        // chip's DRAM_CLK pin. SDRAM controller logic + chip pins both
        // run in this domain; CDC bridge in app/Top.hs crosses the
        // boundary between Riski5.Sdram (DomBus) and SdrController
        // (DomSdram).
        wire [4:0] altpll_sdram_clk_vec;
        wire       clkSdram     = altpll_sdram_clk_vec[0];
        wire       clkDramOut   = altpll_sdram_clk_vec[1];
        wire       pll_sdram_locked;
        altpll u_altpll_sdram (
            .areset (1'b0),
            .inclk  ({1'b0, CLOCK_50}),
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
        defparam u_altpll_sdram.clk1_phase_shift       = "${pllDramPhaseShiftPs}";
        defparam u_altpll_sdram.compensate_clock       = "CLK0";
        defparam u_altpll_sdram.inclk0_input_frequency = 20000;
        defparam u_altpll_sdram.intended_device_family = "Cyclone II";
        defparam u_altpll_sdram.lpm_type               = "altpll";
        defparam u_altpll_sdram.operation_mode         = "NORMAL";
        defparam u_altpll_sdram.port_clk0              = "PORT_USED";
        defparam u_altpll_sdram.port_clk1              = "PORT_USED";
        defparam u_altpll_sdram.port_inclk0            = "PORT_USED";
        defparam u_altpll_sdram.port_locked            = "PORT_USED";
        defparam u_altpll_sdram.port_areset            = "PORT_USED";
        defparam u_altpll_sdram.width_clock            = 5;

        // Task #146: u_altpll_sdram (the second PLL on CLOCK_27 that
        // used to drive the Altera SDRAM Controller IP at 108 MHz
        // CL=3) was removed when the IP itself was removed. The DE2
        // TV Decoder's TD_RESET / TD_CLK27 housekeeping is no longer
        // required because we no longer source any clock from the
        // ADV7180; the chip can sit in reset.
        assign TD_RESET = 1'b0;
        wire   td_clk27_obs = TD_CLK27;  // sink unused input
        wire   clock_27_obs = CLOCK_27;  // sink unused input

        // Combined async-low reset for the bus + core domain. Asserted
        // (low) while the bus PLL hasn't locked or KEY[0] is held.
        wire rstBus_n  = KEY[0] & pll_bus_locked;
        // Phase D-1: rstCore_n now gated by its own PLL's locked
        // signal so the core only comes out of reset after clkCore
        // is stable, independent of rstBus_n. Until Phase D-2 wires
        // up the actual coreCdcBridge between Top.hs's socCore and
        // socBus, the riski5 module sees both clkBus and clkCore but
        // the SoC body still uses one clock internally.
        wire rstCore_n = KEY[0] & pll_core_locked;
        // Phase C: SDRAM reset gated by its own PLL's locked
        // signal so the SdrController only comes out of reset
        // after both KEY[0] is released AND clkSdram is stable.
        // (Both PLLs derive from CLOCK_50; the SDRAM PLL takes
        // longer to lock at 8/3 multiplier than the bus PLL at
        // 4/5, so this matters for boot ordering.)
        wire rstSdram_n = KEY[0] & pll_sdram_locked;

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

        // ----- SDRAM chip-side connections (task #146) ----------------
        // The Clash riski5 module instantiates 'sdrControllerAsAlteraIp'
        // internally and exposes the chip-side pins as outputs. The
        // wrapper just routes them to the DE2 board pads. DRAM_CLK is
        // driven from clkDramOut (PLL clk2, +90° phase-shifted) so the
        // chip's clock edge falls in the middle of the FPGA's stable
        // DQ / command window after the I/O-cell Tco. See the PLL
        // comment block above and pkgs/riski5-core/Riski5.sdc for the
        // matching SDC constraints (virtual clock + set_input_delay /
        // set_output_delay against the IS42S16400-7TL t_DS / t_DH /
        // t_AC / t_OH timings).
        //
        // DRAM_DQ is inout on the top-level port; the Clash module
        // produces SDRAM_DQ_OUT + SDRAM_DQ_OE for the FPGA-drive
        // direction and consumes SDRAM_DQ_IN for what the chip is
        // driving. We resolve the tristate at this boundary.
        wire [15:0] sdram_dq_o;
        wire        sdram_dq_oe;
        assign DRAM_DQ  = sdram_dq_oe ? sdram_dq_o : 16'bz;
        assign DRAM_CLK = clkDramOut;

        // ----- Clash riski5 core --------------------------------------
        wire [31:0]  debug_pcfetch;
        wire [7:0]   debug_flags;
        wire [127:0] debug_frozen_pc;     // 4 × 32-bit pc snapshots
        wire [31:0]  debug_frozen_flags;  // 4 × 8-bit flag snapshots
        wire         debug_reset_capture;
        wire [1:0]   debug_capture_offset; // unused — kept to match port shape
        // Task #46 bridge diagnostic: master is in DomCore, slave in
        // DomBus. Both bytes are sampled by altsource_probes (BDGM,
        // BDGS) below. Bit layout per
        // 'Riski5.CoreCdcBridge.coreCdcBridgeWithDebug' haddock.
        wire [7:0]   debug_bridge_master; // DomCore-clocked
        wire [7:0]   debug_bridge_slave;  // DomBus-clocked
        // Task #46 wide PC probes: 32-bit master mLastSentPc, 32-bit
        // slave sLatReq.cbrPcFetch, 32-bit core-side live pcFetch.
        // Sampled by altsource_probes BPCM, BPCS, BPCC below. Catch
        // bridge-side payload bugs (master fires for X, slave latches
        // Y) and core-stuck bugs (BPCC stays at 0 forever).
        wire [31:0]  debug_bridge_master_pc; // DomCore-clocked
        wire [31:0]  debug_bridge_slave_pc;  // DomBus-clocked
        wire [31:0]  debug_core_pc;          // DomCore-clocked

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
            .CLOCK_BUS    (clkBus),
            .RESET_BUS_N  (rstBus_n),
            .CLOCK_CORE   (clkCore),
            .RESET_CORE_N (rstCore_n),
            .CLOCK_SDRAM  (clkSdram),
            .RESET_SDRAM_N(rstSdram_n),
            .KEY         (KEY),
            .SW          (SW),
            .SRAM_DQ_I   (SRAM_DQ),
            .UART_RDATA  (uart_rdata),
            .UART_READY  (uart_ready),
            .UART_IRQ    (jtag_uart_irq),
            .SDRAM_DQ_IN (DRAM_DQ),
            .DEBUG_RESET_CAPTURE  (debug_reset_capture),
            .DEBUG_CAPTURE_OFFSET (debug_capture_offset),
            .JTAG_LOAD_MODE  (jtag_load_mode),
            .JTAG_LOAD_ADDR  (jtag_load_addr),
            .JTAG_LOAD_WDATA (jtag_load_wdata),
            .JTAG_LOAD_WE    (jtag_load_we),
            .JTAG_LOAD_RD    (jtag_load_rd),
            .JTAG_LOAD_BE    (jam_master_byteenable),
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
            .SDRAM_ADDR_OUT (DRAM_ADDR),
            .SDRAM_BA       (DRAM_BA),
            .SDRAM_CAS_N    (DRAM_CAS_N),
            .SDRAM_CKE      (DRAM_CKE),
            .SDRAM_CS_N     (DRAM_CS_N),
            .SDRAM_DQ_OUT   (sdram_dq_o),
            .SDRAM_DQ_OE    (sdram_dq_oe),
            .SDRAM_DQM      ({DRAM_UDQM, DRAM_LDQM}),
            .SDRAM_RAS_N    (DRAM_RAS_N),
            .SDRAM_WE_N     (DRAM_WE_N),
            .DEBUG_PCFETCH      (debug_pcfetch),
            .DEBUG_FLAGS        (debug_flags),
            .DEBUG_FROZEN_PC    (debug_frozen_pc),
            .DEBUG_FROZEN_FLAGS (debug_frozen_flags),
            .JTAG_LOAD_RDATA    (jtag_load_rdata),
            .JTAG_LOAD_BUSY     (jtag_load_busy),
            .DEBUG_BRIDGE_MASTER (debug_bridge_master),
            .DEBUG_BRIDGE_SLAVE  (debug_bridge_slave),
            .DEBUG_BRIDGE_MASTER_PC (debug_bridge_master_pc),
            .DEBUG_BRIDGE_SLAVE_PC  (debug_bridge_slave_pc),
            .DEBUG_CORE_PC          (debug_core_pc)
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

        // ----- altsource_probe — bridge master FSM state (task #46) -
        // 8 bits sampled in DomCore. Tells us whether the master FSM
        // gets stuck in MIdle (never fires reqIsLive), MBusy (fires
        // but never sees doneEdge), or transitions correctly.
        altsource_probe #(
            .lpm_type                 ("altsource_probe"),
            .lpm_hint                 ("CBX_AUTO_BLACKBOX=ALL"),
            .source_width             (0),
            .probe_width              (8),
            .instance_id              ("BDGM"),
            .sld_ir_width             (3),
            .source_initial_value     ("0"),
            .sld_auto_instance_index  ("YES"),
            .sld_instance_index       (15),
            .enable_metastability     ("NO")
        ) u_bridge_master_probe (
            .probe        (debug_bridge_master),
            .source       (),
            .source_clk   (1'b0),
            .source_ena   (1'b0)
        );

        // ----- altsource_probe — bridge slave FSM state (task #46) --
        // 8 bits sampled in DomBus. Tells us whether the slave FSM
        // sees the master's toggle edge (SIdle→SDrive), settles into
        // SServe, captures the bus reply, and toggles done back.
        altsource_probe #(
            .lpm_type                 ("altsource_probe"),
            .lpm_hint                 ("CBX_AUTO_BLACKBOX=ALL"),
            .source_width             (0),
            .probe_width              (8),
            .instance_id              ("BDGS"),
            .sld_ir_width             (3),
            .source_initial_value     ("0"),
            .sld_auto_instance_index  ("YES"),
            .sld_instance_index       (16),
            .enable_metastability     ("NO")
        ) u_bridge_slave_probe (
            .probe        (debug_bridge_slave),
            .source       (),
            .source_clk   (1'b0),
            .source_ena   (1'b0)
        );

        // ----- altsource_probe — bridge master mLastSentPc (task #46) -
        // 32-bit DomCore-side probe. The most recent PC the master
        // FSM fired a transaction for. Combined with BPCC (core's live
        // pcFetch), this distinguishes "core PC stuck" (BPCC ==
        // BPCM == 0) from "core PC moves but bridge can't keep up"
        // (BPCC > BPCM).
        altsource_probe #(
            .lpm_type                 ("altsource_probe"),
            .lpm_hint                 ("CBX_AUTO_BLACKBOX=ALL"),
            .source_width             (0),
            .probe_width              (32),
            .instance_id              ("BPCM"),
            .sld_ir_width             (3),
            .source_initial_value     ("0"),
            .sld_auto_instance_index  ("YES"),
            .sld_instance_index       (17),
            .enable_metastability     ("NO")
        ) u_bridge_master_pc_probe (
            .probe        (debug_bridge_master_pc),
            .source       (),
            .source_clk   (1'b0),
            .source_ena   (1'b0)
        );

        // ----- altsource_probe — bridge slave sLatReq.pcFetch (task #46)
        // 32-bit DomBus-side probe. The PC the slave most recently
        // latched from the master's payload. If BPCS != BPCM steadily
        // (not just for the few cycles each takes to register), the
        // bridge's bus-side syncBitVector has a CDC bug.
        altsource_probe #(
            .lpm_type                 ("altsource_probe"),
            .lpm_hint                 ("CBX_AUTO_BLACKBOX=ALL"),
            .source_width             (0),
            .probe_width              (32),
            .instance_id              ("BPCS"),
            .sld_ir_width             (3),
            .source_initial_value     ("0"),
            .sld_auto_instance_index  ("YES"),
            .sld_instance_index       (18),
            .enable_metastability     ("NO")
        ) u_bridge_slave_pc_probe (
            .probe        (debug_bridge_slave_pc),
            .source       (),
            .source_clk   (1'b0),
            .source_ena   (1'b0)
        );

        // ----- altsource_probe — core-side live pcFetch (task #46) ---
        // 32-bit DomCore-side probe. The actual PC the core is asserting
        // *right now* on its imem fetch port. If BPCC stays at 0 forever
        // the core itself never advances past reset_pc — bridge would
        // never fire either, and silicon hang is upstream of the bridge.
        // If BPCC advances but BPCM lags, the bridge is the bottleneck.
        altsource_probe #(
            .lpm_type                 ("altsource_probe"),
            .lpm_hint                 ("CBX_AUTO_BLACKBOX=ALL"),
            .source_width             (0),
            .probe_width              (32),
            .instance_id              ("BPCC"),
            .sld_ir_width             (3),
            .source_initial_value     ("0"),
            .sld_auto_instance_index  ("YES"),
            .sld_instance_index       (19),
            .enable_metastability     ("NO")
        ) u_core_pc_probe (
            .probe        (debug_core_pc),
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

        // ----- altsource_probe — last DRAM_* WRITE / READ snapshot --
        // Task #146 hardware-fault diagnostic: capture the DRAM_*
        // pin values at every WRITE / READ command edge so we can
        // compare what the FPGA *actually* drove (= the I/O-cell
        // flop output going onto the pad) against what the
        // SdrController INTENDED to drive. Pre-fix the chip was
        // returning the correct hi-half + dropped lo-half pattern
        // (`wrote 0xdeadbeef → read 0xdeaddead`). After the SDC +
        // FAST_OUTPUT_REGISTER + +90° DRAM_CLK landed, STA closed
        // (+2.4 ns slack) but the silicon symptom is unchanged —
        // and a DRAM_ADDR[0] ↔ DRAM_ADDR[1] pin-swap test (move
        // the col-LSB to chip A1 instead of chip A0) didn't change
        // the failure pattern either, ruling out single-pin stuck
        // faults on PIN_T6 / chip A0. Reading LSWP after a known
        // master_write_32 will show whether the FPGA pin-side ADDR
        // / DQ / BA / DQM actually toggle as expected, or whether
        // something inside the wrapper / fabric path is collapsing
        // the col-LSB.
        //
        // LSWP layout (LSB-first, easy to bit-extract from Tcl):
        //   [7:0]    write_count   (8-bit count of WRITE commands seen, wraps)
        //   [15:8]   read_count    (8-bit count of READ commands seen, wraps)
        //   [27:16]  last_write_addr (DRAM_ADDR[11:0] at WRITE edge)
        //   [29:28]  last_write_ba   (DRAM_BA[1:0] at WRITE edge)
        //   [31:30]  last_write_dqm  ({DRAM_UDQM, DRAM_LDQM} at WRITE edge)
        //   [47:32]  last_write_dq   (DRAM_DQ[15:0] at WRITE edge)
        //   [59:48]  last_read_addr  (DRAM_ADDR[11:0] at READ edge)
        //   [63:60]  reserved
        //
        // Trigger condition: WRITE = CS_N=0, RAS_N=1, CAS_N=0, WE_N=0.
        //                    READ  = CS_N=0, RAS_N=1, CAS_N=0, WE_N=1.
        // Both sample the values directly off the (registered) chip-
        // bound pins so the Tco of the FAST_OUTPUT_REGISTER cell IS
        // already accounted for — what we capture is what the chip
        // pad sees on the same edge.
        wire dram_is_write_cmd = (DRAM_CS_N == 1'b0)
                              && (DRAM_RAS_N == 1'b1)
                              && (DRAM_CAS_N == 1'b0)
                              && (DRAM_WE_N == 1'b0);
        wire dram_is_read_cmd  = (DRAM_CS_N == 1'b0)
                              && (DRAM_RAS_N == 1'b1)
                              && (DRAM_CAS_N == 1'b0)
                              && (DRAM_WE_N == 1'b1);

        reg [11:0] last_write_addr_r = 12'h000;
        reg [1:0]  last_write_ba_r   = 2'b00;
        reg [15:0] last_write_dq_r   = 16'h0000;
        reg [1:0]  last_write_dqm_r  = 2'b00;
        reg [11:0] last_read_addr_r  = 12'h000;
        reg [7:0]  write_count_r     = 8'h00;
        reg [7:0]  read_count_r      = 8'h00;

        always @(posedge clkBus or negedge rstBus_n) begin
            if (!rstBus_n) begin
                last_write_addr_r <= 12'h000;
                last_write_ba_r   <= 2'b00;
                last_write_dq_r   <= 16'h0000;
                last_write_dqm_r  <= 2'b00;
                last_read_addr_r  <= 12'h000;
                write_count_r     <= 8'h00;
                read_count_r      <= 8'h00;
            end else begin
                if (dram_is_write_cmd) begin
                    // DRAM_DQ is bidirectional; during the WRITE edge
                    // the FPGA owns it (DqOe=True for that cycle), so
                    // sampling the pad value gives us the data the
                    // chip is supposed to latch.
                    last_write_addr_r <= DRAM_ADDR;
                    last_write_ba_r   <= DRAM_BA;
                    last_write_dq_r   <= DRAM_DQ;
                    last_write_dqm_r  <= {DRAM_UDQM, DRAM_LDQM};
                    write_count_r     <= write_count_r + 8'h01;
                end
                if (dram_is_read_cmd) begin
                    last_read_addr_r <= DRAM_ADDR;
                    read_count_r    <= read_count_r + 8'h01;
                end
            end
        end

        wire [63:0] sdram_pin_probe = {
            4'b0000,            // [63:60] reserved
            last_read_addr_r,   // [59:48]
            last_write_dq_r,    // [47:32]
            last_write_dqm_r,   // [31:30]
            last_write_ba_r,    // [29:28]
            last_write_addr_r,  // [27:16]
            read_count_r,       // [15:8]
            write_count_r       // [7:0]
        };

        altsource_probe #(
            .lpm_type                 ("altsource_probe"),
            .lpm_hint                 ("CBX_AUTO_BLACKBOX=ALL"),
            .source_width             (0),
            .probe_width              (64),
            .instance_id              ("LSWP"),
            .sld_ir_width             (3),
            .source_initial_value     ("0"),
            .sld_auto_instance_index  ("YES"),
            .sld_instance_index       (8),
            .enable_metastability     ("NO")
        ) u_sdram_pin_probe (
            .probe        (sdram_pin_probe),
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
