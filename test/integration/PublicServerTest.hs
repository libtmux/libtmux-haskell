module PublicServerTest (tests) where

import Control.Concurrent.Async (race, wait, waitCatch, withAsync)
import Control.Concurrent.STM (atomically, newEmptyTMVarIO, putTMVar, readTMVar, tryPutTMVar)
import Control.Exception (ExceptionWithContext (..), MaskingState (..), finally, fromException, getMaskingState, mask_, throwIO, try)
import Control.Monad (forM_, when)
import Data.ByteString.Char8 qualified as Bytes
import Data.IORef
import Data.List (isPrefixOf)
import Fixture qualified
import LibTmux qualified as Tmux
import LibTmux.Server qualified as Server
import LibTmux.Snapshot.Fixture qualified as F
import System.Exit (ExitCode (..))
import System.Directory qualified as Directory
import System.FilePath ((</>))
import System.IO.Error (ioeGetErrorString)
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

  , testCase "Server adoption refuses an unqualified executable before entering the callback" $
      Fixture.withFixture $ \fixture -> forM_ [False, True] $ \shared -> do
        entered <- newIORef False
        let config = (Tmux.serverConfig (Os.fromBytestring (Bytes.pack fixture.socket)))
              {Tmux.executable = Os.fromBytestring "/bin/false"}
            callback _ = writeIORef entered True
            action = if shared
              then Tmux.withRuntime (\runtime -> Tmux.withServerIn runtime config callback)
              else Tmux.withServer config callback
        result <- Tmux.tryTmux action
        readIORef entered >>= (@?= False)
        case result of
          Left (ExceptionWithContext context _) ->
            forM_ (Tmux.cleanupRecoveries context) $ \recovery -> do
              status <- Tmux.inspectCleanup recovery
              mapM_ (Tmux.detachUnresolved recovery . fst) status.unresolved
              _ <- Tmux.resumeCleanup recovery
              pure ()
          Right () -> assertFailure "unqualified Server entered its callback"

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
  , testGroup "public shared Runtime"
      [ testCase "independent handle lifetimes preserve incoming masking and detached values" $
          Fixture.withFixture $ \fixture -> do
            let config = (Tmux.serverConfig (Os.fromBytestring (Bytes.pack fixture.socket)))
                  { Tmux.executable = Os.fromBytestring (Bytes.pack fixture.executable) }
                check expected = do
                  (runtime, closed, snapshot) <- Tmux.withRuntime $ \runtime -> do
                    getMaskingState >>= (@?= expected)
                    Tmux.withServerIn runtime config $ \outer -> do
                      getMaskingState >>= (@?= expected)
                      first <- Tmux.capture outer
                      inner <- Tmux.withServerIn runtime config $ \inner -> do
                        getMaskingState >>= (@?= expected)
                        assertBool "shared Runtime reused a connection generation"
                          (Tmux.serverGeneration inner /= Tmux.serverGeneration outer)
                        captured <- Tmux.capture inner
                        case Tmux.panes captured of
                          [pane] -> Tmux.lookupPane first pane.ref @?= Left Tmux.ForeignGeneration
                          _ -> assertFailure "unexpected owned fixture graph"
                        pure inner
                      Tmux.tryTmux (Tmux.capture inner) >>= \case
                        Left (ExceptionWithContext _ Tmux.ServerClosed) -> pure ()
                        _ -> assertFailure "inner scope did not close its handle"
                      captured <- Tmux.capture outer
                      pure (runtime, outer, captured)
                  length (Tmux.panes snapshot) @?= 1
                  Tmux.tryTmux (Tmux.capture closed) >>= \case
                    Left (ExceptionWithContext _ Tmux.ServerClosed) -> pure ()
                    _ -> assertFailure "outer scope did not close its handle"
                  Tmux.tryTmux (Tmux.withServerIn runtime config Tmux.capture) >>= \case
                    Left (ExceptionWithContext _ Tmux.RuntimeClosed) -> pure ()
                    _ -> assertFailure "closed Runtime admitted another handle"
            check Unmasked
            mask_ (check MaskedInterruptible)

      , testCase "Runtime closure retires an adopted handle whose application callback is still running" $
          Fixture.withFixture $ \fixture -> do
            let config = (Tmux.serverConfig (Os.fromBytestring (Bytes.pack fixture.socket)))
                  { Tmux.executable = Os.fromBytestring (Bytes.pack fixture.executable) }
            runtimeReady <- newEmptyTMVarIO
            handleReady <- newEmptyTMVarIO
            release <- newEmptyTMVarIO
            withAsync (do
              runtime <- atomically (readTMVar runtimeReady)
              Tmux.withServerIn runtime config $ \server -> do
                atomically (putTMVar handleReady ())
                atomically (readTMVar release)
                Tmux.tryTmux (Tmux.capture server)) $ \worker ->
                  flip finally (atomically (tryPutTMVar release ()) >> pure ()) $ do
                    Tmux.withRuntime $ \runtime -> do
                      atomically (putTMVar runtimeReady runtime)
                      race (atomically (readTMVar handleReady)) (waitCatch worker) >>= \case
                        Left () -> pure ()
                        Right (Left problem) -> throwIO problem
                        Right (Right _) -> assertFailure "borrowed handle returned before its ready event"
                    atomically (putTMVar release ())
                    wait worker >>= \case
                      Left (ExceptionWithContext _ Tmux.ServerClosed) -> pure ()
                      _ -> assertFailure "Runtime closure left the borrowed handle open"

      , testCase "application IO errors keep their class while another handle remains usable" $
          Fixture.withFixture $ \fixture -> do
            let config = (Tmux.serverConfig (Os.fromBytestring (Bytes.pack fixture.socket)))
                  { Tmux.executable = Os.fromBytestring (Bytes.pack fixture.executable) }
            Tmux.withRuntime $ \runtime -> Tmux.withServerIn runtime config $ \healthy -> do
              result <- try @IOError $ Tmux.withServerIn runtime config $ \_ ->
                ioError (userError "shared application failure")
              case result of
                Left problem -> ioeGetErrorString problem @?= "shared application failure"
                Right (_ :: ()) -> assertFailure "application failure was lost"
              Tmux.capture healthy >>= \snapshot -> length (Tmux.panes snapshot) @?= 1

      , testCase "failed adoption leaves the shared Runtime and healthy handle usable" $
          Fixture.withFixture $ \fixture -> do
            let config = (Tmux.serverConfig (Os.fromBytestring (Bytes.pack fixture.socket)))
                  { Tmux.executable = Os.fromBytestring (Bytes.pack fixture.executable) }
                missing = config
                  { Server.socketPath = Os.fromBytestring (Bytes.pack (fixture.directory </> "missing")) }
            Tmux.withRuntime $ \runtime -> Tmux.withServerIn runtime config $ \healthy -> do
              Tmux.tryTmux (Tmux.withServerIn runtime missing Tmux.capture) >>= \case
                Left (ExceptionWithContext _ (Tmux.OperationFailed _)) -> pure ()
                _ -> assertFailure "missing endpoint did not report an operational failure"
              Tmux.capture healthy >>= \snapshot -> length (Tmux.panes snapshot) @?= 1
              entries <- filter (isPrefixOf "lt-") <$> Directory.listDirectory fixture.directory
              length entries @?= 1

      , testCase "nested Runtime and Server cleanup preserve their recovery annotations" $
          Fixture.withFixture $ \fixture -> do
            let config = (Tmux.serverConfig (Os.fromBytestring (Bytes.pack fixture.socket)))
                  { Tmux.executable = Os.fromBytestring (Bytes.pack fixture.executable) }
            blocked <- newIORef Nothing
            let clear = readIORef blocked >>= mapM_ (\path -> do
                  exists <- Directory.doesFileExist path
                  when exists (Directory.removeFile path))
            flip finally clear $ do
              result <- Tmux.tryTmux $ Tmux.withRuntime $ \runtime ->
                Tmux.withServerIn runtime config $ \_ -> do
                  entries <- filter (isPrefixOf "lt-") <$> Directory.listDirectory fixture.directory
                  case entries of
                    [directory] -> do
                      let path = fixture.directory </> directory </> "hold"
                      writeIORef blocked (Just path)
                      writeFile path "owned nested cleanup obstacle"
                    _ -> assertFailure "nested scope did not create one pin directory"
              case result of
                Left (ExceptionWithContext context (Tmux.CleanupFailed _ _)) -> do
                  let recoveries = Tmux.cleanupRecoveries context
                  assertBool "nested scope discarded its original cleanup annotation" (length recoveries >= 2)
                  clear
                  forM_ recoveries $ \recovery ->
                    Tmux.resumeCleanup recovery >>= \status -> status.complete @?= True
                _ -> assertFailure "nested cleanup failure was lost"

      , testCase "public selected recovery leaves the healthy scope open" $
          Fixture.withFixture $ \fixture -> do
            let config = (Tmux.serverConfig (Os.fromBytestring (Bytes.pack fixture.socket)))
                  { Tmux.executable = Os.fromBytestring (Bytes.pack fixture.executable) }
            blocked <- newIORef Nothing
            let clear = readIORef blocked >>= mapM_ (\path -> do
                  exists <- Directory.doesFileExist path
                  when exists (Directory.removeFile path))
            flip finally clear $ Tmux.withRuntime $ \runtime ->
              Tmux.withServerIn runtime config $ \healthy -> do
                before <- Directory.listDirectory fixture.directory
                result <- Tmux.tryTmux $ Tmux.withServerIn runtime config $ \_ -> do
                  after <- Directory.listDirectory fixture.directory
                  case filter (\entry -> isPrefixOf "lt-" entry && entry `notElem` before) after of
                    [directory] -> do
                      let path = fixture.directory </> directory </> "hold"
                      writeIORef blocked (Just path)
                      writeFile path "owned selected cleanup obstacle"
                    _ -> assertFailure "selected scope did not create one owned pin directory"
                case result of
                  Left (ExceptionWithContext context (Tmux.CleanupFailed status _)) -> do
                    status.pendingHandles @?= 1
                    case Tmux.cleanupRecoveries context of
                      [recovery] -> do
                        Tmux.capture healthy >>= \snapshot -> length (Tmux.panes snapshot) @?= 1
                        clear
                        Tmux.resumeCleanup recovery >>= \finished -> finished.complete @?= True
                        Tmux.awaitCleanup recovery >>= \finished -> finished.complete @?= True
                        Tmux.capture healthy >>= \snapshot -> length (Tmux.panes snapshot) @?= 1
                      other -> assertFailure ("selected cleanup owner was lost: " <> show other)
                  _ -> assertFailure "selected cleanup failure was lost"
      ]
  ]
