-- SPDX-FileCopyrightText: 2026 Mika Tammi
-- SPDX-License-Identifier: MIT OR BSD-3-Clause
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}

module Main (main) where

import AluSpec qualified
import AsmSpec qualified
import BramCoreSpec qualified
import BramSpec qualified
import CoreSimSpec qualified
import CoreSpec qualified
import DecodeSpec qualified
import HelloSpec qualified
import LcdSpec qualified
import ReferenceSpec qualified
import RegfileSpec qualified
import SocSpec qualified
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
      , BramSpec.tests
      , BramCoreSpec.tests
      , LcdSpec.tests
      , SocSpec.tests
      , HelloSpec.tests
      ]
