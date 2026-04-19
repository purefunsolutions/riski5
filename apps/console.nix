# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# `nix run .#console` — attach `nios2-terminal` to the first JTAG
# UART instance on the USB-Blaster chain.
#
# Caveat: `nios2-terminal` ships with Altera's Nios II EDS, NOT with
# stock Quartus 13.0sp1. If the binary is missing, this script
# prints a clear message explaining what to install. For the phase-1B
# first hardware run the LCD + LED blinking already give a "core is
# alive" signal; this wrapper matters more once the full
# Hello-from-Riski5 firmware (T18) starts writing to the UART.
{
  writeShellApplication,
  quartus-ii-13,
}:
writeShellApplication {
  name = "console";
  runtimeInputs = [quartus-ii-13];
  text = ''
    if ! command -v nios2-terminal >/dev/null 2>&1; then
      echo "nios2-terminal not found in PATH."
      echo
      echo "It ships with the Nios II Embedded Design Suite (separate"
      echo "download from Quartus). Without it you can still verify"
      echo "the core is alive via the LEDs/LCD; you just won't see"
      echo "the JTAG-UART text output until the EDS is installed."
      exit 1
    fi

    # Release the device if a stale jtagd is still hanging on to it.
    killall -q jtagd || :

    echo "== Starting nios2-terminal on the USB-Blaster JTAG UART =="
    echo "   Press Ctrl+C to exit."
    echo
    nios2-terminal
  '';
}
