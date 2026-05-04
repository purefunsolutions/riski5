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
import CdcSocIntegrationSpec qualified
import CdcSpec qualified
import CoreCdcSpec qualified
import ClintSpec qualified
import CompressedSpec qualified
-- import CoreMarkSimSpec qualified  -- disabled: see module header
import ExtIrqSpec qualified
import CoreSimSpec qualified
import CoreSpec qualified
import DecodeSpec qualified
import HelloSpec qualified
import IFetchSpec qualified
import JalrStackSpec qualified
import JtagLoadByteEnableSpec qualified
import LcdSpec qualified
import PipelineSpec qualified
import PlicSocSpec qualified
import PlicSpec qualified
import ReferenceSpec qualified
import RegfileSpec qualified
import SdramCdcSpec qualified
import SdramExecSpec qualified
import SdramSpec qualified
import SdramTwoPortSpec qualified
import SdrControllerSpec qualified
import SocChainIntegrationSpec qualified
import SocHwSim qualified
import SocSpec qualified
import SpikeDiffSpec qualified
import SpikeDriverSpec qualified
import SramExecSpec qualified
import TimerIrqSpec qualified
import SramSpec qualified
import SramStallForwardSpec qualified
import SramTwoPortSpec qualified
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
      , CdcSpec.tests
      , CoreCdcSpec.tests
      , CdcSocIntegrationSpec.tests
      , ClintSpec.tests
      , CompressedSpec.tests
      -- , CoreMarkSimSpec.tests  -- disabled: see module header
      , LcdSpec.tests
      , PlicSpec.tests
      , PlicSocSpec.tests
      , SocSpec.tests
      , SramSpec.tests
      , SramExecSpec.tests
      , SramStallForwardSpec.tests
      , SramTwoPortSpec.tests
      , SdramSpec.tests
      , SdramCdcSpec.tests
      , SdramExecSpec.tests
      , SdramTwoPortSpec.tests
      , SdrControllerSpec.tests
      , SocChainIntegrationSpec.tests
      , HelloSpec.tests
      , IFetchSpec.tests
      , JalrStackSpec.tests
      , JtagLoadByteEnableSpec.tests
      , UartBackpressureSpec.tests
      , SocHwSim.tests
      , SpikeDriverSpec.tests
      , SpikeDiffSpec.tests
      , TimerIrqSpec.tests
      , ExtIrqSpec.tests
      ]
