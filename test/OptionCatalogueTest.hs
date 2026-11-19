module OptionCatalogueTest (tests) where

import Data.Text (Text)
import LibTmux.Capabilities (Capabilities, capabilitiesFor)
import LibTmux.Options
import LibTmux.Version (parseVersion, renderVersion)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "tmux option and hook catalogue"
  [ testCase "retain types for the actual release and keep first availability" $ do
      old <- capabilities "3.3a"
      intermediate <- capabilities "3.4"
      checkKind (lookupOption old "allow-passthrough") FlagKind
      checkKind (lookupOption intermediate "allow-passthrough") ChoiceKind
      latest <- capabilities "3.8"
      entry <- require (lookupOption latest "remain-on-exit")
      entry.optionScopes @?= [WindowScope, PaneScope]
      entry.optionChoices @?= ["off", "on", "failed", "key", "failed-key"]
      renderVersion entry.optionSince @?= "3.3a"
      array <- require (lookupOption old "status-format")
      array.optionShape @?= Array
      array.optionKind @?= StringKind
  , testCase "read hook scopes and account for additions and removal" $ do
      old <- capabilities "3.3a"
      latest <- capabilities "3.8"
      lookupHook old "pane-created" @?= Nothing
      hook <- require (lookupHook latest "pane-created")
      hook.hookScopes @?= [WindowScope, PaneScope]
      renderVersion hook.hookSince @?= "3.8"
      _ <- require (lookupHook old "after-queue")
      lookupHook latest "after-queue" @?= Nothing
      lookupOption latest "after-new-session" @?= Nothing
      length (knownOptions old) @?= 116
      length (knownHooks old) @?= 65
      length (knownOptions latest) @?= 183
      length (knownHooks latest) @?= 89
  ]

checkKind :: Maybe OptionInfo -> OptionKind -> Assertion
checkKind option kind = require option >>= (@?= kind) . (.optionKind)

capabilities :: Text -> IO Capabilities
capabilities = either (fail . show) (pure . capabilitiesFor) . parseVersion

require :: Maybe a -> IO a
require = maybe (fail "missing catalogue entry") pure
