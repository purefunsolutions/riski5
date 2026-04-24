<!--
SPDX-FileCopyrightText: 2026 Mika Tammi
SPDX-License-Identifier: MIT OR BSD-3-Clause
-->

# SRAM execution probe — 2026-04-24

## Result

**The core cannot execute code from SRAM.** A firmware that
prints `B` once, writes a valid `sw` instruction into
`SRAM[0x2000_0000]`, and jumps there produces an infinite
`BBBBB...` stream (~150 000 'B's per second at 40 MHz) —
because the jump to `0x2000_0000` wraps back into BRAM's
`progInit[0]` and re-starts the firmware.

## Root cause — the fetch path is hardwired to BRAM

`src/Riski5/Soc.hs` wires the core's fetch port directly to
the BRAM `progInit` Vec:

```haskell
imemDataS :: Signal dom (BitVector 32)
imemDataS =
  blockRam progInit (addrToImemIdx <$> pcFetchS) (CP.pure Nothing)

addrToImemIdx :: BitVector 32 -> Index p
addrToImemIdx b =
  let w    = unpack (b `shiftR` 2) :: Unsigned 32
      nMax = fromInteger (natVal (Proxy :: Proxy p)) :: Unsigned 32
   in fromIntegral (w `mod` nMax)
```

`addrToImemIdx` takes the full 32-bit PC, drops the two LSBs
(word-align), and then takes `mod ProgSize = mod 4096`. For
`pcFetch = 0x2000_0000` this gives:

```
w    = 0x2000_0000 >> 2 = 0x0800_0000 = 134_217_728
nMax = 4096
w mod nMax = 0
```

So PC = `0x2000_0000` fetches `progInit[0]` — the very first
word of BRAM, which happens to be the start of whatever
firmware is baked in. The jump to SRAM is indistinguishable
from a jump to `0x0000_0000` at the fetch port.

**No bus decoder exists on the fetch path** — the data bus
routes reads / writes to BRAM / SRAM / SDRAM / UART / LCD via
`Riski5.Bus`, but the instruction bus is a point-to-point link
from `pcFetch` to a single `blockRam` over `progInit`.

## Debug firmware

`firmware/phase1/HelloSramExec.hs`. Flow:

1. UART-print `B` — confirms BRAM exec + bus + UART are up.
2. Write two instructions to SRAM via the (working) data bus:
   - `SRAM[0x2000_0000]` = `sw x14, 0(x10)` (0x00E52023) — the
     SRAM-resident "print `S`" routine.
   - `SRAM[0x2000_0004]` = `ebreak` (0x00100073) — traps so we
     don't wander off.
3. `jalr x0, x12, 0` where `x12 = 0x2000_0000` — jump to SRAM.

Build + flash via `nix run .#flash-riski5-sramexec`. The
variant is wired in `pkgs/default.nix`; the Nix package at
`pkgs/riski5-core/package.nix` __overlays
`firmware/phase1/CoreMark.hs`__ with a one-file re-export of
`HelloSramExec.helloSramExecFirmwareWords` and reuses the
existing `-DFIRMWARE_COREMARK` build path. That way `app/Top.hs`
stays __bit-identical__ between the real-CoreMark and
SRAMEXEC builds — see "Quartus placement stability" below.

## Silicon observation

Captured over 10 s of `nios2-terminal` on the clean rebuild:

- 1 507 328 bytes total.
- 1 507 328 are the letter `B`.
- 0 `S` bytes.
- Nothing else — no trap signature, no halt.

This is the "fetch wraps to `progInit[0]`, firmware restarts,
prints `B`, loops" behaviour at ~150 kB/s UART rate. The `sw`s
to SRAM landed on the chip (they go through the working data
bus) — but the core never fetched those bytes. It re-fetched
`BRAM[0]` every time the `jalr` set PC to `0x2000_0000`.

## Quartus placement stability (gotcha)

First cut of this work added `#elif defined(FIRMWARE_SRAMEXEC)`
branches to `app/Top.hs` to select between the MemTest,
CoreMark, and SRAMEXEC firmwares via CPP. After CPP
preprocessing, the `CoreMark` build's Haskell source was
functionally identical to the pre-change Top.hs; the only
Verilog diff was __source-line comments__ (e.g. `app/Top.hs:209:1-9`
→ `213:1-9`) because the inactive CPP lines shifted subsequent
line numbers.

__Quartus placement was not identical.__ With functionally
identical Verilog, the two bitstreams' `.sof` MD5s differed,
and the CoreMark-variant bitstream built from the CPP-augmented
Top.hs __hung silicon__ (zero UART bytes in 20 s) while the
pristine-Top.hs bitstream ran at 44.57 CoreMarks. Fmax was
essentially the same (56.01 vs 56.31 MHz) and setup slack was
plentiful (+7 ns); nothing in the STA report explains the
divergence. Likely cause: Quartus's placer seed is sensitive
to comment/whitespace changes in ways STA doesn't model.

Workaround: __don't touch Top.hs__ to add a new firmware
variant. Instead, overlay `firmware/phase1/CoreMark.hs` in
the Nix build — both variants use the same Top.hs bit-
identically, and Quartus produces stable placement. The overlay
mechanism is the same one `gen-coremark-hs.py` already uses
for the real CoreMark bytes.

Worth remembering the next time CPP feels like the right tool
for a Cyclone II / Quartus 13.0sp1 bitstream variant.

## Relation to the phase-2B silicon hang

Probably unrelated. The phase-2B CoreMark hang happens *before*
any jump out of BRAM (CoreMark's `.text` lives entirely in
BRAM), so SRAM-execution inability doesn't explain it. But
it's a separate architectural gap worth closing regardless.

## Fix plan (future work)

Route the fetch port through a bus decoder — the same
`slaveOf` table `Riski5.Bus` already has for the data side.
Concretely:

1. **Fetch-side decoder in `Soc.hs`.** Switch `imemDataS` from
   "always BRAM" to a mux keyed on `pcFetch`'s region:
   - BRAM range (`0x0..0xFFF`): existing `blockRam progInit`
     path, 1-cycle latency.
   - SRAM range (`0x2000_0000..0x2007_FFFF`): route through
     the `sram` controller, 3-cycle latency per read.
   - SDRAM range (`0x8000_0000..0x807F_FFFF`): route through
     the `sdram` IP wrapper, multi-cycle + refresh.
   - Out of range: return `0x0000_0013` (NOP) or raise a
     fetch-side trap — pick one.

2. **Fetch stall protocol.** The core currently assumes imem
   returns in 1 cycle. Add an explicit `imemReady` signal
   alongside `imemData` so the SoC can stall the core when
   a multi-cycle fetch is in flight. This is a shape change
   on `Riski5.Core.core` and `Riski5.Core.Assembly.coreWith`.

3. **SRAM controller arbitration.** There's one physical SRAM
   chip. Fetch and data accesses need to serialize. Two
   options:
   - **Fetch-priority.** Fetch always wins; data stalls when
     fetch is running. Simple, correct, but stalls every data
     access during SRAM code execution. Probably good enough
     for a debugging / phase-1-plus feature.
   - **Round-robin / fair.** More throughput but more logic.
     Overkill for now.

4. **A separate `bramFetchS`-style fetch port for BRAM.**
   BRAM is a Clash-inferred dual-port M4K already; the fetch
   port can keep using it directly without going through the
   bus decoder. Only SRAM / SDRAM fetches need arbitration.
   This keeps the common case (BRAM code) at 1-cycle fetch.

## Next steps when resumed

- Decide whether SRAM execution is phase-2-scope or
  phase-1-plus debugging. Current firmware (CoreMark, Hello,
  MemTest) all live in BRAM and fit in 16 KB; no immediate
  need for SRAM code. But long-term, anything bigger than
  16 KB *will* need it.
- If proceeding: start with the minimal "BRAM + SRAM fetch
  decoder" slice, leave SDRAM fetches for later. The firmware
  above is the regression probe; add a `cabal test` variant
  in `test/SramExecSpec.hs` that sim-tests the same pattern.
