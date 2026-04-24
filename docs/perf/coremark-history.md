<!--
SPDX-FileCopyrightText: 2026 Mika Tammi
SPDX-License-Identifier: MIT OR BSD-3-Clause
-->

# CoreMark history

One row per `scripts/coremark-run.sh` invocation on real silicon.
Watch the score evolve as phase-2 work lands (M4K regfile,
I$/D$ caches, PLL bumps). Run before every `git commit` that
touches the core or SoC.

The `Pre-commit HEAD` column is the HEAD SHA at measurement
time — i.e. the code **before** the commit the measurement
attaches to. Look at the next row's Pre-commit HEAD for the SHA
where that score was captured. First row is the initial
CM-4-complete baseline.

Methodology:

- 600 iterations, `2K performance run` (seed1=0, seed2=0, seed3=0x66, size=666 per algorithm).
- Upstream `list`/`matrix`/`state` CRCs must match the published `known_id=3` triplet, and `Correct operation validated.` must land on the UART — otherwise the row isn't logged.
- Core clock 40 MHz (PLL 50 × 4 / 5).
- `CoreMarks/MHz = (iterations × 40,000,000) / (ticks × 40,000,000 / 1,000,000) = iter × 1,000,000 / ticks`.

| Date (UTC) | Pre-commit HEAD | Ticks | Wall-clock | CoreMark 1.0 | CoreMarks/MHz | Notes |
|---|---|---:|---:|---:|---:|---|
| 2026-04-23T20:30:00Z | `1fcb6ed` | 538,520,721 | 13.463 s | 44.57 | 1.114 | **Baseline.** CM-4 complete — 5-stage F\|D\|X\|M\|W, no caches, async LE regfile, sync-read imem bus-port (1-cycle stall per .rodata load), SRAM/SDRAM stalls on stack access. |
| 2026-04-23T22:41:26Z | `6431a14` | 538520721 | 13.463 s | 44.57 | 1.114 |  |
| 2026-04-23T23:49:57Z | `92cfbb5` | 538520721 | 13.463 s | 44.57 | 1.114 |  |
| 2026-04-24T00:36:43Z | `7995dc8` | 538520721 | 13.463 s | 44.57 | 1.114 | Sanity re-measurement. Confirms clock reverted from 30 MHz experiment back to 40 MHz, Core.hs back to regfileAsync — baseline intact. |
| 2026-04-24T01:19:52Z | `8baa674` | 538520721 | 13.463 s | 44.57 | 1.114 | Verification re-measurement after SRAM-exec probe work (new `HelloSramExec` firmware + `riski5-core-sramexec` bitstream variant). CoreMark path unchanged because the SRAMEXEC variant overlays `CoreMark.hs` rather than modifying `Top.hs` — keeps Quartus placement stable. |
| 2026-04-24T02:08:06Z | `7d2284a` | 538520721 | 13.463 s | 44.57 | 1.114 | Verification after SRAM-fetch SoC-only arbiter attempt (reverted) — baseline restored, CoreMark intact. |
