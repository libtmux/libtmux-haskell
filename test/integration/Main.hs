module Main (main) where

import FixtureTest qualified
import FrameIntegrationTest qualified
import SocketPinTest qualified
import ProcessTest qualified
import RuntimeTest qualified
import RuntimeReadTest qualified
import RuntimeCreationTest qualified
import RuntimeMutationTest qualified
import ScopeTest qualified
import PublicServerTest qualified
import PublicMutationTest qualified
import PublicCreationTest qualified
import EntityCaptureTest qualified
import CommandIntegrationTest qualified
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = ProcessTest.withTests $ \processTests -> defaultMain $
  testGroup "real tmux"
    [FixtureTest.tests, FrameIntegrationTest.tests, SocketPinTest.tests,
     RuntimeTest.tests, RuntimeReadTest.tests, RuntimeMutationTest.tests, RuntimeCreationTest.tests, ScopeTest.tests, PublicServerTest.tests, PublicMutationTest.tests, PublicCreationTest.tests,
     EntityCaptureTest.tests, CommandIntegrationTest.tests, processTests]
