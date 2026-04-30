# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# `nix run .#sdram-write-pattern-test` — exercises the JTAG-Master
# write path against the currently-flashed bitstream and reports
# whether 32-bit / 16-bit half-word writes commit correctly.
#
# Designed to surface the task #146 hi-half-word write drop in
# seconds, instead of the 8-min Linux-boot round-trip needed to
# discover the same bug via verify_first_words inside
# boot-linux-master.tcl.
#
# Usage:
#   1. Flash a bitstream that exposes the JTAG-Avalon-Master service.
#      E.g. `nix run .#flash-riski5-linux-master`.
#   2. `nix run .#sdram-write-pattern-test`
#
# Exit code 0 = all PASS; 1 = any FAIL; 2 = no JTAG-Master found.
{
  writeShellApplication,
  psmisc,
  quartus-ii-13,
}:
writeShellApplication {
  name = "sdram-write-pattern-test";
  runtimeInputs = [quartus-ii-13 psmisc];
  text = ''
    set -euo pipefail

    echo "== sdram-write-pattern-test: clearing stale JTAG holders =="
    pkill -9 -f nios2-terminal 2>/dev/null || :
    killall -q jtagd || :
    sleep 0.3
    jtagconfig >/dev/null
    sleep 0.3

    echo "== sdram-write-pattern-test: invoking system-console =="
    fhs_wrapper=$(grep -oE '/nix/store/[^/]+-quartus-ii-13/bin/quartus-ii-13' \
        "$(command -v quartus_stp)" | head -1)
    if [[ -z "$fhs_wrapper" ]]; then
      echo "error: could not extract FHS path from quartus_stp wrapper" >&2
      exit 1
    fi

    "$fhs_wrapper" system-console -cli \
        <<< "source ${../scripts/sdram-write-pattern-test.tcl}"
  '';
}
