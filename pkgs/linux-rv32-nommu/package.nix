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
        -e 's|async_synchronize_full();|pr_emerg("DBG64: pre async_synchronize_full\\n");\n\tasync_synchronize_full();\n\tpr_emerg("DBG64: post async_synchronize_full\\n");|' \
        -e 's|kprobe_free_init_mem();|pr_emerg("DBG64: pre kprobe_free_init_mem\\n");\n\tkprobe_free_init_mem();|' \
        -e 's|free_initmem();|pr_emerg("DBG64: pre free_initmem\\n");\n\tfree_initmem();\n\tpr_emerg("DBG64: post free_initmem\\n");|' \
        -e 's|mark_readonly();|pr_emerg("DBG64: pre mark_readonly\\n");\n\tmark_readonly();|' \
        -e 's|rcu_end_inkernel_boot();|pr_emerg("DBG64: pre rcu_end_inkernel_boot\\n");\n\trcu_end_inkernel_boot();\n\tpr_emerg("DBG64: post rcu_end_inkernel_boot\\n");|' \
        -e 's|do_sysctl_args();|pr_emerg("DBG64: pre do_sysctl_args\\n");\n\tdo_sysctl_args();\n\tpr_emerg("DBG64: post do_sysctl_args\\n");|' \
        init/main.c
      grep -c DBG64 init/main.c || true

      # #64-step2: workqueue_init wedges. Sprinkle inside it to find
      # which sub-step hangs. The previous kernel reached
      # "DBG64: pre workqueue_init" but never printed "post" — wedge
      # is between the two. Fine markers narrow it to: thresh_init,
      # BH worker create, online cpu_worker create, unbound pool
      # worker create, wq_online=true, wq_watchdog_init.
      #
      # #64-step3: thresh_init completed; wedge is between
      # post-thresh_init and pre-unbound_pool. Add finer markers
      # around the early-rescuer WARN, BH worker create loop, and
      # online cpu_worker_pool create loop.
      sed -i \
        -e 's|wq_cpu_intensive_thresh_init();|pr_emerg("DBG64-WQ: pre thresh_init\\n");\n\twq_cpu_intensive_thresh_init();\n\tpr_emerg("DBG64-WQ: post thresh_init\\n");|' \
        -e 's|WARN(init_rescuer(wq),|pr_emerg("DBG64-WQ: pre init_rescuer WARN loop\\n");\n\t\tWARN(init_rescuer(wq),|' \
        -e 's| \* possible CPUs here\.| * possible CPUs here.\n\t * DBG64-WQ marker below: pre BH create_worker loop|' \
        -e 's|hash_for_each(unbound_pool_hash, bkt, pool, hash_node)|pr_emerg("DBG64-WQ: pre unbound_pool create_worker\\n");\n\thash_for_each(unbound_pool_hash, bkt, pool, hash_node)|' \
        -e 's|wq_online = true;|pr_emerg("DBG64-WQ: pre wq_online=true\\n");\n\twq_online = true;|' \
        -e 's|wq_watchdog_init();|pr_emerg("DBG64-WQ: pre wq_watchdog_init\\n");\n\twq_watchdog_init();\n\tpr_emerg("DBG64-WQ: post wq_watchdog_init\\n");|' \
        kernel/workqueue.c
      # The BH-loop marker needs to actually emit code, not just a
      # comment — add it via line-anchored insertion.
      sed -i '/DBG64-WQ marker below: pre BH create_worker loop/a\\tpr_emerg("DBG64-WQ: pre BH create_worker loop\\n");' kernel/workqueue.c
      # Instrument create_worker() itself: print every entry + post
      # kthread_create_on_node + post wake_up_process. The unique
      # "ID is needed to determine kthread name" comment anchors it.
      sed -i 's|/\* ID is needed to determine kthread name \*/|/* ID is needed to determine kthread name */\n\tpr_emerg("DBG64-CW: enter create_worker pool_id=%d flags=0x%x\\n", pool->id, pool->flags);|' kernel/workqueue.c
      sed -i 's|kthread_bind_mask(worker->task, pool_allowed_cpus(pool));|kthread_bind_mask(worker->task, pool_allowed_cpus(pool));\n\t\tpr_emerg("DBG64-CW: post kthread_create+bind worker_id=%d\\n", worker->id);|' kernel/workqueue.c
      sed -i 's|wake_up_process(worker->task);|wake_up_process(worker->task);\n\t\tpr_emerg("DBG64-CW: post wake_up_process worker_id=%d\\n", worker->id);|' kernel/workqueue.c
      grep -c DBG64-WQ kernel/workqueue.c || true
      grep -c DBG64-CW kernel/workqueue.c || true

      # #64-step5: kernel hangs INSIDE devtmpfs_init at
      # wait_for_completion(&setup_done) — the kdevtmpfs kthread does
      # ksys_unshare + init_mount("devtmpfs","/",...) + init_chdir +
      # init_chroot. Sprinkle markers so we can see exactly which call
      # wedges. The "devtmpfs: initialized" pr_info fires BEFORE this
      # path; the missing "initcall ... returned" tells us we never
      # exit devtmpfs_init.
      sed -i \
        -e 's|err = ksys_unshare(CLONE_NEWNS);|pr_emerg("DBG64-DT: pre ksys_unshare\\n"); err = ksys_unshare(CLONE_NEWNS);\n\tpr_emerg("DBG64-DT: post ksys_unshare err=%d\\n", err);|' \
        -e 's|err = init_mount("devtmpfs", "/", "devtmpfs", DEVTMPFS_MFLAGS, NULL);|pr_emerg("DBG64-DT: pre init_mount /\\n"); err = init_mount("devtmpfs", "/", "devtmpfs", DEVTMPFS_MFLAGS, NULL);\n\tpr_emerg("DBG64-DT: post init_mount / err=%d\\n", err);|' \
        -e 's|init_chdir("/..");|pr_emerg("DBG64-DT: pre init_chdir\\n"); init_chdir("/..");\n\tpr_emerg("DBG64-DT: post init_chdir\\n");|' \
        -e 's|init_chroot(".");|pr_emerg("DBG64-DT: pre init_chroot\\n"); init_chroot(".");\n\tpr_emerg("DBG64-DT: post init_chroot\\n");|' \
        drivers/base/devtmpfs.c
      grep -c DBG64-DT drivers/base/devtmpfs.c || true

      # #64-step6: pr_debug-via-tracepoint isn't firing for non-early
      # initcalls — only the 10 early ones print "calling/returned".
      # Force it by switching KERN_DEBUG → KERN_EMERG so all
      # initcall_debug calls go to the JTAG-UART unconditionally.
      sed -i 's|printk(KERN_DEBUG "calling  %pS|printk(KERN_EMERG "calling  %pS|' init/main.c
      sed -i 's|printk(KERN_DEBUG "initcall %pS returned|printk(KERN_EMERG "initcall %pS returned|' init/main.c
      sed -i 's|printk(KERN_DEBUG "entering initcall level:|printk(KERN_EMERG "entering initcall level:|' init/main.c
      grep -c "KERN_EMERG \"calling\\|KERN_EMERG \"initcall\\|KERN_EMERG \"entering initcall" init/main.c || true

      # #64-step7: KERN_EMERG via tracepoint still didn't fire for
      # non-early initcalls (tracepoint registration issue?). Inject
      # a direct pr_emerg in do_one_initcall — bypasses the trace
      # mechanism entirely. Anchor on "do_trace_initcall_start(fn);"
      # which is unique inside do_one_initcall.
      #
      # #64-step8: pr_emerg STILL only prints for early initcalls.
      # Bypass all printk paths — write a single tag char directly
      # to the JTAG-UART MMIO at 0x10000000 around every initcall.
      # I=initcall start, e=end. If I/e show up but DBG64-IC doesn't,
      # the printk path is filtering. If neither shows, do_one_initcall
      # itself isn't being entered for non-early.
      sed -i 's|do_trace_initcall_start(fn);|*(volatile unsigned int *)0x10000000 = 0x49; pr_emerg("DBG64-IC: pre fn=%pS\\n", fn); do_trace_initcall_start(fn);|' init/main.c
      sed -i 's|do_trace_initcall_finish(fn, ret);|do_trace_initcall_finish(fn, ret); pr_emerg("DBG64-IC: post fn=%pS ret=%d\\n", fn, ret); *(volatile unsigned int *)0x10000000 = 0x65;|' init/main.c
      grep -c "DBG64-IC" init/main.c || true

      # #64-step9: KEY DISCOVERY — devtmpfs_init is called DIRECTLY
      # from driver_init(), not via the initcall mechanism. After
      # devtmpfs_init returns, driver_init calls devices_init,
      # buses_init, classes_init, firmware_init, hypervisor_init,
      # faux_bus_init, of_core_init, platform_bus_init,
      # auxiliary_bus_init, memory_dev_init, node_dev_init,
      # cpu_dev_init, container_dev_init. One of those wedges
      # (we never see "DBG64: post do_basic_setup"). Add markers
      # around each so we can pinpoint.
      sed -i \
        -e 's|bdi_init(&noop_backing_dev_info);|pr_emerg("DBG64-DR: pre bdi_init\\n"); bdi_init(\&noop_backing_dev_info); pr_emerg("DBG64-DR: post bdi_init\\n");|' \
        -e 's|devtmpfs_init();|pr_emerg("DBG64-DR: pre devtmpfs_init\\n"); devtmpfs_init(); pr_emerg("DBG64-DR: post devtmpfs_init\\n");|' \
        -e 's|devices_init();|pr_emerg("DBG64-DR: pre devices_init\\n"); devices_init(); pr_emerg("DBG64-DR: post devices_init\\n");|' \
        -e 's|buses_init();|pr_emerg("DBG64-DR: pre buses_init\\n"); buses_init(); pr_emerg("DBG64-DR: post buses_init\\n");|' \
        -e 's|classes_init();|pr_emerg("DBG64-DR: pre classes_init\\n"); classes_init(); pr_emerg("DBG64-DR: post classes_init\\n");|' \
        -e 's|firmware_init();|pr_emerg("DBG64-DR: pre firmware_init\\n"); firmware_init(); pr_emerg("DBG64-DR: post firmware_init\\n");|' \
        -e 's|hypervisor_init();|pr_emerg("DBG64-DR: pre hypervisor_init\\n"); hypervisor_init(); pr_emerg("DBG64-DR: post hypervisor_init\\n");|' \
        -e 's|faux_bus_init();|pr_emerg("DBG64-DR: pre faux_bus_init\\n"); faux_bus_init(); pr_emerg("DBG64-DR: post faux_bus_init\\n");|' \
        -e 's|of_core_init();|pr_emerg("DBG64-DR: pre of_core_init\\n"); of_core_init(); pr_emerg("DBG64-DR: post of_core_init\\n");|' \
        -e 's|platform_bus_init();|pr_emerg("DBG64-DR: pre platform_bus_init\\n"); platform_bus_init(); pr_emerg("DBG64-DR: post platform_bus_init\\n");|' \
        -e 's|auxiliary_bus_init();|pr_emerg("DBG64-DR: pre auxiliary_bus_init\\n"); auxiliary_bus_init(); pr_emerg("DBG64-DR: post auxiliary_bus_init\\n");|' \
        -e 's|memory_dev_init();|pr_emerg("DBG64-DR: pre memory_dev_init\\n"); memory_dev_init(); pr_emerg("DBG64-DR: post memory_dev_init\\n");|' \
        -e 's|node_dev_init();|pr_emerg("DBG64-DR: pre node_dev_init\\n"); node_dev_init(); pr_emerg("DBG64-DR: post node_dev_init\\n");|' \
        -e 's|cpu_dev_init();|pr_emerg("DBG64-DR: pre cpu_dev_init\\n"); cpu_dev_init(); pr_emerg("DBG64-DR: post cpu_dev_init\\n");|' \
        -e 's|container_dev_init();|pr_emerg("DBG64-DR: pre container_dev_init\\n"); container_dev_init(); pr_emerg("DBG64-DR: post container_dev_init\\n");|' \
        drivers/base/init.c
      grep -c DBG64-DR drivers/base/init.c || true

      # #64-step4: instrument kthreadd loop to confirm missed-wakeup
      # hypothesis. After 1st pool worker creates, kthreadd appears
      # to never wake again. Only modify within kthreadd's body
      # (set_current_state appears in worker_thread too — sed range
      # `/int kthreadd/,/^}/` restricts to kthreadd only).
      sed -i 's|cgroup_init_kthreadd();|cgroup_init_kthreadd();\n\tpr_emerg("DBG64-KD: kthreadd entry, before for(;;)\\n");|' kernel/kthread.c
      sed -i '/^int kthreadd(void \*unused)/,/^}/ {
        s|set_current_state(TASK_INTERRUPTIBLE);|pr_emerg("DBG64-KD: top of loop, list_empty=%d, set TASK_INTERRUPTIBLE\\n", list_empty(\&kthread_create_list)); set_current_state(TASK_INTERRUPTIBLE);|
        s|__set_current_state(TASK_RUNNING);|__set_current_state(TASK_RUNNING); pr_emerg("DBG64-KD: woke up, set TASK_RUNNING\\n");|
        s|create_kthread(create);|pr_emerg("DBG64-KD: pre create_kthread\\n"); create_kthread(create); pr_emerg("DBG64-KD: post create_kthread\\n");|
      }' kernel/kthread.c
      grep -c DBG64-KD kernel/kthread.c || true
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
