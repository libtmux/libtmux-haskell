module EntityCaptureTest (tests) where

import Control.Concurrent.Async (cancel, withAsync)
import Control.Concurrent.STM
import Control.Exception (bracket, bracket_, try)
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef
import Data.Text.Encoding qualified as Utf8
import Fixture qualified
import GHC.Conc (threadWaitRead)
import LibTmux.Id qualified as Id
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.Capture qualified as C
import LibTmux.Internal.Graph qualified as G
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Native qualified as N
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.SocketPin (pinPath, pinGeneration)
import LibTmux.Internal.TmuxText qualified as Label
import LibTmux.Version qualified as V
import System.Exit (ExitCode (..))
import System.OsString.Posix qualified as Os
import System.Posix.Directory.ByteString qualified as Directory
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as RawIO
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "entity capture"
  [ testCase "hydrates a detached graph while preserving repeated link contexts" $ do
      graph <- withRuntime $ \runtime client fixture -> do
        command fixture ["link-window", "-s", "@0", "-t", "$0:4"]
        command fixture ["new-session", "-d", "-s", "other", "-t", "$0"]
        command fixture ["select-pane", "-t", "%0", "-T", "editor λ"]
        (code, title, errors) <- Fixture.command fixture ["-u", "display-message", "-p", "-t", "%0", "#{pane_title}"]
        (code, title, errors) @?= (ExitSuccess, Lazy.fromStrict (Utf8.encodeUtf8 "editor λ\n"), "")
        (started, ended, graph) <- capture runtime client fixture
        assertBool "reversed capture interval" (started <= ended)
        length (G.graphSessions graph) @?= 2
        length (G.graphWindows graph) @?= 1
        length (G.graphPanes graph) @?= 1
        length (G.graphLinks graph) @?= 4
        length (G.graphOccurrences graph) @?= 4
        map (.name) (G.graphSessions graph) @?= ["fixture", "other"]
        map (.title) (G.graphPanes graph) @?= ["editor λ"]
        command fixture ["rename-session", "-t", "$0", "after-capture"]
        atomically (R.usage runtime) >>= (@?= B.Usage True 1 0 0)
        pure graph
      map (.name) (G.graphSessions graph) @?= ["fixture", "other"]
      length (G.graphOccurrences graph) @?= 4
  , testCase "returns a valid empty graph from an existing empty daemon" $
      withRuntime $ \runtime client fixture -> do
        command fixture ["kill-session", "-t", "$0"]
        (_, _, graph) <- capture runtime client fixture
        G.graphSessions graph @?= []
        G.graphPanes graph @?= []
  , testCase "captures lossless window, process and path values" $ do
      (pane, expectedCommand, expectedPath, label) <- withRuntime $ \runtime client fixture -> do
        let executable = Bytes.pack fixture.executable
            raw args = do
              let spec = N.spec executable
                    ([executable, "-u", "-N", "-S", pinPath (R.clientPin client)] <> args)
              result <- P.submit B.Ordinary P.defaultHooks (R.clientPool client) spec "" >>= P.await
              (result.exit, result.errors) @?= (Just (N.Exited 0), "")
              pure result.output
            path = Bytes.pack fixture.directory <> "/\255"
            readyPath = fixture.directory <> "/ready"
            processName = "cmd\255x"
            rawWindowName = "win\255x"
        releaseBytes <- raw ["display-message", "-p", "-F", "#{version}"]
        release <- either (fail . show) pure (V.parseVersion (Utf8.decodeUtf8 releaseBytes))
        cleanedNames <- either (fail . show) pure (V.parseVersion "3.7")
        Files.createNamedPipe readyPath 0o600
        bracket_ (Directory.createDirectory path 0o700) (Directory.removeDirectory path) $
          bracket (Posix.openFd readyPath Posix.ReadWrite Posix.defaultFileFlags) Posix.closeFd $ \ready -> do
            receipt <- raw ["new-window", "-d", "-n", "byte-fields", "-P", "-F",
              "#{window_id} #{pane_id} #{pane_pid}", "-c", path, "/bin/bash", "-c",
              "exec -a \"$0\" /bin/sh -c 'printf R > \"$1\"; read -r value' \"$0\" \"$1\"",
              processName, Bytes.pack readyPath]
            case Bytes.words receipt of
              [windowId, paneId, pid] -> Fixture.withTrackedPane (Lazy.fromStrict (pid <> "\n"))
                (raw ["kill-window", "-t", windowId] >> pure ()) $ do
                  observed <- timeout 1000000 (threadWaitRead ready >> RawIO.fdRead ready 1)
                  observed @?= Just "R"
                  (_, _, graph) <- capture runtime client fixture
                  length (G.graphPanes graph) @?= 2
                  ident <- either (fail . show) pure (Id.parsePaneId (Utf8.decodeUtf8 paneId))
                  pane <- either (fail . show) pure (G.lookupPane graph (G.PaneRef (pinGeneration (R.clientPin client)) ident))
                  label <- if release >= cleanedNames then pure Nothing else do
                    named <- raw ["new-window", "-d", "-n", rawWindowName, "-P", "-F",
                      "#{window_id} #{pane_pid}", "/bin/cat", "-"]
                    case Bytes.words named of
                      [namedWindow, namedPid] -> Fixture.withTrackedPane (Lazy.fromStrict (namedPid <> "\n"))
                        (raw ["kill-window", "-t", namedWindow] >> pure ()) $ do
                          (_, _, namedGraph) <- capture runtime client fixture
                          windowIdent <- either (fail . show) pure (Id.parseWindowId (Utf8.decodeUtf8 namedWindow))
                          window <- either (fail . show) pure (G.lookupWindow namedGraph
                            (G.WindowRef (pinGeneration (R.clientPin client)) windowIdent))
                          pure (Just window.name)
                      other -> assertFailure ("invalid named-window receipt: " <> show other) >> pure Nothing
                  pure (pane, if release < cleanedNames then processName else "", path, label)
              other -> assertFailure ("invalid creation receipt: " <> show other)
                >> fail "owned pane receipt required"
      pane.currentCommand @?= Os.fromBytestring expectedCommand
      pane.currentPath @?= Os.fromBytestring expectedPath
      case label of
        Nothing -> pure ()
        Just name -> do
          Label.toBytes name @?= "win\255x"
          case Label.decodeUtf8 name of
            Left _ -> pure ()
            Right _ -> assertFailure "non-text window name became valid UTF-8"
  , testCase "retries one changed topology and rejects a second inconsistent attempt" $
      withRuntime $ \runtime client fixture -> do
        calls <- newIORef (0 :: Int)
        let changeOnce = do
              n <- atomicModifyIORef' calls (\n -> (n + 1, n))
              if n == 0 then command fixture ["move-window", "-s", "$0:0", "-t", "$0:4"] else pure ()
        (_, _, graph) <- C.captureGraphWith changeOnce runtime client
          (Bytes.pack fixture.executable) 2000000
        readIORef calls >>= (@?= 2)
        length (G.graphLinks graph) @?= 1
        let changeAlways = do
              n <- atomicModifyIORef' calls (\n -> (n + 1, n))
              let (from, to) = if even n then ("4", "5") else ("5", "4")
              command fixture ["move-window", "-s", "$0:" <> from, "-t", "$0:" <> to]
        try @C.CaptureError (C.captureGraphWith changeAlways runtime client
          (Bytes.pack fixture.executable) 2000000) >>= \case
            Left C.CaptureChanged -> pure ()
            other -> assertFailure ("unstable capture escaped: " <> show other)
        readIORef calls >>= (@?= 4)
        atomically (R.usage runtime) >>= (@?= B.Usage True 1 0 0)
  , testCase "cancellation releases the capture lease while Runtime keeps its owners" $
      withRuntime $ \runtime client fixture -> do
        reached <- newEmptyTMVarIO
        let checkpoint = atomically (putTMVar reached ()) >> atomically retry
        withAsync (C.captureGraphWith checkpoint runtime client
          (Bytes.pack fixture.executable) 2000000) $ \worker -> do
            atomically (takeTMVar reached)
            atomically (R.usage runtime) >>= (@?= B.Usage True 1 0 (64 * 1024 * 1024))
            cancel worker
            atomically (R.usage runtime) >>= (@?= B.Usage True 1 0 0)
  ]

capture :: R.Runtime -> R.Client -> Fixture.Fixture -> IO C.CapturedGraph
capture runtime client fixture = C.captureGraph runtime client (Bytes.pack fixture.executable) 2000000

withRuntime :: (R.Runtime -> R.Client -> Fixture.Fixture -> IO a) -> IO a
withRuntime action = Fixture.withFixture $ \fixture ->
  bracket (R.newRuntime P.normalFork) R.awaitCleanup $ \runtime -> do
    client <- R.adopt runtime (Bytes.pack fixture.socket) (Bytes.pack fixture.directory)
    action runtime client fixture

command :: Fixture.Fixture -> [String] -> IO ()
command fixture args = do
  (code, _, errors) <- Fixture.command fixture args
  assertEqual (show errors) ExitSuccess code
