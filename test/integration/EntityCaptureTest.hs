module EntityCaptureTest (tests) where

import Control.Concurrent.Async (cancel, withAsync)
import Control.Concurrent.STM
import Control.Exception (bracket, try)
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef
import Data.Text.Encoding qualified as Utf8
import Fixture qualified
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.Capture qualified as C
import LibTmux.Internal.Graph qualified as G
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Runtime qualified as R
import System.Exit (ExitCode (..))
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
