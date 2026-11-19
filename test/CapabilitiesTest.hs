module CapabilitiesTest (tests) where

import Control.Monad (forM_)
import Data.Text (Text)
import Data.Text.IO qualified as Text
import LibTmux.Capabilities
import LibTmux.Version
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "application capabilities"
  [ testCase "the released event-wait boundary rejects candidates and older patches" $
      forM_ ["3.3a", "3.7", "3.7z", "next-3.8", "3.8-rc", "3.8-rc10"] $ \raw -> do
        version <- release raw
        forM_ capabilityRegistry $ \info -> do
          supports (capabilitiesFor version) info.capability @?= False
          requireCapability (capabilitiesFor version) info.capability @?=
            Left (CapabilityUnavailable info.capability version)
  , testCase "released, patched and newer daemons admit every registered operation" $
      forM_ ["3.8", "3.8a", "3.8z", "3.9", "3.10", "next-4.0"] $ \raw -> do
        version <- release raw
        forM_ capabilityRegistry $ \info ->
          requireCapability (capabilitiesFor version) info.capability @?= Right ()
  , testCase "packaged capability metadata matches the runtime registry" $
      Text.readFile "capabilities.json" >>= (@?= capabilityManifest)
  ]

release :: Text -> IO TmuxVersion
release = either (fail . show) pure . parseVersion
