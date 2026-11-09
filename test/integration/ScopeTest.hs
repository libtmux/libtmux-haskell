module ScopeTest (tests) where

import Control.Concurrent.Async (Async, AsyncCancelled (..), cancel, race, waitCatch, withAsync)
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (forM_, when)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as Bytes
import Data.IORef
import Fixture qualified
import LibTmux.Internal.Capture qualified as C
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.Scope qualified as Scope
import LibTmux.Internal.SocketPin
import ProcessGate qualified as Gate
import System.IO.Error (ioeGetErrorString)
import System.Posix.Files.ByteString qualified as Files
import System.Posix.IO.ByteString qualified as Posix
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

data BodyFailure = BodyFailure deriving stock (Eq, Show)
instance Exception BodyFailure

tests :: TestTree
tests = testGroup "Server scope outcomes"
  [ testCase "successful callback and cleanup return the callback value" $
      bracket (R.newRuntime P.normalFork) R.awaitCleanup $ \runtime -> do
        Scope.runScope runtime (pure (42 :: Int)) >>= (@?= 42)
        atomically (R.inspect runtime) >>= \report -> do
          report.accepting @?= False
          length report.pending @?= 0

  , testCase "successful cleanup preserves a callback exception" $
      bracket (R.newRuntime P.normalFork) R.awaitCleanup $ \runtime -> do
        result <- try @SomeException (Scope.runScope runtime (throwIO BodyFailure :: IO ()))
        problem <- failed result
        fromException problem @?= Just BodyFailure
        length (Scope.cleanupRecoveries problem) @?= 0

  , testCase "cleanup failure after a successful callback retains retry ownership" $
      withRuntime P.normalFork $ \runtime fixture -> withBlockedPin runtime fixture $ \obstacle -> do
        result <- try @SomeException (Scope.runScope runtime (pure (42 :: Int)))
        problem <- failed result
        case fromException problem of
          Just (Scope.CleanupFailed status _) -> do
            status.complete @?= False
            status.pendingHandles @?= 1
          other -> assertFailure ("cleanup failure was not reported: " <> show other)
        recovery <- oneRecovery problem
        Scope.inspectCleanup recovery >>= \status -> status.pendingHandles @?= 1
        Files.removeLink obstacle
        Scope.resumeCleanup recovery >>= \status -> status.complete @?= True

  , testCase "callback failure stays primary when pin cleanup also fails" $
      withRuntime P.normalFork $ \runtime fixture -> withBlockedPin runtime fixture $ \obstacle -> do
        result <- try @SomeException (Scope.runScope runtime (throwIO BodyFailure :: IO ()))
        problem <- failed result
        fromException problem @?= Just BodyFailure
        recovery <- oneRecovery problem
        status <- Scope.inspectCleanup recovery
        status.complete @?= False
        assertBool "pin cleanup diagnostic was lost" (not (null status.failures))
        Files.removeLink obstacle
        Scope.resumeCleanup recovery >>= \finished -> finished.complete @?= True

  -- An accepted native launch deliberately outlives both bounded cleanup phases.
  , testCase "cancellation retains its class and the owner of an accepted launch" $
      withRuntime P.normalFork $ \runtime fixture -> Gate.withGate $ \gate -> do
        client <- adopt runtime fixture
        let hooks = P.defaultHooks {P.launchNative = Gate.launch Gate.AfterLaunch gate}
            action = C.captureSnapshotWith hooks runtime client (Bytes.pack fixture.executable) 2000000
        recovery <- flip finally (Gate.releaseGate gate) $
          withAsync (Scope.runScope runtime action) $ \worker -> do
            awaitReady (Gate.awaitGate gate) worker
            cancel worker
            problem <- waitCatch worker >>= failed
            fromException problem @?= Just AsyncCancelled
            recovery <- oneRecovery problem
            status <- Scope.inspectCleanup recovery
            status.complete @?= False
            status.pendingHandles @?= 1
            status.pendingReads @?= 1
            length (C.captureRecoveries problem) @?= 1
            pure recovery
        R.awaitCleanup runtime
        status <- Scope.inspectCleanup recovery
        forM_ status.unresolved $ \(operation, _) -> do
          _ <- Scope.detachUnresolved recovery operation
          pure ()
        Scope.inspectCleanup recovery >>= \finished -> finished.complete @?= True

  , testCase "failed shutdown worker allocation retains ownership and its diagnostic" $ do
      refuse <- newIORef False
      let fork :: P.Fork
          fork action = readIORef refuse >>= \blocked ->
            if blocked then throwIO (userError "scope cleanup worker refused") else P.normalFork action
          cleanup runtime = writeIORef refuse False >> R.awaitCleanup runtime
      Fixture.withFixture $ \fixture -> bracket (R.newRuntime fork) cleanup $ \runtime -> do
        _ <- adopt runtime fixture
        result <- try @SomeException (Scope.runScope runtime (writeIORef refuse True))
        problem <- failed result
        case fromException problem of
          Just (Scope.CleanupFailed status (Just cause)) -> do
            status.pendingHandles @?= 1
            case fromException cause of
              Just io -> ioeGetErrorString io @?= "scope cleanup worker refused"
              Nothing -> assertFailure "worker refusal lost its original diagnostic"
          other -> assertFailure ("worker refusal was not reported: " <> show other)
        recovery <- oneRecovery problem
        writeIORef refuse False
        Scope.resumeCleanup recovery >>= \status -> status.complete @?= True

  , testCase "callback failure stays primary when shutdown worker allocation fails" $ do
      refuse <- newIORef False
      let fork :: P.Fork
          fork action = readIORef refuse >>= \blocked ->
            if blocked then throwIO (userError "double failure") else P.normalFork action
          cleanup runtime = writeIORef refuse False >> R.awaitCleanup runtime
      Fixture.withFixture $ \fixture -> bracket (R.newRuntime fork) cleanup $ \runtime -> do
        _ <- adopt runtime fixture
        result <- try @SomeException $ Scope.runScope runtime $ do
          writeIORef refuse True
          throwIO BodyFailure :: IO ()
        problem <- failed result
        fromException problem @?= Just BodyFailure
        recovery <- oneRecovery problem
        case Scope.cleanupFailure recovery >>= fromException of
          Just cause -> ioeGetErrorString cause @?= "double failure"
          Nothing -> assertFailure "primary failure lost its cleanup diagnostic"
        writeIORef refuse False
        Scope.resumeCleanup recovery >>= \status -> status.complete @?= True

  , testCase "cancellation during cleanup allocation preserves cancellation and ownership" $ do
      block <- newIORef False
      ready <- newEmptyTMVarIO
      let fork :: P.Fork
          fork action = do
            blocked <- readIORef block
            when blocked $ atomically (putTMVar ready ()) >> atomically retry
            P.normalFork action
          cleanup runtime = writeIORef block False >> R.awaitCleanup runtime
      Fixture.withFixture $ \fixture -> bracket (R.newRuntime fork) cleanup $ \runtime -> do
        _ <- adopt runtime fixture
        recovery <- withAsync (Scope.runScope runtime (writeIORef block True)) $ \worker -> do
          awaitReady (atomically (takeTMVar ready)) worker
          cancel worker
          problem <- waitCatch worker >>= failed
          fromException problem @?= Just AsyncCancelled
          recovery <- oneRecovery problem
          case Scope.cleanupFailure recovery >>= fromException of
            Just AsyncCancelled -> pure ()
            _ -> assertFailure "cleanup cancellation lost its original class"
          pure recovery
        writeIORef block False
        Scope.resumeCleanup recovery >>= \status -> status.complete @?= True
  ]

failed :: Either SomeException value -> IO SomeException
failed (Left problem) = pure problem
failed (Right _) = assertFailure "scope unexpectedly succeeded" >> fail "expected scope failure"

oneRecovery :: SomeException -> IO Scope.CleanupRecovery
oneRecovery problem = case Scope.cleanupRecoveries problem of
  [recovery] -> pure recovery
  other -> assertFailure ("expected one cleanup owner: " <> show other) >> fail "missing cleanup owner"

awaitReady :: IO () -> Async value -> IO ()
awaitReady ready worker = race ready (waitCatch worker) >>= \case
  Left () -> pure ()
  Right result -> assertFailure ("scope completed before its native checkpoint: " <> either show (const "success") result)

adopt :: R.Runtime -> Fixture.Fixture -> IO R.ServerHandle
adopt runtime fixture = R.adopt runtime (Bytes.pack fixture.socket) (Bytes.pack fixture.directory)

withRuntime :: P.Fork -> (R.Runtime -> Fixture.Fixture -> IO a) -> IO a
withRuntime fork action = Fixture.withFixture $ \fixture ->
  bracket (R.newRuntime fork) R.awaitCleanup $ \runtime -> action runtime fixture

withBlockedPin :: R.Runtime -> Fixture.Fixture -> (ByteString -> IO a) -> IO a
withBlockedPin runtime fixture action = do
  selected <- newIORef Nothing
  let checkpoint point directory = when (point == BeforePublish) $ do
        let obstacle = directory <> "/hold"
        Posix.createFile obstacle 0o600 >>= Posix.closeFd
        writeIORef selected (Just obstacle)
  _ <- R.adoptWith checkpoint runtime (Bytes.pack fixture.socket) (Bytes.pack fixture.directory)
  readIORef selected >>= \case
    Nothing -> assertFailure "pin checkpoint did not run" >> fail "missing obstacle"
    Just obstacle -> action obstacle `finally` do
      present <- Files.fileExist obstacle
      when present (Files.removeLink obstacle)
