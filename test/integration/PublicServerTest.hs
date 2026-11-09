module PublicServerTest (tests) where

import Control.Exception (ExceptionWithContext (..), finally, fromException, try)
import Control.Monad (when)
import Data.ByteString.Char8 qualified as Bytes
import Data.IORef
import Data.List (isPrefixOf)
import Fixture qualified
import LibTmux qualified as Tmux
import LibTmux.Snapshot.Fixture qualified as F
import System.Exit (ExitCode (..))
import System.Directory qualified as Directory
import System.FilePath ((</>))
import System.OsString.Posix qualified as Os
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "public Server API"
  [ testCase "captures the graph, keeps values after closure and leaves the daemon running" $
      Fixture.withFixture $ \fixture -> do
        (renamed, _, renameErrors) <- Fixture.command fixture ["select-pane", "-T", "public-api"]
        renamed @?= ExitSuccess
        renameErrors @?= ""
        let config = (Tmux.serverConfig (Os.fromBytestring (Bytes.pack fixture.socket)))
              { Tmux.executable = Os.fromBytestring (Bytes.pack fixture.executable) }
        (server, snapshot) <- Tmux.withServer config $ \server -> do
          snapshot <- Tmux.capture server
          Tmux.serverGeneration server @?= (Tmux.serverInfo snapshot).generation
          pure (server, snapshot)
        length (Tmux.sessions snapshot) @?= 1
        Tmux.snapshotOrigin snapshot @?= Tmux.AcquiredFromTmux
        length (Tmux.windows snapshot) @?= 1
        length (Tmux.panes snapshot) @?= 1
        case Tmux.panes snapshot of
          [pane] -> do
            window <- either (fail . show) pure (Tmux.lookupWindow snapshot pane.window)
            Tmux.panesForWindow snapshot window.ref @?= Right [pane]
            Tmux.lookupPaneId snapshot (Tmux.paneId pane.ref) @?= Right pane
            let offline = F.paneRef (F.fixtureOrigin "unit") (Tmux.paneId pane.ref)
            assertBool "offline reference equalled a Server target" (offline /= pane.ref)
            Tmux.lookupPane snapshot offline @?= Left Tmux.ForeignGeneration
            pane.title @?= "public-api"
          _ -> assertFailure "owned fixture has an unexpected pane graph"
        case Tmux.captureInterval snapshot of
          Just interval -> assertBool "capture time went backwards"
            (interval.startedNanoseconds <= interval.finishedNanoseconds)
          Nothing -> assertFailure "live snapshot has no capture interval"
        Tmux.tryTmux (Tmux.capture server) >>= \case
          Left (ExceptionWithContext _ Tmux.ServerClosed) -> pure ()
          Left problem -> assertFailure ("closed handle failed with an unexpected error: " <> show problem)
          Right _ -> assertFailure "closed handle performed another capture"
        (code, _, errors) <- Fixture.command fixture ["display-message", "-p", "#{pid}"]
        code @?= ExitSuccess
        errors @?= ""

  , testCase "independent Server scopes do not exchange targeting references" $
      Fixture.withFixture $ \fixture -> do
        let config = (Tmux.serverConfig (Os.fromBytestring (Bytes.pack fixture.socket)))
              { Tmux.executable = Os.fromBytestring (Bytes.pack fixture.executable) }
        first <- Tmux.withServer config Tmux.capture
        second <- Tmux.withServer config Tmux.capture
        case Tmux.panes first of
          [pane] -> Tmux.lookupPane second pane.ref @?= Left Tmux.ForeignGeneration
          _ -> assertFailure "owned fixture has an unexpected pane graph"

  , testCase "tryTmux does not consume an application exception" $ do
      result <- try (Tmux.tryTmux (ioError (userError "application failure")))
      case result of
        Left problem -> assertBool "application exception changed type"
          (case fromException @IOError problem of Just _ -> True; Nothing -> False)
        Right _ -> assertFailure "application exception was returned as a library error"

  , testCase "tryTmux retains a failed scope's cleanup context and reachable owner" $
      Fixture.withFixture $ \fixture -> do
        let config = (Tmux.serverConfig (Os.fromBytestring (Bytes.pack fixture.socket)))
              { Tmux.executable = Os.fromBytestring (Bytes.pack fixture.executable) }
        blocked <- newIORef Nothing
        let clear = readIORef blocked >>= mapM_ (\path -> do
              exists <- Directory.doesFileExist path
              when exists (Directory.removeFile path))
        flip finally clear $ do
          result <- Tmux.tryTmux $ Tmux.withServer config $ \_ -> do
            entries <- filter (isPrefixOf "lt-") <$> Directory.listDirectory fixture.directory
            case entries of
              [directory] -> do
                let path = fixture.directory </> directory </> "hold"
                writeIORef blocked (Just path)
                writeFile path "owned cleanup obstacle"
              _ -> assertFailure "scope did not create exactly one owned pin directory"
          case result of
            Left (ExceptionWithContext context (Tmux.CleanupFailed status _)) -> do
              status.complete @?= False
              case Tmux.cleanupRecoveries context of
                [recovery] -> do
                  clear
                  Tmux.resumeCleanup recovery >>= \finished -> finished.complete @?= True
                other -> assertFailure ("typed result lost its cleanup owners: " <> show other)
            other -> assertFailure ("cleanup failure was not preserved: " <> show other)
  ]
