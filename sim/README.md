# sim/

Verilator-driven Verilog testbenches for SoC subsystems too narrow
for the full `riski5-sim` (which compiles the entire Clash core).
Each subdirectory / file pair targets one block, with a behavioral
model standing in for the parts that aren't Verilator-friendly
(e.g. the Altera SDRAM IP, which is encrypted-binary in shipped
Quartus).

## Current testbenches

### `cdc_bridge_top.v` + `cdc_bridge_test.cpp`

Wraps the `riski5_sdram_cdc_bridge` (the toggle-handshake
clock-domain-crossing bridge between clkBus and clkSdram) against
`sdram_ip_behavioral.v` (a stand-in for the Altera SDRAM Controller
IP's slave port). Drives 16-bit Avalon-MM writes and reads from
both EVEN (= lo half-word) and ODD (= hi half-word) half-word
indices, plus the lo+hi pair pattern the SDRAM adapter emits for a
32-bit write.

Was created to debug task #146 (silicon hi-half-word writes
silently dropping). All 14 cases PASS in this sim — exonerating
the CDC bridge and the Clash-side SDRAM adapter from the bug, and
narrowing the remaining suspect to the actual Altera SDRAM IP or
the SDR SDRAM chip itself.

Run it:

```sh
cd sim
nix shell nixpkgs#python3 nixpkgs#verilator nixpkgs#gnumake nixpkgs#gcc \
    --command sh -c '
        verilator --cc --build --trace \
            -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT \
            -Wno-UNUSEDSIGNAL -Wno-LATCH \
            --top-module cdc_bridge_top \
            --Mdir obj_dir \
            --exe cdc_bridge_test.cpp \
            cdc_bridge_top.v riski5_sdram_cdc_bridge.v \
            sdram_ip_behavioral.v
        ./obj_dir/Vcdc_bridge_top
    '
```

Exit 0 = all PASS, 1 = any FAIL. Pass `--trace` to the binary to
emit `cdc_bridge_test.vcd` for waveform inspection.

### `riski5_sdram_cdc_bridge.v`

Verbatim copy of the bridge module from
`pkgs/riski5-core/package.nix`. Kept here so the testbench builds
without rebuilding the whole bitstream. Re-export from the package
when the bridge changes (or factor it into a shared file the
package.nix imports — TODO).

### `sdram_ip_behavioral.v`

Simple Verilator-friendly behavioral model of the Altera
`altera_avalon_new_sdram_controller` IP's slave port. Mirrors
`Riski5.Sdram.sdramIpSim`'s logic in pure Verilog: a 16-bit
Avalon-MM slave with a single-cycle response, byte enables, and
no chip-side timing. Adequate for catching CDC-bridge / adapter
bugs; not adequate for catching real SDRAM-chip protocol bugs.

## Future testbenches

- `sdram_adapter_top.v` — link the Clash-emitted SDRAM adapter
  to `sdram_ip_behavioral.v` to test 32-bit-via-lo+hi patterns.
- `jtag_master_top.v` — feed the JTAG-Avalon-Master Clash module
  with a synthetic byte stream and verify the resulting Avalon-MM
  master behavior.
- Full-SoC integration via the existing `riski5-sim` package, once
  the SDRAM section of `riski5_sim_top.v` is added.
