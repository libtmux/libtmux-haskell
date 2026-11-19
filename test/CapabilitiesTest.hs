module CapabilitiesTest (tests) where

import Control.Monad (forM_)
import Data.Text (Text)
import Data.Text.IO qualified as Text
import LibTmux.Capabilities
import LibTmux.Version
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "daemon capabilities"
  [ testCase "the released event-wait boundary rejects candidates and older patches" $
      forM_ ["3.3a", "3.7", "3.7z", "next-3.8", "3.8-rc", "3.8-rc10"] $ \raw -> do
        version <- release raw
        forM_ [ManagedPrograms, ProgramInput, RenderedScreen, ProgramExitEvents] $ \feature -> do
          supports (capabilitiesFor version) feature @?= False
          requireCapability (capabilitiesFor version) feature @?=
            Left (CapabilityUnavailable feature version)
  , testCase "released, patched and newer daemons admit every registered operation" $
      forM_ ["3.8", "3.8a", "3.8z", "3.9", "3.10", "next-4.0"] $ \raw -> do
        version <- release raw
        forM_ capabilityRegistry $ \info ->
          requireCapability (capabilitiesFor version) info.capability @?= Right ()
  , testCase "raw paste flags exist from tmux 3.7 while older daemons use their native raw path" $ do
      forM_ ["3.3a", "3.6b", "3.7-rc"] $ \raw -> do
        version <- release raw
        supports (capabilitiesFor version) RawBufferPasteFlag @?= False
      forM_ ["3.7", "3.8"] $ \raw -> do
        version <- release raw
        supports (capabilitiesFor version) RawBufferPasteFlag @?= True
      (capabilityInfo RawBufferPasteFlag).handling @?= Fallback
  , testCase "control attachment flags first exist in tmux 3.2" $ do
      forM_ ["3.1c", "3.2-rc"] $ \raw -> do
        version <- release raw
        requireCapability (capabilitiesFor version) ControlNotifications @?=
          Left (CapabilityUnavailable ControlNotifications version)
      forM_ ["3.2", "3.3a", "3.8"] $ \raw -> do
        version <- release raw
        requireCapability (capabilitiesFor version) ControlNotifications @?= Right ()
  , testCase "packaged capability metadata matches the runtime registry" $
      Text.readFile "capabilities.json" >>= (@?= capabilityManifest)
  ]

release :: Text -> IO TmuxVersion
release = either (fail . show) pure . parseVersion
