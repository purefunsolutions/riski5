# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# `nix run .#flash-riski5` — push the synthesised .sof to the DE2
# over JTAG via the USB Blaster. Mirrors
# alterade2-flake/apps/flash-de2.nix (where the pattern was
# proven) except the payload points at our riski5.sof instead of
# the Blinky.sof.
{
  writeShellApplication,
  psmisc,
  quartus-ii-13,
  riski5-core,
}:
writeShellApplication {
  name = "flash-riski5";
  runtimeInputs = [quartus-ii-13 psmisc];
  text = ''
    # Release the device if a stale jtagd is still hanging on to it.
    killall -q jtagd || :

    echo "== Detected JTAG chains =="
    jtagconfig

    cable=$(jtagconfig | awk -F') ' '/USB-Blaster/ {print $2; exit}' | sed 's/ *$//')
    if [ -z "$cable" ]; then
      echo "No USB-Blaster detected. Is the board plugged in and powered?"
      exit 1
    fi

    sof="${riski5-core}/Riski5.sof"
    if [ ! -f "$sof" ]; then
      echo "Expected .sof not found at $sof"
      echo "Did \`nix build .#riski5-core\` complete? Check its output."
      exit 1
    fi

    echo
    echo "== Flashing $sof via '$cable' =="
    quartus_pgm -c "$cable" -m JTAG -o "p;$sof"
  '';
}
