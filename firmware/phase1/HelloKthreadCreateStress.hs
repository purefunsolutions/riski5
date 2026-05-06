-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoStarIsType #-}

{- |
Module      : HelloKthreadCreateStress
Description : Linux-style kthread-create + completion-wait stress (#64).

The byte-level Linux trace in #64 narrowed the wedge to: kernel_init
calls kthread_create_on_node, which does (paraphrased):

@
  list_add_tail(&request, &kthread_create_list);   -- spin_locked
  wake_up_process(kthreadd_task);
  wait_for_completion(&request->done);             -- blocks here
@

And kthreadd's loop is:

@
  set_current_state(TASK_INTERRUPTIBLE);
  if (list_empty(&kthread_create_list)) schedule();
  __set_current_state(TASK_RUNNING);
  process the request, which eventually fires complete(&request->done);
@

'HelloSchedStress' tests the bare cooperative-yield path
(switch_to + jalr-through-loaded-ra). It passes on hwsim once the
SRAM chip is modelled — so the lw + jalr pattern itself is fine.

This module adds the missing piece: a shared "request" + "completion"
slot in SRAM that one task writes and the other reads. If the bug
turns out to be in the shared-state visibility (write from task A
not visible to task B after a context switch), it surfaces here at
the byte level.

== Per-iteration UART script

  - @A@   : main task wrote request N to SRAM, about to yield
  - @b@   : worker task read request N, wrote completion, yielded back
  - @.@   : main task verified completion[N] == N+1 (worker added 1).
  - @F<x>@: a verification mismatch (e.g. F0 = main saw stale
            completion, F1 = worker saw stale request); halts.

Steady-state stream: @B Ab. Ab. Ab. …@

If the stream truncates (first 'F' or just hangs after 'A') the
synthesised core's write-before-yield + read-after-resume sequence
isn't presenting consistent shared memory — the same corner case
that could explain Linux's silent kthreadd wedge.
-}
module HelloKthreadCreateStress (
  helloKthreadCreateStressFirmware,
  helloKthreadCreateStressFirmwareWords,
) where

import Clash.Prelude (BitVector)
import Data.Either qualified as DE
import Riski5.Asm
import Riski5.ISA
import Prelude qualified as P

-- * Firmware -------------------------------------------------------

helloKthreadCreateStressFirmware :: Asm ()
helloKthreadCreateStressFirmware = do
  -- Same context-switch primitives as HelloSchedStress, plus two
  -- shared-state slots in SRAM:
  --   M[0x2000_0080] = request    (main task writes, worker reads)
  --   M[0x2000_0084] = completion (worker writes, main reads)
  let uartReg     = x10
      task0CtxReg = x11
      task1CtxReg = x12
      sharedReg   = x13         -- base of the shared-state slots

  li uartReg     0x1000_0000
  li task0CtxReg 0x2000_0000
  li task1CtxReg 0x2000_0040
  li sharedReg   0x2000_0080

  -- Boot byte
  li x14 0x42
  sw uartReg x14 0

  -- Initialize shared state to 0
  sw sharedReg x0 0
  sw sharedReg x0 4

  -- Initialize task1's stack pointer
  li x14 0x2000_0140
  sw task1CtxReg x14 4

  -- Capture worker entry address.
  overWorkerL <- labelUnplaced
  jal x14 overWorkerL

  -- ---------------- worker task body ----------------
  workerLoopL <- label
  -- Read request from shared memory
  lw x16 sharedReg 0           -- x16 = request value
  -- Process: completion = request + 1
  addi x17 x16 1
  sw sharedReg x17 4           -- write completion
  -- Print 'b' marker
  li x14 0x62
  sw uartReg x14 0
  -- Switch back to main
  switchTask1ToTask0L <- labelUnplaced
  jal x1 switchTask1ToTask0L
  j workerLoopL

  placeAt overWorkerL
  -- Save worker entry into task1_ctx[0]
  sw task1CtxReg x14 0

  -- Zero out task1_ctx[8..56] (s0..s11)
  li x14 8
  zeroLoop1L <- label
  add x15 task1CtxReg x14
  sw x15 x0 0
  addi x14 x14 4
  addi x15 x0 56
  bne x14 x15 zeroLoop1L

  -- Zero out task0_ctx
  li x14 0
  zeroLoop0L <- label
  add x15 task0CtxReg x14
  sw x15 x0 0
  addi x14 x14 4
  addi x15 x0 56
  bne x14 x15 zeroLoop0L

  -- Initial main-task sp + counter (in s11/x27 = main's iteration counter)
  li x2  0x2000_0100
  li x27 0                     -- x27 = main's iteration counter

  -- ---------------- main task loop ----------------
  mainLoopL <- label
  -- Compute next request value
  addi x27 x27 1               -- counter += 1
  sw sharedReg x27 0           -- request = counter
  -- Print 'A' marker
  li x14 0x41
  sw uartReg x14 0
  -- Switch to worker (= wake_up_process(kthreadd))
  switchTask0ToTask1L <- labelUnplaced
  jal x1 switchTask0ToTask1L
  -- Resumed: verify completion == counter + 1
  lw x16 sharedReg 4           -- x16 = completion
  addi x15 x27 1               -- expected = counter + 1
  failVerifyL <- labelUnplaced
  bne x16 x15 failVerifyL
  -- Print '.' for round-trip success
  li x14 0x2E
  sw uartReg x14 0
  j mainLoopL

  placeAt failVerifyL
  -- Print 'F' + '0' to mark verification failure
  li x14 0x46                  -- 'F'
  sw uartReg x14 0
  li x14 0x30                  -- '0'
  sw uartReg x14 0
  failSpinL <- label
  li x14 0x46
  sw uartReg x14 0
  j failSpinL

  -- ---------------- switch_to wrappers (same as HelloSchedStress) ----
  switchToCommonL <- labelUnplaced

  placeAt switchTask0ToTask1L
  add x6 x0 task0CtxReg
  add x7 x0 task1CtxReg
  j switchToCommonL

  placeAt switchTask1ToTask0L
  add x6 x0 task1CtxReg
  add x7 x0 task0CtxReg
  j switchToCommonL

  placeAt switchToCommonL
  -- Save 14 caller-saved + s-regs to curr_ctx
  sw x6 x1 0
  sw x6 x2 4
  sw x6 x8 8
  sw x6 x9 12
  sw x6 x18 16
  sw x6 x19 20
  sw x6 x20 24
  sw x6 x21 28
  sw x6 x22 32
  sw x6 x23 36
  sw x6 x24 40
  sw x6 x25 44
  sw x6 x26 48
  sw x6 x27 52

  -- Restore from next_ctx
  lw x1 x7 0
  lw x2 x7 4
  lw x8 x7 8
  lw x9 x7 12
  lw x18 x7 16
  lw x19 x7 20
  lw x20 x7 24
  lw x21 x7 28
  lw x22 x7 32
  lw x23 x7 36
  lw x24 x7 40
  lw x25 x7 44
  lw x26 x7 48
  lw x27 x7 52

  jalr x0 x1 0

helloKthreadCreateStressFirmwareWords :: [BitVector 32]
helloKthreadCreateStressFirmwareWords =
  case assemble helloKthreadCreateStressFirmware of
    DE.Right ws -> ws
    DE.Left e -> P.error ("HelloKthreadCreateStress assembly failed: " P.++ P.show e)
