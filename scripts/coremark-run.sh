#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# coremark-run.sh — build → flash → capture → log the current
# source tree's CoreMark score on the DE2. Run before `git commit`
# whenever the commit could plausibly move the score.
#
# Workflow:
#   1. git add -A                 # stage everything we want measured
#   2. scripts/coremark-run.sh    # (this — appends to history file)
#   3. git add docs/perf/coremark-history.md  # pick up the new row
#   4. git commit -m "..."        # normal commit, message stays
#                                 # about the change, not the score
#
# Main side-effect: appends one row to docs/perf/coremark-history.md.
# That file is where the per-commit performance evolution is kept;
# commit messages do NOT embed the score.
#
# Requires: the DE2 plugged in via USB-Blaster, the devshell or
# something with `jtagconfig` / `nios2-terminal` on PATH, and a
# flake that exposes riski5-core-coremark + flash-riski5-coremark.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
LOG_FILE="${COREMARK_LOG:-/tmp/coremark-run-$$.log}"
HIST_FILE="${REPO_ROOT}/docs/perf/coremark-history.md"
CAPTURE_SECS="${CAPTURE_SECS:-30}"
CORE_CLOCK_HZ="${CORE_CLOCK_HZ:-40000000}"

# --- Build -------------------------------------------------------
echo "== 1. nix build .#riski5-core-coremark =="
cd "$REPO_ROOT"
nix build .#riski5-core-coremark --no-link 2>&1 | tail -3 || {
    echo "ERROR: bitstream build failed. Fix before committing."
    exit 1
}

# --- Flash -------------------------------------------------------
echo
echo "== 2. nix run .#flash-riski5-coremark =="
# `killall -9` (vs the older `pkill -f`) is needed because nios2-terminal
# leaves jtagd holding the USB-Blaster lock; without a forced kill of
# jtagd here, the post-flash nios2-terminal connects but the firmware's
# JTAG-UART output never reaches stdout.
killall -9 nios2-terminal nios2-terminal-wrapped jtagd 2>/dev/null || true
sleep 2
nix run .#flash-riski5-coremark 2>&1 | tail -3 || {
    echo "ERROR: flash failed. Board plugged in? USB-Blaster detected?"
    exit 1
}

# --- Capture -----------------------------------------------------
echo
echo "== 3. capturing ${CAPTURE_SECS} s of JTAG-UART =="
rm -f "$LOG_FILE"
# Drop jtagd one more time so the freshly-flashed bitstream is
# what nios2-terminal opens against, not a stale handle.
killall -q jtagd 2>/dev/null || true
sleep 2
# `timeout 30 nios2-terminal` exits with code 124 when the timeout
# fires (expected — the firmware spins after printing). We swallow
# the exit so `set -e` doesn't kill the script on that path.
nix develop --command bash -c "timeout ${CAPTURE_SECS} nios2-terminal > '$LOG_FILE' 2>&1" || :

# --- Parse -------------------------------------------------------
if ! grep -q "Correct operation validated" "$LOG_FILE" 2>/dev/null; then
    echo
    echo "ERROR: CoreMark did not complete a validated run in ${CAPTURE_SECS} s."
    echo "       Raw capture (${LOG_FILE}):"
    echo "---"
    cat "$LOG_FILE" 2>/dev/null || echo "(no output captured at all)"
    echo "---"
    exit 1
fi

TICKS=$(grep "Total ticks" "$LOG_FILE" | awk '{print $NF}')
ITERS=$(grep "^Iterations " "$LOG_FILE" | awk '{print $NF}')

if [[ -z "$TICKS" || -z "$ITERS" ]]; then
    echo "ERROR: couldn't parse ticks / iterations from capture. See $LOG_FILE"
    exit 1
fi

SECS=$(awk "BEGIN{printf \"%.3f\", ${TICKS}/${CORE_CLOCK_HZ}}")
CM=$(awk "BEGIN{printf \"%.2f\", ${ITERS}*${CORE_CLOCK_HZ}/${TICKS}}")
CM_PER_MHZ=$(awk "BEGIN{printf \"%.3f\", (${ITERS}*${CORE_CLOCK_HZ}/${TICKS})/(${CORE_CLOCK_HZ}/1000000)}")

# --- Report ------------------------------------------------------
SHORT=$(git rev-parse --short HEAD 2>/dev/null || echo "uncommitted")
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo
echo "== CoreMark silicon result =="
echo "  Total ticks      : ${TICKS}"
echo "  Wall-clock       : ${SECS} s"
echo "  Iterations       : ${ITERS}"
echo "  CoreMark 1.0     : ${CM}"
echo "  CoreMarks / MHz  : ${CM_PER_MHZ}"
echo "  Validated        : YES"

# --- History append ----------------------------------------------
mkdir -p "$(dirname "$HIST_FILE")"
if [[ ! -f "$HIST_FILE" ]]; then
    cat > "$HIST_FILE" <<'HEADER'
<!--
SPDX-FileCopyrightText: 2026 Mika Tammi
SPDX-License-Identifier: MIT OR BSD-3-Clause
-->

# CoreMark history

One row per `scripts/coremark-run.sh` invocation on real silicon.
Watch the score evolve as phase-2 work lands (M4K regfile,
I$/D$ caches, PLL bumps). Run before every `git commit` that
touches the core or SoC.

The `Commit` column is the HEAD SHA at measurement time — i.e.
the code **before** the commit the measurement attaches to. Look
at the NEXT row's Commit for the SHA where that score landed.

| Date (UTC) | Pre-commit HEAD | Ticks | Wall-clock | CoreMark 1.0 | CoreMarks/MHz | Notes |
|---|---|---:|---:|---:|---:|---|
HEADER
fi
echo "| ${DATE} | \`${SHORT}\` | ${TICKS} | ${SECS} s | ${CM} | ${CM_PER_MHZ} |  |" >> "$HIST_FILE"

echo
echo "History appended to: ${HIST_FILE}"
