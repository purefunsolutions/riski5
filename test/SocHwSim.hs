-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause

{- |
Module      : SocHwSim
Description : Verilator-backed whole-SoC simulation tests (SKELETON).

This is the second verification layer in the plan
('docs/verification.md'): we compile the Clash-emitted RTL *together
with the Altera JTAG UART IP's Verilog* under Verilator and drive
the resulting simulation from Haskell via verilambda. This catches
peripheral-protocol bugs that the pure-Clash tests cannot see —
most notably the Altera IP's 1-cycle registered write-data
semantics which bit us in T19-continued on real silicon (the bytes
we wrote came out as zeros because the master wasn't holding the
bus across av_waitrequest).

== Status

**Skeleton only** as of commit time. The pieces in place:

  * @pkgs\/riski5-sim\/verilog\/riski5_sim_top.v@ — hand-written
    simulation top that wires @riski5@ + @riski5_jtag_uart@ + a
    UART-TX observation tap.
  * @pkgs\/riski5-sim\/package.nix@ — Nix derivation that produces
    a @libVriski5_sim_top.a@ via verilator.
  * @pkgs\/riski5-sim\/clash-manifest.json@ — the shim-gen metadata
    describing the sim-top's ports.

Still to land (next session):

  * A `Custom` @Setup.hs@ (or `Hooks` equivalent, depending on
    Cabal version) wiring @verilambda-shim-gen@ into the build, so
    the Haskell tests can link against the sim library without a
    separate nix-build step in the middle.
  * An HKD @Riski5SimTopPorts@ record matching @ports_flat@ in the
    manifest, plus the FFI declarations and @SimBackend@ glue
    (modelled on @verilambda\/examples\/blinky\/src\/Main.hs@).
  * The first real test — probably @case_uartLandingBytes@ below:
    load the Hello firmware, simulate for enough cycles, assert
    the TX byte stream spells "hello, world\\n". When run against
    the buggy (non-stalled) version of @Riski5.Soc@ this MUST
    fail, exposing the silicon bug in sim. When run against the
    current head (with UART_READY wired into 'stallS') this MUST
    pass.

Once that loop closes, the test becomes the regression fence for
every future peripheral-bus change.

== Why the skeleton ships now

The plan file + skeleton land ahead of the implementation so that
(a) the decision to add the verilator layer is visible in the repo,
not just in conversation, and (b) the next session can start from
concrete TODOs rather than a blank page.
-}
module SocHwSim (
  tests,
) where

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)

tests :: TestTree
tests =
  testGroup
    "Riski5.SoC Verilator simulation (skeleton — no cases yet)"
    [ testCase "placeholder" (pure ())
    ]
