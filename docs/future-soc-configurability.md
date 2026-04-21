<!--
SPDX-FileCopyrightText: 2026 Mika Tammi
SPDX-License-Identifier: MIT OR BSD-3-Clause
-->

# Future SoC configurability (design note)

> **Superseded by [`core-family.md`](./core-family.md) for the
> core-tier story.** The four-tier sketch below (Tiny / Little / Big
> / Performance) has been replaced by a five-tier plan (Tiny / Little
> / Mid / Big / Performance), each in RV32 and RV64 editions, with a
> type-level `CoreConfig` parameter space documented fully in the new
> doc. Read `core-family.md` first.
>
> This file is retained for its **SoC-level** story: the
> IP-provider-per-peripheral choice (Altera vs own-Clash), the
> cache-configuration dimensions, and the historical note on why we
> didn't build the config machinery in phase 1. Those parts are
> unchanged by the core-family expansion.

Status: **not yet implemented** — this is a forward-looking design note
captured while we are still in phase 1. The first concrete uses land in
phase 2+, once the single-variant phase-1 SoC has proven itself on
hardware.

## The vision

The Riski5 SoC is currently a single concrete assembly: one core style
(pipelineless → 2-stage F+X), one set of peripherals (BRAM, SRAM,
JTAG-UART via Altera IP, LCD, GPIO), one memory map. As the project
grows we want to turn the SoC description into a *type-parameterised*
Haskell generator so that the same source code can emit several
different hardware realisations from one codebase — the "SoC family"
idea.

Haskell's type system is the right place for this: type-level configs
behave like C++ template parameters, letting the elaborator pick module
shapes at generate time while the generated Verilog stays specialised
and fully synthesisable (no runtime overhead).

## Dimensions we want to vary

1. **IP-block provider per peripheral.** e.g. the JTAG UART can be
   either:

   - `UartProvider = AlteraIp` — Path-1 black-box of
     `altera_avalon_jtag_uart` (what we're doing first).
   - `UartProvider = OwnClash` — Path-2 own-Clash controller over
     `sld_virtual_jtag_basic`.

   Analogous choice applies to the SDRAM controller, any future
   Ethernet MAC, and so on. The SoC signature takes a
   `UartProvider`-like type parameter, and dispatches to the right
   module.

2. **Cache configuration.** `data CacheSpec = NoCache | DirectMapped Size
   Line | Associative Ways Size Line`; the `Cache` module is
   parameterised on the spec so a change from `NoCache` to
   `DirectMapped 4096 32` flows through the memory pipeline without
   hand-wiring.

3. **Core class — the four we want to grow into.**

   | Class | Pipeline | M-ext | Caches | FPU | Target use |
   |---|---|---|---|---|---|
   | **tiny** | pipelineless (phase 1B) | no | no | no | minimal footprint, tight budgets |
   | **little** | 2-stage F+X (current direction) | yes | small I-cache | no | DE2 phase-1 completion, first Linux boots |
   | **big** | 5-stage classic | yes | I + D with write-back | no | performance-oriented baseline |
   | **performance** | superscalar / OoO (aspirational) | yes | L1 + L2 | yes | performance ceiling on larger devices |

   These become the visible entry points (`tinyCore`, `littleCore`,
   `bigCore`, `performanceCore`), each exporting the same `Core`
   interface so the SoC wiring is shared.

4. **Memory map + slave set.** Each core class might want a slightly
   different peripheral set; the memory-map constants in
   `src/Riski5/MemMap.hs` evolve into a type-indexed record so the bus
   decoder and firmware agree automatically.

## Implementation shape (sketch, not spec)

A plausible surface once we go there:

```haskell
data CoreClass = Tiny | Little | Big | Performance
data UartImpl  = UartAltera | UartOwn
data SdramImpl = SdramAltera | SdramOwn
-- … etc.

data SocConfig = SocConfig
  { socCore  :: CoreClass
  , socUart  :: UartImpl
  , socSdram :: SdramImpl
  , socICache, socDCache :: CacheSpec
  -- …
  }

-- Type-level promoted; used by `soc` as a type parameter so that the
-- chosen implementations get picked at compile time. Generated Verilog
-- is a specialisation for that one SocConfig.
soc :: forall (cfg :: SocConfig). …
```

The test harnesses then parameterise over `SocConfig` too, so every
combination can be run through the same catalog.

## Why we're *not* doing this today

- Phase 1's goal is first-silicon on the DE2 with the simplest possible
  assembly. One concrete SoC, running one concrete core, wired directly.
- Every configurability dimension costs time to design now and time to
  migrate later; premature generalisation is the wrong trade when the
  baseline variant isn't even proven on hardware yet.
- The right moment to introduce the config machinery is **after** we
  have at least two real variants in hand (e.g. phase-1B pipelineless
  core + phase-2A little-class 2-stage core, *and* Altera JTAG UART
  working alongside an own-Clash alternative). Then the abstractions
  emerge from concrete duplicates rather than being guessed.

## Lessons to capture along the way

As we build each variant, record in `docs/`:

- Synthesised **Fmax** (from the Quartus fit report).
- **LE count**, **M4K count**, **multiplier count**, **carry-chain
  count** — watch the deltas.
- **Decisions** that went into the variant: what we tried, what we
  rejected, why.

When the time comes to collapse these variants into the type-parameter
machinery, these notes become the design log we refactor against.

## Cross-references

- The current phase-1 task backlog lives in
  [`../TODO.md`](../TODO.md).
- The phase plan is at
  `/home/mika/.claude/plans/look-at-repositories-alterade2-flake-starry-shell.md`.
- Peripheral policy (Altera IP vs own-Clash) is summarised in
  [`../CLAUDE.md`](../CLAUDE.md) under "Altera IP black-boxing policy".
