# SPDX-FileCopyrightText: 2026 Mika Tammi
# SPDX-License-Identifier: MIT OR BSD-3-Clause
#
# Phase-1A: only the treefmt check is active. Additional checks (cabal
# test, hlint, coverage threshold) get added once src/ + test/ are
# non-trivial.
_: {
  perSystem = _: {
    checks = {};
  };
}
