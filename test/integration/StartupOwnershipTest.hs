-- | Physical startup evidence independent of command receipts.
module StartupOwnershipTest (tests) where

import Control.Concurrent.Async (AsyncCancelled (..), cancel, wait, waitCatch, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, tryPutMVar)
import Control.Exception
import Control.Monad (forM_, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as Ascii
import Data.IORef
import Data.Maybe (isJust)
import Foreign.C.Error (eCHILD, eCONNREFUSED, eNOENT)
import Foreign.C.Types (CInt)
import GHC.Conc (threadWaitRead)
import LibTmux.Internal.Capture qualified as C
import LibTmux.Internal.Graph qualified as G
import LibTmux.Internal.OwnedServer qualified as OS
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Native qualified as N
import LibTmux.Internal.Scope (CleanupStatus (..))
import ProcessGate qualified as Gate
import System.Directory (doesPathExist)
import System.Environment (lookupEnv)
import System.Posix.Files.ByteString qualified as Files
import System.Posix.Types (Fd (..))
import Test.Tasty (TestTree, localOption, mkTimeout, testGroup)
import Test.Tasty.HUnit

data Watch = Watch
  { names :: IORef (Maybe OS.Names)
  , processes :: IORef [CInt]
  , socketAnchor :: IORef (Maybe CInt)
  , peerWitness :: IORef (Maybe CInt)
  , associated :: IORef Bool
  }

withWatch :: (Watch -> IO a) -> IO a
withWatch = bracket acquire release
  where
    acquire = Watch <$> newIORef Nothing <*> newIORef [] <*> newIORef Nothing <*> newIORef Nothing <*> newIORef False
    release watch = do
      readIORef watch.processes >>= mapM_ (\fd -> do
        gone <- OS.awaitExit fd 0
        unless gone $ do
          void (N.cSignal fd 9)
          OS.awaitExit fd 2000 >>= assertBool "test-owned startup process did not exit"
        N.close fd)
      readIORef watch.socketAnchor >>= mapM_ N.close
      readIORef watch.peerWitness >>= mapM_ N.close

watching :: Watch -> P.Hooks -> OS.Probe
watching watch hooks = OS.defaultProbe
  { OS.hooks = hooks {P.launchNative = \spec -> do
      let startup = elem "-D" spec.args || elem "start-server" spec.args
      when startup $ case dropWhile (/= "-S") spec.args of
        _ : socket : _ -> writeIORef watch.names
          (Just (OS.Names (Ascii.init (fst (Ascii.breakEnd (== '/') socket))) socket))
        _ -> pure ()
      started <- hooks.launchNative spec
      when startup $ case started of
        N.Refused _ -> pure ()
        N.Owned child -> do
          copy <- OS.cDup child.pidfd
          when (copy >= 0) (modifyIORef' watch.processes (copy :))
          readIORef watch.peerWitness >>= mapM_ (\peer -> do
            expected <- OS.pidfdPid child.pidfd
            observed <- OS.pidfdPid peer
            writeIORef watch.associated (isJust expected && expected == observed))
      pure started}
  , OS.stage = \_ known -> writeIORef watch.names (Just known)
  }

assertPhysical :: Watch -> Assertion
assertPhysical watch = do
  observed <- readIORef watch.processes
  assertBool "startup process was not independently witnessed" (not (null observed))
  peer <- readIORef watch.peerWitness
  forM_ peer $ \_ -> readIORef watch.associated >>= assertBool "the listener witness is not the spawned child"
  forM_ (observed <> maybe [] pure peer) $ \fd -> do
    OS.awaitExit fd 0 >>= assertBool "startup child physically alive after cleanup"
    -- This duplicate names the exact test child; ECHILD confirms its status was
    -- already collected. A missed collection is consumed here and fails the test.
    N.waitChild (N.Child fd (-1) (-1) (-1)) >>= \case
      Just (N.StatusLost problem) | problem == N.errno eCHILD -> pure ()
      other -> assertFailure ("the startup child's status was left uncollected: " <> show other)

assertNamesGone :: Watch -> Assertion
assertNamesGone watch = readIORef watch.names >>= mapM_ (\known ->
  doesPathExist (Ascii.unpack known.directory) >>= assertBool "private directory retained" . not)

tests :: TestTree
tests = localOption (mkTimeout 5000000) $ testGroup "physical startup ownership"
  [ testCase "a refused startup that physically exited keeps no unresolved birth" failedStartup
  , testCase "the ready empty daemon is the spawned child and is collected" $
      withTmux directIdentity
  , testCase "caller cancellation while atomic spawn is held retires the child or retains ownership" $
      withTmux callerDuringSpawn
  ]

failedStartup :: Assertion
failedStartup = withWatch $ \watch -> do
  outcome <- tryWithContext @SomeException $
    OS.withOwnedServerWith (watching watch P.defaultHooks) "/bin/false"
      (\_ -> assertFailure "false admitted")
  assertPhysical watch
  case outcome of
    Right _ -> assertFailure "false startup succeeded"
    Left (ExceptionWithContext context cause) -> do
      case fromException cause of
        Just (OS.StartFailed (Just (N.Exited 1)) _) -> pure ()
        _ -> assertFailure ("unexpected startup failure: " <> show cause)
      assertBool "the exited exact child still has unresolved startup ownership"
        (null (OS.ownedRecoveries context))
  assertNamesGone watch

directIdentity :: ByteString -> Assertion
directIdentity executable = withWatch $ \watch -> do
  OS.withOwnedServerWith (watching watch P.defaultHooks) executable $ \owned -> do
    witnesses <- readIORef watch.processes
    forM_ witnesses $ \fd -> OS.pidfdPid fd >>= (@?= Just owned.daemonPid)
    (_, _, snapshot) <- C.captureSnapshot owned.runtime owned.handle owned.executable 2000000
    G.graphSessions (G.entities snapshot) @?= []
    G.graphWindows (G.entities snapshot) @?= []
    G.graphPanes (G.entities snapshot) @?= []
  assertPhysical watch
  assertNamesGone watch

callerDuringSpawn :: ByteString -> Assertion
callerDuringSpawn executable = Gate.withGate $ \gate -> withWatch $ \watch -> do
  closing <- newEmptyMVar
  let probe = (watching watch P.defaultHooks {P.launchNative = Gate.launch Gate.AfterLaunch gate})
        {OS.phase = \point -> when (point == OS.PhaseClient) (void (tryPutMVar closing ()))}
      body = OS.withOwnedServerWith probe executable
        (\_ -> assertFailure "cancelled startup reached the callback")
  outcome <- withAsync body $ \worker -> finally
    (do Gate.awaitGate gate
        known <- readIORef watch.names >>= maybe (assertFailure "no private names") pure
        witnessBeforeReturn watch known
        withAsync (cancel worker) $ \sender -> do
          takeMVar closing
          Gate.releaseGate gate
          wait sender
        waitCatch worker)
    (Gate.releaseGate gate)
  context <- case outcome of
    Left problem | Just AsyncCancelled <- fromException problem -> pure (someExceptionContext problem)
    other -> assertFailure ("startup cancellation changed class: " <> either show (const "success") other)
  assertPhysical watch
  known <- readIORef watch.names >>= maybe (assertFailure "no private names") pure
  retained <- doesPathExist (Ascii.unpack known.directory)
  when retained $ case OS.ownedRecoveries context of
    [recovery] -> do
      let owner = OS.recoveryOwner recovery
      OS.observeOwned owner >>= assertBool "retained namespace was reported complete" . not . (.complete)
      -- The independent anchor was taken through the original listener before
      -- cancellation. Test cleanup removes only that same inode.
      removeWitnessed watch.socketAnchor known.socket
      OS.settle owner
      OS.observeOwned owner >>= assertBool "recovery did not finish" . (.complete)
    _ -> assertFailure "retained private names lost their reachable owner"
  assertNamesGone watch

-- The native call is held after birth but before its result reaches Haskell.
-- Take the listener's independent process and inode witnesses before cancelling.
witnessBeforeReturn :: Watch -> OS.Names -> IO ()
witnessBeforeReturn watch known = bracket arm N.close $ \events -> do
  loop events
  void (OS.awaitLock known.directory (known.socket <> ".lock") (pure ()))
  where
    arm = Ascii.useAsCString known.directory $ \path -> OS.cWatchStart path >>= \fd ->
      if fd < 0 then N.raise (negate fd) else pure fd
    loop events = OS.anchoredPeer known.socket >>= \case
      Right (anchor, fd) -> do
        writeIORef watch.socketAnchor (Just anchor)
        writeIORef watch.peerWitness (Just fd)
      Left problem
        | problem == N.errno eNOENT || problem == N.errno eCONNREFUSED -> do
            threadWaitRead (Fd events)
            rc <- OS.cWatchDrain events
            when (rc < 0) (N.raise (negate rc))
            loop events
        | otherwise -> N.raise problem

removeWitnessed :: IORef (Maybe CInt) -> ByteString -> IO ()
removeWitnessed cell path = readIORef cell >>= mapM_ (\anchor -> do
  current <- OS.statusIfPresent path
  original <- Files.getFdStatus (Fd anchor)
  forM_ current $ \entry -> do
    assertBool "test cleanup refused a replacement name" (OS.identity entry == OS.identity original)
    Files.removeLink path)

withTmux :: (ByteString -> IO a) -> IO a
withTmux action = lookupEnv "LIBTMUX_TEST_TMUX" >>= maybe
  (assertFailure "LIBTMUX_TEST_TMUX must name the released binary") (action . Ascii.pack)
