-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause

module Main (main) where

import AluSpec qualified
import AsmSpec qualified
import CoreSimSpec qualified
import CoreSpec qualified
import DecodeSpec qualified
import ReferenceSpec qualified
import RegfileSpec qualified
import Test.Tasty (defaultMain, testGroup)
import TrapSpec qualified

main :: IO ()
main =
  defaultMain $
    testGroup
      "riski5"
      [ DecodeSpec.tests
      , AsmSpec.tests
      , AluSpec.tests
      , RegfileSpec.tests
      , ReferenceSpec.tests
      , CoreSpec.tests
      , CoreSimSpec.tests
      , TrapSpec.tests
      ]
