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
An SoC-only attempt was made on 2026-04-24 and reverted; see
"Failed SoC-only attempt" below. The remaining proper fix
requires a companion core refactor.

### Core-side IF-stage refactor (required)

The existing `Riski5.Core` IF stage assumes `imemData` arrives
one cycle after `pcFetch` and handles 1-cycle data stalls via
`imemHeldS` (hold the about-to-be-captured instruction across
the stall) + `pcFetchPrevS` (stall-gated, so `pcFetchPrev`
stays put while pcFetch is frozen).

Neither survives a multi-cycle __fetch__ stall:

  * `pcFetchPrevS` is updated at the edge __before__ stall
    asserts, which for a fetch-stall captures the pre-jalr pc
    (BRAM) rather than the post-jalr pc (SRAM). When the stall
    eventually releases the IF/ID register captures the wrong
    pc / instruction pair.
  * `imemHeldS` captures `imemData` during the first stall
    cycle (when `stallPrev` is False). For a fetch-stall the
    first stall cycle is exactly the cycle the multi-cycle
    fetch started — `imemData` at that moment is junk / 0,
    so `imemHeldS` latches garbage and hands it back to IF/ID
    when the stall releases.

Proposed core changes:

  1. Add `imemReady :: Signal dom Bool` as a new input on
     `core` / `coreWith`. BRAM fetches strap this True always;
     SRAM fetches pulse True only on the cycle the fetched
     instruction is present on `imemData`.
  2. Redefine `pcFetchPrev` to advance when `imemReady` AND not
     stall (i.e., "a fresh fetch is completing"). Drop the
     stall-only gating.
  3. Redefine `imemHeldS` capture to fire on `imemReady` (the
     instruction-valid moment), not on the inverse of
     `stallPrev` (the pre-stall moment).
  4. Gate IF/ID capture on `imemReady && !stall`. Today IF/ID
     capture is only `!stall`.

None of this is invasive — ~15 lines of core changes — but it
is an interface break on `coreWith` / `core` that flows
through every test.

### SoC-side (after core is updated)

  1. __Fetch-side decoder in `Soc.hs`.__ Mux `imemDataS` by
     `pcFetch`'s region: BRAM (existing path), SRAM (arbitrated
     controller), SDRAM (future).
  2. __SRAM controller arbitration.__ One physical chip; fetch
     and data requests need a mini state machine. Data-priority
     seems cleanest (data at X is "further along" than fetch
     at F), with fetch blocking a data-requesting cycle only
     when a fetch transaction is mid-flight.
  3. __Wire `imemReady` back.__ True on the cycle the fetched
     instruction lands on `imemData`. Also True always for
     BRAM (existing sync-read gives a valid word every cycle).
  4. Keep the BRAM fetch port __direct__ (no bus decoder
     indirection): Clash-inferred dual-port M4K, 1-cycle latency,
     no arbitration overhead. Only SRAM / SDRAM fetches take
     the arbitrated slower path.

## Failed SoC-only attempt (2026-04-24)

Tried to implement the fix by editing `Riski5.Soc` alone:
added an `SramOwner` state register, muxed the SRAM controller
inputs between fetch and data, captured fetch results into a
`fetchSramRegS` holding register, and asserted a `fetchStallS`
so the existing core's stall infrastructure would freeze
during multi-cycle fetches.

All 159 `cabal tests` stayed green (sim doesn't exercise the
broken pcFetchPrev / imemHeldS semantics on this path), but
on silicon:

  * __`riski5-core-sramexec` bitstream__: same infinite
    `BBBBB...` stream as before. Confirmed the root cause is
    `imemHeldS` latching `0` at the first fetch-stall cycle
    (because `cachedSram = fetchSramReg` starts at 0), so
    even when the SRAM transaction completes, the core reads
    stale 0 out of `imemHeldS` and traps on the illegal
    instruction.
  * __`riski5-core-coremark` bitstream__: silicon hung too,
    despite CoreMark never targeting SRAM for fetch. Fmax
    still closed (54.5 MHz with +7 ns slack at 40 MHz target)
    but the Quartus placement shift from restructuring the
    `imemDataS` mux and split-then-recombined `stallS` was
    enough to produce a functionally broken bitstream.
    Another Cyclone II / Quartus 13.0sp1 placement-stability
    gotcha on top of the earlier CPP-line-number one.

Reverted. `git show <revert-sha>:src/Riski5/Soc.hs` for the
attempt code if resuming from this point. Lesson: SoC-only
fixes for multi-cycle fetch paper over a core-level issue
that has to be fixed at the source. Don't do it again.

## Next steps when resumed

- __Do the core refactor first.__ Add `imemReady`, redefine
  `pcFetchPrev` / `imemHeldS` semantics, run the 159 tests
  to confirm nothing regresses on BRAM-only code paths.
  Build both `riski5-core` and `riski5-core-coremark`, flash,
  confirm silicon stays at 44.57 CoreMarks. That's the safety
  net.
- __Then do the SoC arbiter.__ Same structure as the failed
  attempt but now pointing at the new `imemReady` signal.
  Flash `riski5-core-sramexec`; expect `BS` or better.
- __Sim coverage.__ Add `test/SramExecSpec.hs` with a
  `socSimFull`-driven run of `helloSramExecFirmwareWords`
  that asserts the UART stream is exactly `BS` followed by
  an ebreak trap. This would have caught the silicon hang
  in `cabal test` had it existed — and would let us iterate
  on the fix without a Quartus round-trip per attempt.
