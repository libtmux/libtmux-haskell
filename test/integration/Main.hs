module Main (main) where

import FixtureTest qualified
import FrameIntegrationTest qualified
import SocketPinTest qualified
import ProcessTest qualified
import OwnedGuardianTest qualified
import RuntimeTest qualified
import RuntimeReadTest qualified
import RuntimeCreationTest qualified
import RuntimeMutationTest qualified
import ScopeTest qualified
import PublicServerTest qualified
import PublicMutationTest qualified
import PublicCreationTest qualified
import PublicWindowCreationTest qualified
import PublicResizeTest qualified
import PublicControlTest qualified
import PublicSettingsTest qualified
import PublicProgramTest qualified
import EntityCaptureTest qualified
import CommandIntegrationTest qualified
import Fixture (guardRetained, withSandbox)
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = withSandbox $ guardRetained $ do
  programTests <- PublicProgramTest.tests
  ProcessTest.withTests $ \processTests -> defaultMain $ testGroup "real tmux"
    [FixtureTest.tests, FrameIntegrationTest.tests, SocketPinTest.tests,
     RuntimeTest.tests, RuntimeReadTest.tests, RuntimeMutationTest.tests, RuntimeCreationTest.tests, ScopeTest.tests, PublicServerTest.tests, PublicMutationTest.tests, PublicCreationTest.tests,
     EntityCaptureTest.tests, CommandIntegrationTest.tests, PublicWindowCreationTest.tests,
     OwnedGuardianTest.tests, PublicResizeTest.tests, PublicSettingsTest.tests, PublicControlTest.tests, programTests, processTests]
