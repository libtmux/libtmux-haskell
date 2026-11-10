module Main (main) where

import FixtureTest qualified
import FrameIntegrationTest qualified
import SocketPinTest qualified
import ProcessTest qualified
import RuntimeTest qualified
import RuntimeReadTest qualified
import ScopeTest qualified
import PublicServerTest qualified
import EntityCaptureTest qualified
import CommandIntegrationTest qualified
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = ProcessTest.withTests $ \processTests -> defaultMain $
  testGroup "real tmux"
    [FixtureTest.tests, FrameIntegrationTest.tests, SocketPinTest.tests,
     RuntimeTest.tests, RuntimeReadTest.tests, ScopeTest.tests, PublicServerTest.tests,
     EntityCaptureTest.tests, CommandIntegrationTest.tests, processTests]
