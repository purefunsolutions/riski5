# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# `nix run .#sdram-state-probe` — read the SDRAM CDC bridge / IP
# state diagnostic probes (task #142). The riski5_top.v wrapper
# instantiates two altsource_probe SLD nodes (SDST, SDIO) that
# pack the bridge's master/slave FSM states + handshake toggles +
# IP/bus signals + last-latched address.
#
# Workflow:
#
#   nix run .#boot-linux-master       # flash + upload + JR into Linux
#   # Wait for the silicon hang at PC=0x80000108 (no kernel
#   # earlycon output past the boot-stub markers).
#   # In a separate terminal:
#   nix run .#sdram-state-probe
#
# The script samples PCFE, DBGF, SDST, SDIO 8 times at 100 ms
# intervals so you can see if the bridge / IP state is animating
# or genuinely parked. Hand-decoded bit fields point at which
# side has stopped:
#
#   m_state=BUSY  + s_state=REQ        → bridge waiting for IP to
#                                        accept the request (IP
#                                        keeps waitrequest high)
#   m_state=BUSY  + s_state=AWAIT_VALID → bridge waiting for IP
#                                        to pulse za_valid (IP
#                                        accepted but never
#                                        returned data)
#   m_state=BUSY  + s_state=IDLE       → master kicked req, slave
#                                        side never saw the toggle
#                                        synchronise (CDC bug)
#   m_state=IDLE  + master cs/rd/wr=1  → master is asking but
#                                        bridge dropped the request
#                                        somehow (also CDC bug)
{
  writeShellApplication,
  quartus-ii-13,
  psmisc,
}:
writeShellApplication {
  name = "sdram-state-probe";
  runtimeInputs = [quartus-ii-13 psmisc];
  text = ''
    set -euo pipefail

    # Release the device if nios2-terminal / a stale jtagd are
    # holding the cable.
    pkill -9 -f nios2-terminal 2>/dev/null || :
    killall -q jtagd 2>/dev/null || :
    sleep 0.3

    quartus_stp -t ${../scripts/sdram-state-probe.tcl}
  '';
}
