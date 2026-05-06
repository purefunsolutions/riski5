-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : HelloSchedStress
Description : Stress test for cooperative context switching (task #64).

The 1B-cycle Linux-boot trace in #64 narrowed the silicon hang to
"resuming a previously-sleeping task does not work, but spawning a
new task does". The Linux kernel's @__switch_to@ saves @ra/sp/s0-s11@
to the outgoing task's @task_struct.thread@ slot and loads the same
from the incoming task. After all the kernel housekeeping around it
(CFS rbtree, runqueue lock, irqentry_exit, ...), the bug only
materialises on the *second* visit of a kthread (kthreadd) — i.e.
when the registers being loaded have ALSO been STORED by an earlier
context switch.

This firmware reproduces the same pattern at the byte level, with no
SoC bus / Linux noise:

  - Two cooperative \"tasks\" share BRAM (no MMU, no scheduler,
    no IRQs). Each task has a context block of 14 words holding
    @ra/sp/s0..s11@.
  - 'switch_to(curr_ctx, next_ctx)' stores the live @ra/sp/s0-s11@
    into @curr_ctx@, loads the same fields from @next_ctx@, then
    'ret's. Identical instruction sequence to RV32 Linux's
    @__switch_to@ (modulo the @tp@ swap, which we don't have a
    cheap analogue for).
  - Task 0 runs in main(), prints @'A'@, switches to task 1.
  - Task 1 prints @'b'@ (lowercase to distinguish), switches back
    to task 0.
  - On every successful round trip task 0 also prints @'.'@.

Expected silicon stream: @BAb.Ab.Ab.…@ (the @'B'@ boot byte once,
then @Ab.@ repeating forever).

If the wake-from-sleep bug observed in #64 reproduces here, the
stream stalls after some prefix (e.g. @BAb@ before the second
@switch_to(task0_ctx, task1_ctx)@ wedges), and the JTAG-UART
commit counter on silicon stops incrementing.

== Memory layout

The BRAM-mapped data port in 'Riski5.Soc.socWithExternalCore' is
read-only ("writes to SlaveBram silently drop"), so we put the
mutable scheduler state in SRAM:

  - @0x0000_0000..0x0000_???@ : code (this firmware), in BRAM.
  - @0x2000_0000..0x2000_0037@ : task 0 context (14 words).
  - @0x2000_0040..0x2000_0077@ : task 1 context (14 words).
  - @0x2000_00C0..0x2000_00FF@ : task 0 stack (top @0x2000_0100@,
                                  grows down 64 B).
  - @0x2000_0100..0x2000_013F@ : task 1 stack (top @0x2000_0140@,
                                  grows down 64 B).

The contexts and stacks together cost \<320 B; the SRAM has 512 KB,
so plenty of headroom.

== Why BRAM-only

Same reasoning as 'HelloMdStress': isolate the core's behaviour
from any bus / bridge / external-memory paths so that a hang here
unambiguously means the context-save / context-restore sequence
itself is broken on silicon.
-}
module HelloSchedStress (
  helloSchedStressFirmware,
  helloSchedStressFirmwareWords,
) where

import Clash.Prelude (BitVector)
import Data.Either qualified as DE
import Riski5.Asm
import Riski5.ISA
import Prelude qualified as P

-- * Firmware -------------------------------------------------------

helloSchedStressFirmware :: Asm ()
helloSchedStressFirmware = do
  -- Constant register file:
  --   x10 = UART data register pointer  (= 0x1000_0000)
  --   x11 = task 0 context base pointer (= 0xE00)
  --   x12 = task 1 context base pointer (= 0xE40)
  --   x14 = scratch / per-byte char
  --   x15 = scratch
  let uartReg     = x10
      task0CtxReg = x11
      task1CtxReg = x12

  li uartReg     0x1000_0000

  -- 'B' boot byte. Confirms BRAM exec + UART are alive before any
  -- context switch happens. If we never see 'B' on silicon, the
  -- problem is much earlier than wake-from-sleep.
  li x14 0x42
  sw uartReg x14 0

  li task0CtxReg 0x2000_0000
  li task1CtxReg 0x2000_0040

  -- Set up the initial task-1 stack pointer (top of task-1's stack).
  -- The first switch into task 1 will load this into sp.
  li x14 0x2000_0140          -- top of task 1 stack
  sw task1CtxReg x14 4        -- task1_ctx[1] = task1_sp_init

  -- Now compute the address of @task1_init@ (the first instruction
  -- task 1 will run) and store it as task1_ctx.ra. We use the
  -- @jal x14, over_task1_init@ trick: JAL writes (PC+4) into x14,
  -- which equals the address of the instruction RIGHT AFTER the
  -- JAL. We arrange for @task1_init@ to live exactly at that PC+4
  -- by placing the JAL target ('overTask1InitL') beyond
  -- @task1_init@'s body. The JAL then both: (a) leaves task 1's
  -- entry point in x14, and (b) jumps over task 1's body so we
  -- don't run it on the main path.
  overTask1InitL <- labelUnplaced
  jal x14 overTask1InitL
  -- ↓ task 1's first-time entry. x14 already points HERE for the
  --   parent (main / task 0), so we're about to record this address
  --   in task1_ctx.ra. Task 1 itself enters here on its first
  --   resumption (when the very first switch_to(task0, task1)
  --   loads x1 from task1_ctx.ra and `ret`s).
  --
  -- The body below mirrors task 1's main loop without any
  -- pre-amble — it must be self-contained because there is no
  -- "function call" wrapper around it.
  task1LoopL <- label
  -- Print 'b' (task-1 marker)
  li x14 0x62
  sw uartReg x14 0
  -- Switch back to task 0. switchTo expects:
  --   x11 = curr ctx, x12 = next ctx
  -- We're task 1 now, so swap them via a temporary.
  switchTask1ToTask0L <- labelUnplaced
  jal x1 switchTask1ToTask0L
  -- After switch_to returns we're STILL task 1 (resumed). Loop.
  j task1LoopL

  placeAt overTask1InitL
  -- ↑ x14 now equals @task1_init@'s address (one instruction past
  --   the JAL above). Save it as task1_ctx.ra so the first
  --   switch_to(task0, task1) lands there.
  sw task1CtxReg x14 0        -- task1_ctx[0] = task1_init_addr

  -- Zero out task 1's s0..s11 (12 words at offsets 8..52). We don't
  -- care about the values, but leaving them undefined would make
  -- the first context-restore noisy.
  -- NB: Also zero task 1's @ra@ slot? No — we just wrote it above.
  --     Zero offsets 8..52 inclusive (12 words = 48 bytes).
  li x14 8
  zeroLoopL <- label
  add x15 task1CtxReg x14
  sw x15 x0 0
  addi x14 x14 4
  addi x15 x0 56              -- stop when x14 == 56 (= 8 + 12*4)
  bne x14 x15 zeroLoopL

  -- Same zero-init for task 0's context (it'll be overwritten by
  -- the very first switch_to anyway, but explicit init keeps any
  -- "ghost run before save" deterministic).
  li x14 0
  zeroLoop0L <- label
  add x15 task0CtxReg x14
  sw x15 x0 0
  addi x14 x14 4
  addi x15 x0 56
  bne x14 x15 zeroLoop0L

  -- Initial main-task stack pointer. We don't strictly need a real
  -- stack for the loop body below (the body has no function calls
  -- besides switch_to), but keeping sp valid means
  -- switch_to's "save ra/sp" stores something coherent.
  li x2 0x2000_0100            -- top of task 0 stack

  -- ----------------------------------------------------------------
  -- Main loop (task 0).
  -- ----------------------------------------------------------------
  task0LoopL <- label
  -- Print 'A' (task-0 marker)
  li x14 0x41
  sw uartReg x14 0
  -- Switch to task 1.
  switchTask0ToTask1L <- labelUnplaced
  jal x1 switchTask0ToTask1L
  -- Resumed (woke up from being switched-out). Print '.' to mark
  -- a successful round trip, then loop.
  li x14 0x2E
  sw uartReg x14 0
  j task0LoopL

  -- ----------------------------------------------------------------
  -- switch_to wrappers.
  -- We can't pass arguments to a label-call easily, so use two
  -- thin wrappers that load the (curr, next) ctx pair into known
  -- registers (x6 = curr, x7 = next) before tail-calling the
  -- shared switch_to body.
  -- ----------------------------------------------------------------
  switchToCommonL <- labelUnplaced

  placeAt switchTask0ToTask1L
  -- Caller (task 0) wants: curr = task0_ctx, next = task1_ctx.
  -- ra (x1) was set by the caller's `jal x1 switchTask0ToTask1L`.
  -- We must preserve x1 (it's part of the saved state being switched
  -- out) — switch_to_common will sw x1 to curr_ctx[0].
  add x6 x0 task0CtxReg
  add x7 x0 task1CtxReg
  j switchToCommonL

  placeAt switchTask1ToTask0L
  -- Caller (task 1) wants: curr = task1_ctx, next = task0_ctx.
  add x6 x0 task1CtxReg
  add x7 x0 task0CtxReg
  j switchToCommonL

  -- Shared switch_to body. Mirrors the kernel's __switch_to:
  --   1. Save x1 (ra), x2 (sp), x8 (s0), x9 (s1), x18..x27 (s2..s11)
  --      into curr_ctx (= x6) at offsets 0..52 (14 words).
  --   2. Load the same regs from next_ctx (= x7).
  --   3. ret (jalr x0, x1, 0).
  --
  -- Layout of the 14-word context block:
  --   [0]  ra
  --   [1]  sp
  --   [2]  s0
  --   [3]  s1
  --   [4]  s2
  --   ...
  --   [13] s11
  placeAt switchToCommonL
  sw x6 x1 0                  -- save ra
  sw x6 x2 4                  -- save sp
  sw x6 x8 8                  -- save s0
  sw x6 x9 12                 -- save s1
  sw x6 x18 16                -- save s2
  sw x6 x19 20                -- save s3
  sw x6 x20 24                -- save s4
  sw x6 x21 28                -- save s5
  sw x6 x22 32                -- save s6
  sw x6 x23 36                -- save s7
  sw x6 x24 40                -- save s8
  sw x6 x25 44                -- save s9
  sw x6 x26 48                -- save s10
  sw x6 x27 52                -- save s11

  lw x1 x7 0                  -- load ra
  lw x2 x7 4                  -- load sp
  lw x8 x7 8                  -- load s0
  lw x9 x7 12                 -- load s1
  lw x18 x7 16                -- load s2
  lw x19 x7 20                -- load s3
  lw x20 x7 24                -- load s4
  lw x21 x7 28                -- load s5
  lw x22 x7 32                -- load s6
  lw x23 x7 36                -- load s7
  lw x24 x7 40                -- load s8
  lw x25 x7 44                -- load s9
  lw x26 x7 48                -- load s10
  lw x27 x7 52                -- load s11

  jalr x0 x1 0                -- ret

helloSchedStressFirmwareWords :: [BitVector 32]
helloSchedStressFirmwareWords =
  case assemble helloSchedStressFirmware of
    DE.Right ws -> ws
    DE.Left e -> P.error ("HelloSchedStress assembly failed: " P.++ P.show e)
