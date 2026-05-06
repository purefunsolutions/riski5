# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# Build the rv32 nommu Linux kernel for riski5. Source comes from
# nixpkgs's pinned `linux_6_18` (matches the user's preference for
# 6.18 from the L-* planning Q&A). We layer three configs:
#
#   1. arch/riscv/configs/nommu_virt_defconfig — base nommu profile
#      that already turns on most of what we need.
#   2. arch/riscv/configs/32-bit.config         — switches to RV32.
#   3. ./riski5-overlay.config                  — riski5-specific
#      bits: bootargs, JTAG-UART driver, size cuts.
#
# Output: $out/Image (raw kernel binary, ready to load into SDRAM
# via the L-3b loader), $out/vmlinux (ELF, for Spike/sim debug),
# and $out/config (the merged config we actually built with).
#
# The build is __slow__ (~5 min on a beefy host, longer in our
# CI). The Nix derivation caches it across rebuilds. Trigger
# manually with `nix build .#linux-rv32-nommu`; the L-9 silicon
# bring-up flake output will depend on it.
{
  stdenv,
  lib,
  linux_6_18,
  linux_6_12,
  linux_6_6,
  # Pick which upstream kernel to base the build on. Default 6.18
  # (current stable). Override with "6.12" or "6.6" (LTS) for
  # bisecting suspected scheduler / nommu bugs without rebuilding
  # the whole pipeline.
  kernelChoice ? "6.18",
  # #64 debug: sprinkle pr_emerg() calls at rest_init /
  # kernel_init_freeable / kthreadd_done to see where the boot
  # silently wedges past Mountpoint-cache. Off by default — toggle
  # via the package call's debugSchedulerPrintks arg.
  debugSchedulerPrintks ? false,
  pkgsCross,
  bc,
  bison,
  flex,
  cpio,
  perl,
  openssl,
  pahole,
  elfutils,
  # Optional cpio path to embed as the initramfs. When non-null,
  # the kernel build sets CONFIG_INITRAMFS_SOURCE = <path>; when
  # null, the kernel boots without an initramfs (useful for early
  # bring-up — boot panics on rdinit=/init failure but the panic
  # message itself proves Linux ran).
  initramfs ? null,
}: let
  ccPkg = pkgsCross.riscv64.buildPackages.gcc;
  cc = "${ccPkg}/bin/riscv64-unknown-linux-gnu-";
  upstream =
    if kernelChoice == "6.12" then linux_6_12
    else if kernelChoice == "6.6" then linux_6_6
    else linux_6_18;
in
  stdenv.mkDerivation {
    pname = "riski5-linux-rv32-nommu";
    inherit (upstream) version src;

    nativeBuildInputs = [
      ccPkg
      bc
      bison
      flex
      cpio
      perl
      openssl
      pahole
      elfutils
    ];

    # Kernel objects fail this; the kernel emits BFD-format ELFs
    # that nixpkgs's elf-fixup mishandles.
    dontStrip = true;
    dontFixup = true;
    dontPatchELF = true;

    # #64 debug: sprinkle pr_emerg() calls in init/main.c at the
    # entries of rest_init / kernel_init / kernel_init_freeable so
    # we can watch (via the keep_bootcon earlycon) exactly how far
    # past Mountpoint-cache the boot gets. Toggle by setting
    # `debugSchedulerPrintks = true` on the package call.
    prePatch = lib.optionalString debugSchedulerPrintks ''
      # Patch init/main.c to add KERN_EMERG markers at every step of
      # kernel_init_freeable so we can see exactly where the boot
      # silently wedges in 6.18 nommu on this SoC. Uses sed (immune
      # to line-number drift) — checks every key call site.
      sed -i \
        -e 's|cad_pid = get_pid(task_pid(current));|pr_emerg("DBG64: kernel_init_freeable entered\\n");\n\tcad_pid = get_pid(task_pid(current));|' \
        -e 's|smp_prepare_cpus(setup_max_cpus);|pr_emerg("DBG64: pre smp_prepare_cpus\\n");\n\tsmp_prepare_cpus(setup_max_cpus);|' \
        -e 's|workqueue_init();|pr_emerg("DBG64: pre workqueue_init\\n");\n\tworkqueue_init();\n\tpr_emerg("DBG64: post workqueue_init\\n");|' \
        -e 's|init_mm_internals();|pr_emerg("DBG64: pre init_mm_internals\\n");\n\tinit_mm_internals();\n\tpr_emerg("DBG64: post init_mm_internals\\n");|' \
        -e 's|rcu_init_tasks_generic();|pr_emerg("DBG64: pre rcu_init_tasks_generic\\n");\n\trcu_init_tasks_generic();|' \
        -e 's|do_pre_smp_initcalls();|pr_emerg("DBG64: pre do_pre_smp_initcalls\\n");\n\tdo_pre_smp_initcalls();|' \
        -e 's|lockup_detector_init();|pr_emerg("DBG64: pre lockup_detector_init\\n");\n\tlockup_detector_init();|' \
        -e 's|smp_init();|pr_emerg("DBG64: pre smp_init\\n");\n\tsmp_init();|' \
        -e 's|sched_init_smp();|pr_emerg("DBG64: pre sched_init_smp\\n");\n\tsched_init_smp();|' \
        -e 's|do_basic_setup();|pr_emerg("DBG64: pre do_basic_setup\\n");\n\tdo_basic_setup();\n\tpr_emerg("DBG64: post do_basic_setup\\n");|' \
        -e 's|wait_for_completion(&kthreadd_done);|wait_for_completion(\&kthreadd_done);\n\tpr_emerg("DBG64: kthreadd_done complete\\n");|' \
        init/main.c
      grep -c DBG64 init/main.c || true

      # #64-step2: workqueue_init wedges. Sprinkle inside it to find
      # which sub-step hangs. The previous kernel reached
      # "DBG64: pre workqueue_init" but never printed "post" — wedge
      # is between the two. Fine markers narrow it to: thresh_init,
      # BH worker create, online cpu_worker create, unbound pool
      # worker create, wq_online=true, wq_watchdog_init.
      sed -i \
        -e 's|wq_cpu_intensive_thresh_init();|pr_emerg("DBG64-WQ: pre thresh_init\\n");\n\twq_cpu_intensive_thresh_init();\n\tpr_emerg("DBG64-WQ: post thresh_init\\n");|' \
        -e 's|hash_for_each(unbound_pool_hash, bkt, pool, hash_node)|pr_emerg("DBG64-WQ: pre unbound_pool create_worker\\n");\n\thash_for_each(unbound_pool_hash, bkt, pool, hash_node)|' \
        -e 's|wq_online = true;|pr_emerg("DBG64-WQ: pre wq_online=true\\n");\n\twq_online = true;|' \
        -e 's|wq_watchdog_init();|pr_emerg("DBG64-WQ: pre wq_watchdog_init\\n");\n\twq_watchdog_init();\n\tpr_emerg("DBG64-WQ: post wq_watchdog_init\\n");|' \
        kernel/workqueue.c
      grep -c DBG64-WQ kernel/workqueue.c || true
    '';

    KBUILD_BUILD_VERSION = "1-riski5";
    KBUILD_BUILD_TIMESTAMP = "Thu Jan  1 00:00:00 UTC 1970";

    configurePhase = ''
      runHook preConfigure

      # Step 1 + 2: nommu_virt + 32-bit.
      make ARCH=riscv CROSS_COMPILE=${cc} \
        nommu_virt_defconfig 32-bit.config

      # Step 3: riski5 overlay. Append to .config and rerun
      # olddefconfig so dependent symbols settle.
      cat ${./riski5-overlay.config} >> .config

      ${lib.optionalString (initramfs != null) ''
        # Embed the supplied cpio.gz at link time.
        sed -i 's|^CONFIG_INITRAMFS_SOURCE=.*|CONFIG_INITRAMFS_SOURCE="${initramfs}/initramfs.cpio"|' .config
      ''}

      make ARCH=riscv CROSS_COMPILE=${cc} olddefconfig

      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      make ARCH=riscv CROSS_COMPILE=${cc} -j$NIX_BUILD_CORES Image
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp arch/riscv/boot/Image  $out/Image
      cp vmlinux                $out/vmlinux
      cp .config                $out/config
      runHook postInstall
    '';

    meta = with lib; {
      description = "rv32 nommu Linux kernel for riski5 (Altera DE2)";
      license = licenses.gpl2Only;
      platforms = ["x86_64-linux"];
    };
  }
