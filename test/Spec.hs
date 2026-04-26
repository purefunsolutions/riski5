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
import AvalonMmSpec qualified
import BramCoreSpec qualified
import BramSpec qualified
import BramStallForwardSpec qualified
-- import CoreMarkSimSpec qualified  -- disabled: see module header
import CoreSimSpec qualified
import CoreSpec qualified
import DecodeSpec qualified
import HelloSpec qualified
import JalrStackSpec qualified
import LcdSpec qualified
import PipelineSpec qualified
import ReferenceSpec qualified
import RegfileSpec qualified
import SdramSpec qualified
import SocHwSim qualified
import SocSpec qualified
import SpikeDiffSpec qualified
import SpikeDriverSpec qualified
import SramExecSpec qualified
import SramSpec qualified
import SramStallForwardSpec qualified
import Test.Tasty (defaultMain, testGroup)
import TrapSpec qualified
import UartBackpressureSpec qualified

main :: IO ()
main =
  defaultMain $
    testGroup
      "riski5"
      [ DecodeSpec.tests
      , AsmSpec.tests
      , AluSpec.tests
      , AvalonMmSpec.tests
      , RegfileSpec.tests
      , ReferenceSpec.tests
      , CoreSpec.tests
      , CoreSimSpec.tests
      , PipelineSpec.tests
      , TrapSpec.tests
      , BramSpec.tests
      , BramCoreSpec.tests
      , BramStallForwardSpec.tests
      -- , CoreMarkSimSpec.tests  -- disabled: see module header
      , LcdSpec.tests
      , SocSpec.tests
      , SramSpec.tests
      , SramExecSpec.tests
      , SramStallForwardSpec.tests
      , SdramSpec.tests
      , HelloSpec.tests
      , JalrStackSpec.tests
      , UartBackpressureSpec.tests
      , SocHwSim.tests
      , SpikeDriverSpec.tests
      , SpikeDiffSpec.tests
      ]
