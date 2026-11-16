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
import OwnedServerTest qualified
import PublicLifecycleTest qualified
import Control.Exception (finally)
import Fixture (Daemon (..), retainedDaemons)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = ProcessTest.withTests $ \processTests -> (`finally` failOnRetained) $ defaultMain $
  testGroup "real tmux"
    [FixtureTest.tests, FrameIntegrationTest.tests, SocketPinTest.tests,
     RuntimeTest.tests, RuntimeReadTest.tests, RuntimeMutationTest.tests, RuntimeCreationTest.tests, ScopeTest.tests, PublicServerTest.tests, PublicMutationTest.tests, PublicCreationTest.tests,
     EntityCaptureTest.tests, CommandIntegrationTest.tests, processTests, OwnedServerTest.tests, PublicLifecycleTest.tests]

-- | A fixture daemon that outlived SIGTERM and SIGKILL stays owned and fails the run.
failOnRetained :: IO ()
failOnRetained = retainedDaemons >>= \case
  [] -> pure ()
  owners -> do
    hPutStrLn stderr ("fixture daemons still owned: " <> unwords (map (.label) owners))
    exitWith (ExitFailure 3)
