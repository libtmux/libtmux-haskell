{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
module ProcessTest (withTests) where

import Control.Concurrent (throwTo)
import Control.Concurrent.Async (AsyncCancelled (..), asyncThreadId, cancel, wait, waitCatch, withAsync)
import Control.Concurrent.STM (atomically, check, newEmptyTMVarIO, newTVarIO, putTMVar, readTMVar, readTVar, retry, writeTVar)
import Control.Exception (bracket_, mask, onException, IOException, SomeException, bracket, finally, fromException, throwIO, try)
import Control.Monad (replicateM_, unless, when)
import Data.ByteString qualified as Bytes
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Internal qualified as BytesInternal
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Ptr (Ptr, nullPtr, plusPtr)
import Foreign.C.Types (CSize (..), CUInt (..), CInt (..))
import Data.ByteString.Char8 qualified as Ascii
import Data.ByteString.Lazy qualified as Lazy
import Data.IntSet qualified as Set
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import Fixture qualified
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.SocketPin
import LibTmux.Internal.Process.Native qualified as N
import ProcessGate qualified as G
import LibTmux.Internal.Process qualified as O
import System.Directory (removePathForcibly)
import System.Posix.Temp (mkdtemp)
import System.Process.Typed (proc, readProcess)
import System.Exit (ExitCode (..))
import System.Posix.Types (Fd (..))
import System.Posix.Directory.ByteString qualified as Directory
import System.Posix.Files.ByteString qualified as Files
import System.Posix.IO.ByteString qualified as Posix
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

foreign import ccall unsafe "libtmux_test_watch_input" watchInput :: Ptr a -> CSize -> IO ()
foreign import ccall unsafe "libtmux_test_shared_writes" sharedWrites :: IO CUInt

foreign import ccall unsafe "libtmux_test_high_descriptor" highDescriptor :: IO CInt
foreign import ccall unsafe "libtmux_test_blocked_writes" blockedWrites :: IO CUInt

foreign import ccall safe "libtmux_test_stolen_wait" stolenWait :: N.WaitCall

-- Compile once in the outer tier; bracket owns the test-runner handoff.
withTests :: (TestTree -> IO a) -> IO a
withTests action = bracket buildChild (removePathForcibly . fst) $ \helpers ->
  action (tests (pure helpers))

tests :: IO (FilePath, (Bytes.ByteString, FilePath)) -> TestTree
tests getChild = testGroup "private process owner"
    [ testGroup "isolated host policies"
        [ testCase mode $ do
            (_, (_, policy)) <- getChild
            (code, output, errors) <- readProcess (proc policy [mode])
            (code, output, errors) @?= (ExitSuccess, "", "")
        | mode <- ["no-spawn", "no-chdir", "no-closefrom", "kernel-refusal",
            "ignored-child", "no-child-status", "pipe-default", "pipe-ignored",
            "pipe-custom", "pipe-blocked", "pipe-thread-pending", "pipe-process-pending",
            "pipe-both-pending", "closed-stdio"] ]
    , testCase "keeps the action error when cleanup also fails" $ do
        journal <- newTVarIO Nothing
        outcome <- try @SomeException $ O.preservingFinally journal
          (throwIO O.ResourceLimit :: IO ()) (throwIO (userError "cleanup failed"))
        case outcome of
          Left problem -> (fromException problem :: Maybe O.OwnerError) @?= Just O.ResourceLimit
          Right _ -> assertFailure "action unexpectedly succeeded"
        atomically (readTVar journal) >>= \case
          Just problem -> assertBool "cleanup IOException retained separately"
            (isJust (fromException problem :: Maybe IOException))
          Nothing -> assertFailure "cleanup error was lost"

    , testCase "throws a cleanup failure after a successful action" $ do
        journal <- newTVarIO Nothing
        try @IOException (O.preservingFinally journal (pure ()) (throwIO (userError "cleanup failed"))) >>= \case
          Left _ -> pure ()
          Right _ -> assertFailure "cleanup failure unexpectedly became success"

    , testCase "two pools share sixteen pending launches even after waiter cancellation" $ do
        budget <- B.newBudget O.inspectionBytes
        forks <- newIORef (0 :: Int)
        let tracked :: O.Fork
            tracked action = do
              atomicModifyIORef' forks (\n -> (n + 1, ()))
              O.normalFork action
            gates 0 action = action []
            gates n action = G.withGate $ \gate -> gates (n - 1) (action . (gate :))
        (_, (executable, _)) <- getChild
        Fixture.withFixture $ \fixture ->
          withPoolIn budget fixture 16 tracked $ \first firstPin ->
            withPoolIn budget fixture 16 tracked $ \second _ ->
              gates (16 :: Int) $ \held -> G.withGate $ \extra -> do
                let start allocation pool gate = O.submit allocation (O.defaultHooks {O.launchNative = G.launch G.BeforeLaunch gate})
                      pool (N.spec executable [executable, "--wait"]) ""
                    release = mapM_ G.releaseGate (extra : held)
                (do
                  tickets <- sequence [start allocation pool gate
                    | (allocation, pool, gate) <- zip3 (replicate 15 B.Ordinary <> [B.Inspection])
                        (replicate 8 first <> replicate 8 second) held]
                  mapM_ G.awaitGate held
                  case tickets of
                    initial : _ -> withAsync (O.await initial) $ \waiter -> do
                      cancel waiter
                      waitCatch waiter >>= assertCancelled
                    [] -> assertFailure "no pending launch was created"
                  O.requestClose first >>= assertIncomplete
                  Files.fileExist (pinPath firstPin) >>= assertBool "pending context keeps socket pin"
                  try @B.LimitError (start B.Ordinary second extra) >>= \case
                    Left (B.Exhausted B.Children 1 16 16) -> pure ()
                    _ -> assertFailure "seventeenth child reached native dispatch"
                  readIORef forks >>= (@?= 16)
                  state <- atomically (B.usage budget)
                  state.clients @?= 2
                  state.children @?= 16
                  state.pendingBytes @?= 16 * O.childBytes
                  O.abortAll first
                  O.abortAll second
                  release
                  mapM_ (\ticket -> try @O.OwnerError (O.await ticket) >>= \case
                    Left O.Aborted -> pure ()
                    Right completed -> do
                      -- EOF or SIGKILL may win the race with the abort watcher.
                      completed.launchFailure @?= Nothing
                      assertBool "completion retained a valid owned exit"
                        (completed.exit `elem` [Just (N.Exited 24), Just (N.Signaled 9 False)])
                      atomically (readTVar ticket.exitCache) >>= (@?= completed.exit)
                    Left other -> assertFailure ("unexpected owner failure: " <> show other)) tickets
                  O.awaitCleanup first
                  _ <- O.requestClose second
                  O.awaitCleanup second
                  atomically (B.usage budget) >>= (@?= B.Usage True 0 0 0)) `finally` release

    , testCase "a pool rejects an insufficient inspection allowance" $ do
        budget <- B.newBudget (O.inspectionBytes - 1)
        Fixture.withFixture $ \fixture -> bracket newPinOwner closePin $ \owner -> do
          pin <- acquirePin owner (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
          try @O.OwnerError (O.newPool budget O.normalFork owner 16) >>= \case
            Left O.ResourceLimit -> pure ()
            Left other -> assertFailure ("unexpected pool refusal: " <> show other)
            Right pool -> do
              _ <- O.requestClose pool
              O.awaitCleanup pool
              assertFailure "pool accepted less than its inspection buffer allowance"
          atomically (B.usage budget) >>= (@?= B.Usage True 0 0 0)
          Files.fileExist (pinPath pin) >>= assertBool "refused construction preserves caller pin ownership"

    , testCase "ordinary work leaves the pool inspection slot usable" $ do
        budget <- B.newBudget O.inspectionBytes
        (_, (executable, _)) <- getChild
        Fixture.withFixture $ \fixture -> withPoolIn budget fixture 2 O.normalFork $ \pool pin ->
          G.withGate $ \held -> G.withGate $ \extra -> do
            (code, expected, errors) <- Fixture.command fixture ["display-message", "-p", "#{pid}"]
            code @?= ExitSuccess
            errors @?= ""
            let tmux = Ascii.pack fixture.executable
                inspect = N.spec tmux [tmux, "-N", "-S", pinPath pin, "display-message", "-p", "#{pid}"]
                start gate = O.submit B.Ordinary (O.defaultHooks {O.launchNative = G.launch G.BeforeLaunch gate})
                  pool (N.spec executable [executable, "--wait"]) ""
                release = mapM_ G.releaseGate [extra, held]
            (do
              ordinary <- start held
              G.awaitGate held
              try @O.OwnerError (start extra) >>= \case
                Left O.ResourceLimit -> pure ()
                Left other -> assertFailure ("unexpected admission failure: " <> show other)
                Right ticket -> O.abort ticket >> assertFailure "ordinary work consumed the inspection slot"
              bracket (atomically (B.acquireBytes budget B.Inspection O.retainedBytes))
                (atomically . B.releaseBytes) $ \_ -> do
                  observed <- O.submit B.Inspection O.defaultHooks pool inspect "" >>= O.await
                  observed.output @?= Lazy.toStrict expected
                  observed.errors @?= ""
                  observed.exit @?= Just (N.Exited 0)
                  observed.launchFailure @?= Nothing
                  atomically (B.usage budget) >>= (@?= B.Usage True 1 1 (O.childBytes + O.retainedBytes))
              release
              O.await ordinary >>= \result -> result.exit @?= Just (N.Exited 24)
              _ <- O.requestClose pool
              O.awaitCleanup pool
              atomically (B.usage budget) >>= (@?= B.Usage True 0 0 0)) `finally` release

    , testCase "inspection reaches tmux under shared child and payload saturation" $ do
        budget <- B.newBudget O.inspectionBytes
        forks <- newIORef (0 :: Int)
        let tracked :: O.Fork
            tracked action = do
              atomicModifyIORef' forks (\n -> (n + 1, ()))
              O.normalFork action
            gates 0 action = action []
            gates n action = G.withGate $ \gate -> gates (n - 1) (action . (gate :))
        (_, (executable, _)) <- getChild
        Fixture.withFixture $ \fixture ->
          withPoolIn budget fixture 16 tracked $ \first _ ->
            withPoolIn budget fixture 16 tracked $ \second pin ->
              gates (15 :: Int) $ \held -> do
                (code, expected, errors) <- Fixture.command fixture ["display-message", "-p", "#{pid}"]
                code @?= ExitSuccess
                errors @?= ""
                let tmux = Ascii.pack fixture.executable
                    inspect = N.spec tmux [tmux, "-N", "-S", pinPath pin, "display-message", "-p", "#{pid}"]
                    start pool gate = O.submit B.Ordinary (O.defaultHooks {O.launchNative = G.launch G.BeforeLaunch gate})
                      pool (N.spec executable [executable, "--wait"]) ""
                    release = mapM_ G.releaseGate held
                (do
                  tickets <- sequence [start pool gate | (pool, gate) <- zip (replicate 8 first <> replicate 7 second) held]
                  mapM_ G.awaitGate held
                  case tickets of
                    initial : _ -> withAsync (O.await initial) $ \waiter -> do
                      cancel waiter
                      waitCatch waiter >>= assertCancelled
                    [] -> assertFailure "no pending launch was created"
                  bracket (atomically (B.acquireBytes budget B.Ordinary 58720256))
                    (atomically . B.releaseBytes) $ \_ -> do
                      atomically (B.usage budget) >>= (@?= B.Usage True 2 15 125566976)
                      try @B.LimitError (O.submit B.Ordinary O.defaultHooks second inspect "") >>= \case
                        Left actual -> actual @?= B.Exhausted B.OrdinaryChildren 1 15 15
                        Right ticket -> O.abort ticket >> assertFailure "ordinary work reached protected capacity"
                      readIORef forks >>= (@?= 15)
                      bracket (atomically (B.acquireBytes budget B.Inspection O.retainedBytes))
                        (atomically . B.releaseBytes) $ \_ -> do
                          observed <- O.submit B.Inspection O.defaultHooks second inspect "" >>= O.await
                          observed.output @?= Lazy.toStrict expected
                          observed.errors @?= ""
                          observed.exit @?= Just (N.Exited 0)
                          observed.launchFailure @?= Nothing
                          readIORef forks >>= (@?= 16)
                          atomically (B.usage budget) >>= (@?= B.Usage True 2 15 129761280)
                      atomically (B.usage budget) >>= (@?= B.Usage True 2 15 125566976)
                  release
                  mapM_ (\ticket -> O.await ticket >>= \result -> result.exit @?= Just (N.Exited 24)) tickets
                  _ <- O.requestClose first
                  _ <- O.requestClose second
                  O.awaitCleanup first
                  O.awaitCleanup second
                  atomically (B.usage budget) >>= (@?= B.Usage True 0 0 0)) `finally` release

    , testCase "total shared bytes reject dispatch before allocating a worker" $ do
        budget <- B.newBudget O.inspectionBytes
        forks <- newIORef (0 :: Int)
        let tracked :: O.Fork
            tracked action = do
              atomicModifyIORef' forks (\n -> (n + 1, ()))
              O.normalFork action
        (_, (executable, _)) <- getChild
        Fixture.withFixture $ \fixture -> withPoolIn budget fixture 2 tracked $ \pool _ -> do
          let bytes = 128 * 1024 * 1024
              command = N.spec executable [executable, "--exit"]
          bracket (atomically (B.acquireBytes budget B.Inspection bytes)) (atomically . B.releaseBytes) $ \_ -> do
            try @B.LimitError (O.submit B.Ordinary O.defaultHooks pool command "") >>= \case
              Left (B.Exhausted B.PendingBytes requested used limit) ->
                (requested, used, limit) @?= (O.childBytes, bytes, bytes)
              _ -> assertFailure "byte exhaustion reached dispatch"
            readIORef forks >>= (@?= 0)
            atomically (B.usage budget) >>= (@?= B.Usage True 1 0 bytes)
          O.submit B.Ordinary O.defaultHooks pool command "" >>= O.await >>= \result ->
            result.exit @?= Just (N.Exited 23)
          atomically (B.usage budget) >>= (@?= B.Usage True 1 0 0)

    , testCase "failed pin cleanup retains a client lease until successful retry" $ do
        budget <- B.newBudget O.inspectionBytes
        Fixture.withFixture $ \fixture -> withPoolIn budget fixture 1 O.normalFork $ \pool pin -> do
          let path = pinPath pin
              sentinel = Bytes.take (Bytes.length path - 1) path <> "hold"
          bracket_ (Posix.createFile sentinel 0o600 >>= Posix.closeFd) (Files.removeLink sentinel) $ do
            _ <- O.requestClose pool
            try @PinError (O.awaitCleanup pool) >>= \case
              Left (SocketPinCleanupFailed _) -> pure ()
              _ -> assertFailure "pin cleanup unexpectedly succeeded"
            atomically (B.usage budget) >>= (@?= B.Usage True 1 0 0)
          _ <- O.requestClose pool
          O.awaitCleanup pool
          atomically (B.usage budget) >>= (@?= B.Usage True 0 0 0)
          _ <- O.requestClose pool
          atomically (B.usage budget) >>= (@?= B.Usage True 0 0 0)

    , testCase "pending cancellation after pool construction waits for caller registration" $ do
        budget <- B.newBudget O.inspectionBytes
        registered <- newIORef False
        Fixture.withFixture $ \fixture -> G.withGate $ \gate ->
          bracket newPinOwner closePin $ \owner -> do
            pin <- acquirePin owner (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
            let construct = mask $ \restore -> do
                  pool <- O.newPool budget O.normalFork owner 1
                  G.pauseConstructor gate
                  writeIORef registered True
                  restore (atomically retry) `finally` do
                    O.abortAll pool
                    _ <- O.requestClose pool
                    O.awaitCleanup pool
            withAsync construct $ \worker -> do
              G.awaitGate gate
              atomically (B.usage budget) >>= (@?= B.Usage True 1 0 0)
              withAsync (throwTo (asyncThreadId worker) AsyncCancelled) $ \sender -> do
                G.awaitPending (asyncThreadId sender) `finally` G.releaseGate gate
                wait sender
              waitCatch worker >>= assertCancelled
            readIORef registered >>= (@?= True)
            atomically (B.usage budget) >>= (@?= B.Usage True 0 0 0)
            Files.fileExist (pinPath pin) >>= (@?= False)

    , testCase "unawaited detached results leave only their consumer envelope charged" $ do
        budget <- B.newBudget O.inspectionBytes
        (_, (executable, _)) <- getChild
        Fixture.withFixture $ \fixture -> withPoolIn budget fixture 2 O.normalFork $ \pool _ -> do
          let envelope = 2 * 1024 * 1024
              payload = Bytes.pack (take 65536 (cycle [0..255]))
          bracket (atomically (B.acquireBytes budget B.Ordinary envelope)) (atomically . B.releaseBytes) $ \_ -> do
            ticket <- O.submit B.Ordinary O.defaultHooks pool (N.spec executable [executable, "--echo"]) payload
            atomically (O.activeCount pool >>= check . (== 0))
            atomically (B.usage budget) >>= (@?= B.Usage True 1 0 envelope)
            _ <- O.requestClose pool
            O.awaitCleanup pool
            atomically (B.usage budget) >>= (@?= B.Usage True 0 0 envelope)
            result <- O.await ticket
            result.exit @?= Just (N.Exited 0)
            result.output @?= payload
            result.errors @?= payload
          atomically (B.usage budget) >>= (@?= B.Usage True 0 0 0)

    , testCase "invalid input fails before worker allocation or native dispatch" $ do
        forks <- newIORef (0 :: Int)
        let tracked :: O.Fork
            tracked action = do
              atomicModifyIORef' forks (\n -> (n + 1, ()))
              O.normalFork action
        withPool getChild tracked $ \pool _ _ child -> do
          let valid = child ["--exit"]
              invalid = [valid {N.args = []}, valid {N.file = "relative"}, valid {N.cwd = "relative"},
                valid {N.args = ["a\0b"]}, valid {N.env = ["missing-equals"]},
                valid {N.env = ["=empty-name"]}, valid {N.args = repeat "x"},
                valid {N.env = replicate 4097 "A=B"}, valid {N.args = [Bytes.replicate 65536 120]}]
          mapM_ (\spec -> try @N.Failure (O.submit B.Ordinary O.defaultHooks pool spec "") >>= \case
            Left (N.InvalidInput _) -> pure ()
            _ -> assertFailure "invalid vectors reached dispatch") invalid
          try @O.OwnerError (O.submit B.Ordinary O.defaultHooks pool valid (Bytes.replicate 65537 120)) >>= \case
            Left O.ResourceLimit -> pure ()
            _ -> assertFailure "oversized stdin reached dispatch"
          readIORef forks >>= (@?= 0)
          atomically (O.activeCount pool) >>= (@?= 0)
          O.submit B.Ordinary O.defaultHooks pool valid "" >>= O.await >>= \result ->
            result.exit @?= Just (N.Exited 23)

    , testCase "exec refusal retains no child or descriptors" $
        withPool getChild O.normalFork $ \pool _ fixture _child -> do
          let missing = Ascii.pack fixture.directory <> "/missing-executable"
          ticket <- O.submit B.Ordinary O.defaultHooks pool (N.spec missing [missing]) ""
          result <- O.await ticket
          result.launchFailure @?= Just (N.LaunchRefused N.Execute 2)
          result.exit @?= Nothing
          result.output @?= ""
          result.errors @?= ""
          readIORef ticket.descriptors >>= assertBool "refusal retained descriptors" . Set.null
          atomically (O.activeCount pool) >>= (@?= 0)

    , testCase "external status consumption remains explicit lost-status data" $
        withPool getChild O.normalFork $ \pool _ _ child -> do
          let hooks = O.defaultHooks {O.waitNative = N.waitWith stolenWait}
          ticket <- O.submit B.Ordinary hooks pool (child ["--exit"]) ""
          first <- O.await ticket
          second <- O.await ticket
          first.exit @?= Just (N.StatusLost 10)
          second.exit @?= first.exit

    , testCase "output overflow retires its owned child before reporting failure" $
        withPool getChild O.normalFork $ \pool _ _ child -> do
          ticket <- O.submit B.Ordinary O.defaultHooks pool (child ["--flood"]) ""
          try @O.OwnerError (O.await ticket) >>= \case
            Left O.ResourceLimit -> pure ()
            _ -> assertFailure "oversized stdout was accepted"
          atomically (O.activeCount pool) >>= (@?= 0)
          atomically (readTVar ticket.exitCache) >>= assertBool "overflow lost reap obligation" . isJust
          readIORef ticket.descriptors >>= assertBool "overflow retained descriptors" . Set.null

    , testCase "owner failure after native return retires the child" $
        withPool getChild O.normalFork $ \pool pin _ child -> G.withGate $ \gate -> do
          let hooks = O.defaultHooks {O.afterStart = throwIO AsyncCancelled, O.launchNative = G.launch G.AfterLaunch gate}
          ticket <- O.submit B.Ordinary hooks pool
            (child ["--wait"]) ""
          G.awaitGate gate
          withAsync (O.await ticket) $ \waiter -> do
            cancel waiter
            waitCatch waiter >>= assertCancelled
          report <- O.requestClose pool
          assertIncomplete report
          Files.fileExist (pinPath pin) >>= assertBool "pin survives pending native return"
          G.releaseGate gate
          try @SomeException (O.await ticket) >>= assertCancelled
          atomically (readTVar ticket.exitCache) >>= assertBool "cleanup cached the actual exit" . isJust
          O.awaitCleanup pool
          Files.fileExist (pinPath pin) >>= (@?= False)

    , testCase "worker failure after consuming status preserves the exit cache" $
        withPool getChild O.normalFork $ \pool _ _ child -> G.withGate $ \gate -> do
          let hooks = O.defaultHooks {O.afterReap = throwIO AsyncCancelled, O.waitNative = G.consume gate}
          ticket <- O.submit B.Ordinary hooks pool (child ["--exit"]) ""
          G.awaitGate gate
          withAsync (O.await ticket) $ \waiter -> do
            cancel waiter
            waitCatch waiter >>= assertCancelled
          O.requestClose pool >>= assertIncomplete
          G.releaseGate gate
          try @SomeException (O.await ticket) >>= assertCancelled
          atomically (readTVar ticket.exitCache) >>= (@?= Just (N.Exited 23))
          -- A second waiter observes the retained worker failure, not ECHILD.
          try @SomeException (O.await ticket) >>= assertCancelled
          O.awaitCleanup pool

    , testCase "pending RTS interruption after native launch preserves ownership" $
        withPool getChild O.normalFork $ \pool pin _ child -> G.withGate $ \gate -> do
          -- Keep the journaled launch alive and stdin open for in-flight delivery.
          let hooks = O.defaultHooks {O.launchNative = G.launch G.AfterLaunch gate,
                O.afterStart = atomically retry}
          ticket <- O.submit B.Ordinary hooks pool (child ["--wait"]) ""
          G.awaitGate gate
          target <- atomically (G.gateThread gate)
          withAsync (throwTo target AsyncCancelled) $ \sender -> do
            (do G.awaitPending (asyncThreadId sender)
                O.requestClose pool >>= assertIncomplete
                Files.fileExist (pinPath pin) >>= assertBool "pending interruption retains the pin")
              `finally` G.releaseGate gate
            wait sender
          try @SomeException (O.await ticket) >>= assertCancelled
          atomically (readTVar ticket.exitCache) >>= (@?= Just (N.Signaled 9 False))
          O.awaitCleanup pool
          atomically (O.activeCount pool) >>= (@?= 0)
          Files.fileExist (pinPath pin) >>= (@?= False)

    , testCase "pending RTS interruption after consuming status preserves the cache" $
        withPool getChild O.normalFork $ \pool pin _ child -> G.withGate $ \gate -> do
          -- A sender can be blocked on an in-flight message to another capability.
          -- Keep the receiver alive after caching until that message is delivered.
          let hooks = O.defaultHooks {O.waitNative = G.consume gate, O.afterReap = atomically retry}
          ticket <- O.submit B.Ordinary hooks pool (child ["--exit"]) ""
          G.awaitGate gate
          target <- atomically (G.gateThread gate)
          withAsync (throwTo target AsyncCancelled) $ \sender -> do
            (do G.awaitPending (asyncThreadId sender)
                O.requestClose pool >>= assertIncomplete
                Files.fileExist (pinPath pin) >>= assertBool "consumed unpublished status retains the pin")
              `finally` G.releaseGate gate
            wait sender
          try @SomeException (O.await ticket) >>= assertCancelled
          atomically (readTVar ticket.exitCache) >>= (@?= Just (N.Exited 23))
          try @SomeException (O.await ticket) >>= assertCancelled
          O.awaitCleanup pool
          atomically (O.activeCount pool) >>= (@?= 0)
          Files.fileExist (pinPath pin) >>= (@?= False)

    , testCase "detaches retained launch fields and stdin from backing buffers" $
        withPool getChild O.normalFork $ \pool _ _ child -> do
          let slice bytes = Bytes.take (Bytes.length bytes) (Bytes.drop 1048576
                (Bytes.replicate 1048576 120 <> bytes <> Bytes.replicate 1048576 121))
              source = child ["--echo"]
              original = source {N.file = slice source.file, N.args = map slice source.args,
                N.env = map slice source.env, N.cwd = slice source.cwd}
              fields spec = spec.file : spec.cwd : spec.args <> spec.env
              hooks = O.defaultHooks {O.launchNative = \owned -> do
                fields owned @?= fields original
                let pairs = zip (fields original) (fields owned)
                mapM_ (\(before, after) -> do
                  before @?= after
                  let (old, oldOffset, _) = BytesInternal.toForeignPtr before
                      (new, newOffset, _) = BytesInternal.toForeignPtr after
                  withForeignPtr old $ \a -> withForeignPtr new $ \b ->
                    assertBool "launch field still shares its original slice"
                      (a `plusPtr` oldOffset /= b `plusPtr` newOffset)) pairs
                N.launch owned}
              backing = Bytes.pack (take 1048576 (cycle [0..255]))
              input = Bytes.take 65536 (Bytes.drop 17 backing)
              (storage, offset, _) = BytesInternal.toForeignPtr backing
          withForeignPtr storage $ \base ->
            bracket_ (watchInput (base `plusPtr` offset) (fromIntegral (Bytes.length backing)))
              (watchInput nullPtr 0) $ do
                result <- O.submit B.Ordinary hooks pool original input >>= O.await
                result.output @?= input
                result.errors @?= input
                result.exit @?= Just (N.Exited 0)
                sharedWrites >>= (@?= 0)

    , testCase "retains at most eight failed signals while the child remains owned" $
        withPool getChild O.normalFork $ \pool _ fixture child -> do
          let fifo = Ascii.pack fixture.directory <> "/signal-gate"
          Files.createNamedPipe fifo 0o600
          bracket (Posix.openFd fifo Posix.ReadWrite Posix.defaultFileFlags) Posix.closeFd $ \control -> do
            let hooks = O.defaultHooks {O.signalChild = \owned -> N.signalChild owned 9999}
            ticket <- O.submit B.Ordinary hooks pool (child ["--gate", fifo]) ""
            atomically $ O.progress ticket >>= \p -> check (p.outputBytes >= 1)
            replicateM_ 32 (O.stop ticket)
            retained <- atomically (readTVar ticket.signalErrors)
            atomically (readTVar ticket.signalErrorCount) >>= (@?= 32)
            atomically (writeTVar ticket.signalErrorCount (maxBound - 1))
            replicateM_ 2 (O.stop ticket)
            -- Release the live child before asserting, including in the red run.
            _ <- Posix.fdWrite control "x"
            O.await ticket >>= \result -> do
              result.exit @?= Just (N.Exited 0)
              result.signalFailureCount @?= maxBound
            length retained @?= 8

    , testCase "pidfd retirement waits for a signal already using the descriptor" $
        withPool getChild O.normalFork $ \pool _ fixture child -> do
          let fifo = Ascii.pack fixture.directory <> "/retire-gate"
          Files.createNamedPipe fifo 0o600
          bracket (Posix.openFd fifo Posix.ReadWrite Posix.defaultFileFlags) Posix.closeFd $ \control -> do
            entered <- newEmptyTMVarIO
            resume <- newEmptyTMVarIO
            let hooks = O.defaultHooks {O.signalChild = \owned -> do
                  atomically (putTMVar entered ())
                  atomically (readTMVar resume)
                  N.signalChild owned 0}
            ticket <- O.submit B.Ordinary hooks pool (child ["--gate", fifo]) ""
            atomically $ O.progress ticket >>= \p -> check (p.outputBytes >= 1)
            withAsync (O.stop ticket) $ \sender -> do
              early <- (do
                atomically (readTMVar entered)
                _ <- Posix.fdWrite control "x"
                atomically $ readTVar ticket.exitCache >>= check . isJust
                -- A bounded watchdog detects premature retirement while signaling
                -- is deliberately held. It does not schedule the race by sleeping.
                timeout 250000 (O.await ticket))
                `finally` atomically (putTMVar resume ())
              wait sender
              O.await ticket >>= \result -> result.exit @?= Just (N.Exited 0)
              assertBool "completion closed the pidfd during an active signal" (not (isJust early))

    , testCase "failed signaling retains the live child and pin" $
        withPool getChild O.normalFork $ \pool pin fixture child -> do
          let fifo = Ascii.pack fixture.directory <> "/gate"
          Files.createNamedPipe fifo 0o600
          bracket (Posix.openFd fifo Posix.ReadWrite Posix.defaultFileFlags)
            Posix.closeFd $ \control -> do
              let hooks = O.defaultHooks {O.signalChild = \owned -> N.signalChild owned 9999}
              ticket <- O.submit B.Ordinary hooks pool (child ["--gate", fifo]) ""
              atomically $ O.progress ticket >>= \p -> check (p.outputBytes >= 1)
              O.abort ticket
              atomically $ readTVar ticket.signalErrors >>= check . not . null
              O.requestClose pool >>= assertIncomplete
              Files.fileExist (pinPath pin) >>= assertBool "failed signal did not release pin"
              _ <- Posix.fdWrite control "x"
              try @SomeException (O.await ticket) >>= \case
                Left _ -> pure ()
                Right _ -> assertFailure "aborted job unexpectedly succeeded"
              atomically (readTVar ticket.exitCache) >>= (@?= Just (N.Exited 0))
              O.awaitCleanup pool

    , testCase "pending tmux launch retains its alias after waiter cancellation and close" $
        withPool getChild O.normalFork $ \pool pin fixture _child -> G.withGate $ \gate -> do
          (code, expected, errors) <- Fixture.command fixture ["display-message", "-p", "#{pid}"]
          unless (code == ExitSuccess) (assertFailure (show errors))
          let tmux = Ascii.pack fixture.executable
              launch = N.spec tmux [tmux, "-N", "-S", pinPath pin, "display-message", "-p", "#{pid}"]
              hooks = O.defaultHooks {O.launchNative = G.launch G.BeforeLaunch gate}
          ticket <- O.submit B.Ordinary hooks pool launch ""
          G.awaitGate gate
          withAsync (O.await ticket) $ \waiter -> do
            cancel waiter
            waitCatch waiter >>= assertCancelled
          O.requestClose pool >>= assertIncomplete
          atomically (O.activeCount pool) >>= (@?= 1)
          Files.fileExist (pinPath pin) >>= assertBool "alias retained for the admitted launch"
          try @O.OwnerError (O.submit B.Ordinary hooks pool launch "") >>= \case
            Left O.PoolClosed -> pure ()
            other -> assertFailure ("expected closed admission: " <> either show (const "ticket") other)
          G.releaseGate gate
          result <- O.await ticket
          result.output @?= Lazy.toStrict expected
          result.errors @?= ""
          result.exit @?= Just (N.Exited 0)
          result.launchFailure @?= Nothing
          O.awaitCleanup pool
          Files.fileExist (pinPath pin) >>= (@?= False)

    , testCase "preserves raw argv, environment and cwd and closes inherited descriptors" $
        withPool getChild O.normalFork $ \pool _ fixture child -> do
          let cwd = Ascii.pack fixture.directory <> "/cwd-\255"
              base = child []
              arguments = ["argv0-\255", "space tab\t newline\n", "#{format};'\92\34", "\254"]
              environment = ["LANG=C.UTF-8", "RAW=\255\t\n", "EMPTY="]
              input = Bytes.pack (take 1024 (cycle [0..255]))
              frame bytes = Builder.word32BE (fromIntegral (Bytes.length bytes)) <> Builder.byteString bytes
              vector values = Builder.word32BE (fromIntegral (length values)) <> foldMap frame values
              expected = Lazy.toStrict (Builder.toLazyByteString
                (vector arguments <> vector environment <> frame cwd <> Builder.word32BE 0)) <> input
          Directory.createDirectory cwd 0o700
          bracket highDescriptor N.close $ \sentinel -> do
            assertBool "high descriptor allocation failed" (sentinel >= 512 && sentinel < 1024)
            status <- Files.getFdStatus (Fd sentinel)
            assertBool "sentinel is not an open character device" (Files.isCharacterDevice status)
            result <- O.submit B.Ordinary O.defaultHooks pool
              (base {N.args = arguments, N.env = environment, N.cwd = cwd}) input >>= O.await
            result.launchFailure @?= Nothing
            result.exit @?= Just (N.Exited 0)
            result.output @?= expected
            result.errors @?= input

    , testCase "resumes socket input after observed EAGAIN and reader readiness" $
        withPool getChild O.normalFork $ \pool _ fixture child -> G.withGate $ \notice -> do
          published <- newEmptyTMVarIO
          let fifo = Ascii.pack fixture.directory <> "/input-gate"
              input = Bytes.pack (take 65536 (cycle [0..255]))
              hooks = O.defaultHooks {O.afterStart = do
                ticket <- atomically (readTMVar published)
                readIORef ticket.child >>= maybe (assertFailure "no owned child") (G.watchWriter notice)}
          Files.createNamedPipe fifo 0o600
          bracket (Posix.openFd fifo Posix.ReadWrite Posix.defaultFileFlags) Posix.closeFd $ \control ->
            (do
              ticket <- O.submit B.Ordinary hooks pool (child ["--gated-echo", fifo]) input
              atomically (putTMVar published ticket)
              observed <- timeout 250000 (G.awaitGate notice)
              assertBool "the production send must actually encounter EAGAIN" (isJust observed)
              atomically $ O.progress ticket >>= \p -> check (p.outputBytes >= 1)
              _ <- Posix.fdWrite control "x"
              result <- O.await ticket
              result.output @?= "R" <> input
              result.errors @?= input
              result.exit @?= Just (N.Exited 0)
              blockedWrites >>= assertBool "no EAGAIN recorded" . (> 0))
              `finally` G.stopWatchingWriter

    , testCase "drains stdout and stderr while sending bounded input" $
        withPool getChild O.normalFork $ \pool _ _ child -> do
          let bytes = Bytes.pack (take 65536 (cycle [0 .. 255]))
          ticket <- O.submit B.Ordinary O.defaultHooks pool (child ["--echo"]) bytes
          result <- O.await ticket
          result.output @?= bytes
          result.errors @?= bytes
          result.exit @?= Just (N.Exited 0)

    , testCase "preserves signaled status for repeated waiters" $
        withPool getChild O.normalFork $ \pool _ _ child -> do
          ticket <- O.submit B.Ordinary O.defaultHooks pool (child ["--signal"]) ""
          first <- O.await ticket
          second <- O.await ticket
          first.exit @?= Just (N.Signaled 15 False)
          second.exit @?= first.exit

    , testCase "failed worker creation rolls back admission" $ do
        first <- newIORef True
        let failOnce :: O.Fork
            failOnce action = atomicModifyIORef' first (\old -> (False, old)) >>= \case
              True -> throwIO (userError "injected fork allocation failure")
              False -> O.normalFork action
        withPool getChild failOnce $ \pool _ _ child -> do
          try @SomeException (O.submit B.Ordinary O.defaultHooks pool (child ["--exit"]) "") >>= \case
            Left _ -> pure ()
            Right _ -> assertFailure "worker creation unexpectedly succeeded"
          atomically (O.activeCount pool) >>= (@?= 0)
          atomically (B.usage pool.budget) >>= (@?= B.Usage True 1 0 0)
          ticket <- O.submit B.Ordinary O.defaultHooks pool (child ["--exit"]) ""
          O.await ticket >>= \result -> result.exit @?= Just (N.Exited 23)

    , testCase "retry fork failure leaves other cleanup debts resumable" $ do
        forks <- newIORef (0 :: Int)
        blocked <- newIORef True
        let failThird :: O.Fork
            failThird action = atomicModifyIORef' forks (\n -> (n + 1, n + 1)) >>= \case
              3 -> throwIO (userError "injected first retry fork failure")
              _ -> O.normalFork action
        withPoolAt getChild 2 failThird $ \pool _ _ child -> do
          let hooks = O.defaultHooks
                { O.afterStart = throwIO AsyncCancelled
                , O.signalChild = \owned -> atomicModifyIORef' blocked (\b -> (b,b)) >>= \case
                    True -> throwIO (userError "injected cleanup failure")
                    False -> N.signalChild owned 9
                }
          first <- O.submit B.Ordinary hooks pool (child ["--wait"]) ""
          second <- O.submit B.Ordinary hooks pool (child ["--wait"]) ""
          try @SomeException (O.await first) >>= assertCancelled
          try @SomeException (O.await second) >>= assertCancelled
          atomically (B.usage pool.budget) >>= (@?= B.Usage True 1 2 (2 * O.childBytes))
          let rescue = do
                -- Recover teardown if the injected fork failure leaves a claimed ticket.
                attempts <- readIORef forks
                when (attempts == 4) (atomically (writeTVar second.busy False))
                _ <- O.requestClose pool
                O.awaitCleanup pool
          (do
            _ <- atomicModifyIORef' blocked (\_ -> (False, ()))
            try @SomeException (O.requestClose pool) >>= \case
              Left _ -> pure ()
              Right _ -> assertFailure "retry fork unexpectedly succeeded"
            atomically (readTVar second.cleanupFailure) >>= \case
              Just problem -> assertBool "cleanup error is distinct from the worker cancellation"
                (isJust (fromException problem :: Maybe IOException))
              Nothing -> assertFailure "cleanup failure was discarded"
            completed <- timeout 250000 (O.requestClose pool >> O.awaitCleanup pool)
            assertBool "both owned debts must be recoverable after the failed fork" (isJust completed)
            atomically (O.activeCount pool) >>= (@?= 0)
            atomically (B.usage pool.budget) >>= (@?= B.Usage True 0 0 0)) `finally` rescue

    , testCase "partial stream startup retires the started reader before releasing ownership" $
        withPool getChild O.normalFork $ \pool _ fixture child -> do
          let fifo = Ascii.pack fixture.directory <> "/startup-gate"
          Files.createNamedPipe fifo 0o600
          bracket (Posix.openFd fifo Posix.ReadWrite Posix.defaultFileFlags)
            Posix.closeFd $ \_control -> do
              box <- newEmptyTMVarIO
              let hooks = O.defaultHooks {O.beforeSecondStream = do
                    ticket <- atomically (readTMVar box)
                    atomically $ O.progress ticket >>= \p -> check (p.outputBytes >= 1)
                    throwIO (userError "injected second stream startup failure")}
              ticket <- O.submit B.Ordinary hooks pool (child ["--gate", fifo]) ""
              atomically (putTMVar box ticket)
              try @SomeException (O.await ticket) >>= \case
                Left problem -> assertBool "startup failure remains an IOException"
                  (isJust (fromException problem :: Maybe IOException))
                Right _ -> assertFailure "stream startup unexpectedly succeeded"
              atomically (O.activeCount pool) >>= (@?= 0)
              atomically (readTVar ticket.exitCache) >>= assertBool "owned child was reaped" . isJust

    , testCase "socket stdin loads binary bytes through the pinned tmux endpoint" $
        withPool getChild O.normalFork $ \pool pin fixture _child -> do
          let tmux = Ascii.pack fixture.executable
              command args = N.spec tmux ([tmux, "-u", "-N", "-S", pinPath pin] <> args)
              payload = Bytes.pack (take 65536 (cycle [0..255]))
          loaded <- O.submit B.Ordinary O.defaultHooks pool
            (command ["load-buffer", "-b", "native-socket-bin", "-"]) payload >>= O.await
          loaded.launchFailure @?= Nothing
          loaded.exit @?= Just (N.Exited 0)
          loaded.output @?= ""
          loaded.errors @?= ""
          saved <- O.submit B.Ordinary O.defaultHooks pool
            (command ["save-buffer", "-b", "native-socket-bin", "-"]) "" >>= O.await
          saved.exit @?= Just (N.Exited 0)
          saved.output @?= payload
          saved.errors @?= ""

    , testCase "empty socket stdin delivers EOF without creating a buffer" $
        withPool getChild O.normalFork $ \pool pin fixture _child -> do
          let tmux = Ascii.pack fixture.executable
              command args = N.spec tmux ([tmux, "-u", "-N", "-S", pinPath pin] <> args)
          loaded <- O.submit B.Ordinary O.defaultHooks pool
            (command ["load-buffer", "-b", "native-socket-empty", "-"]) "" >>= O.await
          loaded.exit @?= Just (N.Exited 0)
          loaded.output @?= ""
          loaded.errors @?= ""
          listed <- O.submit B.Ordinary O.defaultHooks pool
            (command ["list-buffers", "-F", "#{buffer_name}"]) "" >>= O.await
          listed.exit @?= Just (N.Exited 0)
          assertBool "empty input created no named buffer"
            (not ("native-socket-empty" `Bytes.isInfixOf` listed.output))
    ]

buildChild :: IO (FilePath, (Bytes.ByteString, FilePath))
buildChild = mask $ \restore -> do
  directory <- mkdtemp "/tmp/libtmux-haskell-process-"
  let executable = directory <> "/child"
      policy = directory <> "/policy"
      common = ["-std=c11", "-Wall", "-Wextra", "-Werror", "-O2"]
      compile arguments = do
        (code, output, errors) <- readProcess (proc "cc" (common <> arguments))
        unless (code == ExitSuccess && Lazy.null output && Lazy.null errors) $
          assertFailure ("helper compilation failed: " <> show (code, output, errors))
  restore (do
    compile ["test-support/process-child.c", "-o", executable]
    compile ["-Icbits", "test-support/process-policy.c", "cbits/process.c", "-ldl", "-pthread",
      "-Wl,--wrap=dlsym", "-o", policy]
    pure (directory, (Ascii.pack executable, policy))) `onException` removePathForcibly directory

withPool :: IO (FilePath, (Bytes.ByteString, FilePath)) -> O.Fork
  -> (O.Pool -> SocketPin -> Fixture.Fixture -> ([Bytes.ByteString] -> N.Spec) -> IO a) -> IO a
withPool resource = withPoolAt resource 1

withPoolAt :: IO (FilePath, (Bytes.ByteString, FilePath)) -> Int -> O.Fork
  -> (O.Pool -> SocketPin -> Fixture.Fixture -> ([Bytes.ByteString] -> N.Spec) -> IO a) -> IO a
withPoolAt resource ordinaryCapacity forker action = do
  (_, (executable, _)) <- resource
  budget <- B.newBudget O.inspectionBytes
  Fixture.withFixture $ \fixture -> withPoolIn budget fixture (ordinaryCapacity + 1) forker $ \pool pin ->
    action pool pin fixture (\args -> N.spec executable (executable : args))

withPoolIn :: B.Budget -> Fixture.Fixture -> Int -> O.Fork -> (O.Pool -> SocketPin -> IO a) -> IO a
withPoolIn budget fixture capacity forker action = mask $ \restore -> do
  owner <- newPinOwner
  (pin, pool) <- (do
    pin <- acquirePin owner (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
    pool <- O.newPool budget forker owner capacity
    pure (pin, pool)) `onException` closePin owner
  restore (action pool pin) `finally` do
    O.abortAll pool
    _ <- O.requestClose pool
    O.awaitCleanup pool

assertCancelled :: Either SomeException a -> IO ()
assertCancelled (Left problem) = case fromException problem of
  Just AsyncCancelled -> pure ()
  Nothing -> assertFailure ("expected preserved AsyncCancelled: " <> show problem)
assertCancelled (Right _) = assertFailure "expected cancellation"

assertIncomplete :: O.CloseReport -> IO ()
assertIncomplete (O.CleanupIncomplete (_ : _)) = pure ()
assertIncomplete other = assertFailure ("expected retained cleanup: " <> show other)
