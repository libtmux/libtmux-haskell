module RuntimeTest (tests) where

import Control.Concurrent.Async (AsyncCancelled (..), cancel, waitCatch, withAsync)
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (forM_, replicateM, when)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef
import Fixture qualified
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Native qualified as N
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.SocketPin
import System.Exit (ExitCode (..))
import System.Posix.Files.ByteString qualified as Files
import System.Posix.IO.ByteString qualified as Posix
import System.IO.Error (ioeGetErrorString)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "provisional Runtime ownership"
  [ testCase "client quota is reserved before endpoint adoption" $
      withRuntime $ \runtime fixture -> do
        clients <- replicateM 8 (adopt runtime fixture)
        checkpoints <- newIORef (0 :: Int)
        let observe _ _ = modifyIORef' checkpoints (+ 1)
        try @B.LimitError (adoptWith observe runtime fixture) >>= \case
          Left actual -> actual @?= B.Exhausted B.Clients 1 8 8
          Right _ -> assertFailure "ninth client was admitted"
        readIORef checkpoints >>= (@?= 0)
        atomically (R.usage runtime) >>= (@?= B.Usage True 8 0 0)
        _ <- R.requestClose runtime
        R.awaitCleanup runtime
        atomically (R.inspect runtime) >>= assertEmpty
        forM_ clients $ \client -> Files.fileExist (pinPath (R.clientPin client)) >>= (@?= False)

  , testCase "cancelled partial adoption retains its cleanup owner and credit" $
      withRuntime $ \runtime fixture -> do
        registered <- newEmptyTMVarIO
        let checkpoint point directory = when (point == DirectoryRegistered) $ do
              let obstacle = directory <> "/hold"
              Posix.createFile obstacle 0o600 >>= Posix.closeFd
              atomically (putTMVar registered (directory, obstacle))
              atomically retry
        withAsync (adoptWith checkpoint runtime fixture) $ \worker -> do
          (directory, obstacle) <- atomically (readTMVar registered)
          flip finally (Files.removeLink obstacle) $ do
            atomically (R.inspect runtime) >>= assertPending 1
            healthy <- adopt runtime fixture
            cancel worker
            waitCatch worker >>= assertCancelled
            try @PinError (R.awaitCleanup runtime) >>= \case
              Left (SocketPinCleanupFailed _) -> pure ()
              _ -> assertFailure "partial pin cleanup failure was lost"
            P.awaitCleanup (R.clientPool healthy)
            Files.fileExist (pinPath (R.clientPin healthy)) >>= (@?= False)
            atomically (R.usage runtime) >>= (@?= B.Usage False 1 0 0)
            atomically (R.inspect runtime) >>= assertPending 1
            Files.fileExist directory >>= (@?= True)
          _ <- R.requestClose runtime
          R.awaitCleanup runtime
          Files.fileExist directory >>= (@?= False)
        atomically (R.inspect runtime) >>= assertEmpty

  , testCase "close observes an adoption before it can publish a client" $
      withRuntime $ \runtime fixture -> do
        registered <- newEmptyTMVarIO
        release <- newEmptyTMVarIO
        let checkpoint point _ = when (point == BeforePublish) $ do
              atomically (putTMVar registered ())
              atomically (readTMVar release)
        withAsync (adoptWith checkpoint runtime fixture) $ \worker ->
          flip finally (atomically (tryPutTMVar release ()) >> pure ()) $ do
            atomically (readTMVar registered)
            atomically (R.inspect runtime) >>= assertPending 1
            _ <- R.requestClose runtime
            atomically (R.usage runtime) >>= (@?= B.Usage False 1 0 0)
            touched <- newIORef False
            try @B.LimitError (adoptWith (\_ _ -> writeIORef touched True) runtime fixture) >>= \case
              Left B.AdmissionClosed -> pure ()
              _ -> assertFailure "closed Runtime admitted another endpoint"
            readIORef touched >>= (@?= False)
            atomically (putTMVar release ())
            waitCatch worker >>= \case
              Left problem -> case fromException problem of
                Just P.PoolClosed -> pure ()
                _ -> assertFailure ("wrong adoption close result: " <> show problem)
              Right _ -> assertFailure "closed adoption returned a client"
        R.awaitCleanup runtime
        atomically (R.inspect runtime) >>= assertEmpty

  , testCase "adopted pins execute inspection and retire without registry growth" $
      withRuntime $ \runtime fixture -> do
        (code, expected, errors) <- Fixture.command fixture ["display-message", "-p", "#{pid}"]
        code @?= ExitSuccess
        errors @?= ""
        forM_ [1 .. 12 :: Int] $ \_ -> do
          client <- adopt runtime fixture
          atomically (R.inspect runtime) >>= assertPending 1
          let tmux = Ascii.pack fixture.executable
              spec = N.spec tmux [tmux, "-u", "-N", "-S", pinPath (R.clientPin client),
                "display-message", "-p", "#{pid}"]
          result <- P.submit B.Inspection P.defaultHooks (R.clientPool client) spec "" >>= P.await
          result.exit @?= Just (N.Exited 0)
          result.output @?= Lazy.toStrict expected
          result.errors @?= ""
          _ <- R.closeClient client
          P.awaitCleanup (R.clientPool client)
          _ <- R.closeClient client
          atomically (R.inspect runtime) >>= assertEmpty
          atomically (R.usage runtime) >>= (@?= B.Usage True 0 0 0)
          Files.fileExist (pinPath (R.clientPin client)) >>= (@?= False)

  , testCase "failed cleanup restart is reported before waiting and remains retryable" $ do
      refuse <- newIORef False
      blocked <- newIORef True
      let fork :: P.Fork
          fork action = atomicModifyIORef' refuse (\old -> (False, old)) >>= \case
            True -> throwIO (userError "injected Runtime cleanup restart failure")
            False -> P.normalFork action
          cleanup runtime = do
            writeIORef refuse False
            writeIORef blocked False
            R.awaitCleanup runtime
      Fixture.withFixture $ \fixture -> bracket (R.newRuntime fork) cleanup $ \runtime -> do
        client <- adopt runtime fixture
        healthy <- adopt runtime fixture
        let tmux = Ascii.pack fixture.executable
            spec = N.spec tmux [tmux, "-u", "-N", "-S", pinPath (R.clientPin client),
              "display-message", "-p", "#{pid}"]
            hooks = P.defaultHooks
              { P.afterStart = throwIO (userError "injected Runtime worker failure")
              , P.signalChild = \child -> readIORef blocked >>= \case
                  True -> throwIO (userError "injected Runtime child cleanup failure")
                  False -> N.signalChild child 9
              }
        ticket <- P.submit B.Ordinary hooks (R.clientPool client) spec ""
        try @IOException (P.await ticket) >>= \case
          Left _ -> pure ()
          Right _ -> assertFailure "worker failure was lost"
        writeIORef blocked False
        writeIORef refuse True
        result <- timeout 250000 (try @IOException (R.awaitCleanup runtime))
        case result of
          Just (Left problem) -> ioeGetErrorString problem @?= "injected Runtime cleanup restart failure"
          Just (Right ()) -> assertFailure "failed cleanup was reported complete"
          Nothing -> assertFailure "known cleanup restart failure became a blocked wait"
        P.awaitCleanup (R.clientPool healthy)
        atomically (R.inspect runtime) >>= \report -> do
          assertPending 1 report
          length report.closeFailures @?= 1
        atomically (R.usage runtime) >>= (@?= B.Usage False 1 1 P.childBytes)
        R.awaitCleanup runtime
        atomically (R.inspect runtime) >>= assertEmpty
        atomically (R.usage runtime) >>= (@?= B.Usage False 0 0 0)
  ]

withRuntime :: (R.Runtime -> Fixture.Fixture -> IO a) -> IO a
withRuntime action = Fixture.withFixture $ \fixture ->
  bracket (R.newRuntime P.normalFork) R.awaitCleanup (\runtime -> action runtime fixture)

adopt :: R.Runtime -> Fixture.Fixture -> IO R.Client
adopt runtime fixture = R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)

adoptWith :: (PinCheckpoint -> Bytes.ByteString -> IO ()) -> R.Runtime -> Fixture.Fixture -> IO R.Client
adoptWith checkpoint runtime fixture =
  R.adoptWith checkpoint runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)

assertPending :: Int -> R.Report -> Assertion
assertPending expected report = length report.pending @?= expected

assertEmpty :: R.Report -> Assertion
assertEmpty = assertPending 0

assertCancelled :: Either SomeException a -> Assertion
assertCancelled (Left problem) = case fromException problem of
  Just AsyncCancelled -> pure ()
  _ -> assertFailure ("cancellation changed: " <> show problem)
assertCancelled (Right _) = assertFailure "expected cancellation"
