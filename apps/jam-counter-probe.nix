# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# `nix run .#jam-counter-probe` — read the diagnostic counters that
# `Riski5.JtagAvalonMaster` exposes via three `altsource_probe` SLD
# instances inside the IP composition shim (task #133).
#
# Output: bytes_in_cnt, writes_commit_cnt, reads_commit_cnt — and the
# bytes_in / writes_commit ratio (4.0 = perfect; > 4 means drops at
# the FSM/master layer; < 4 means drops UPSTREAM of the FSM, i.e. in
# the bytes_to_packets / sc_fifo / JTAG-PHY chain).
#
# Use after a `nix run .#boot-linux-master` upload finishes, before
# power-cycling. The counters survive whatever the boot stub does
# next (they're in the bridge IP, not the riski5 core).
{
  writeShellApplication,
  quartus-ii-13,
  psmisc,
}:
writeShellApplication {
  name = "jam-counter-probe";
  runtimeInputs = [quartus-ii-13 psmisc];
  text = ''
    set -euo pipefail

    # Release the device if nios2-terminal / a stale jtagd are
    # holding the cable.
    pkill -9 -f nios2-terminal 2>/dev/null || :
    killall -q jtagd 2>/dev/null || :
    sleep 0.3

    quartus_stp -t ${../scripts/jam-counter-probe.tcl}
  '';
}
