module RuntimeReadTest (tests) where

import Control.Concurrent (myThreadId)
import Control.Concurrent.Async (AsyncCancelled (..), asyncThreadId, cancel, wait, waitCatch, withAsync)
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (forM, forM_, replicateM, void)
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.IORef
import Data.IntMap.Strict qualified as Map
import Data.Text.Encoding qualified as Utf8
import Fixture qualified
import GHC.Conc (BlockReason (BlockedOnSTM))
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.Scheduler qualified as S
import LibTmux.Version qualified as Version
import ProcessGate qualified as G
import System.Exit (ExitCode (..))
import System.IO.Error (ioeGetErrorString)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "owned Runtime reads"
  [ testCase "framed PID values survive close without retained worker journals" $ do
      (expected, detached) <- withRuntime P.normalFork $ \runtime client fixture -> do
        expected <- serverPid fixture
        immediate <- forM [R.ScalarRead, R.InspectionRead] $ \allocation -> do
          request <- start runtime client fixture allocation
          expectValue expected request
          pure request
        detached <- replicateM 8 (start runtime client fixture R.InspectionRead)
        forM_ detached $ \request ->
          atomically (R.readStatus request >>= check . not . (.retained))
        atomically (R.inspect runtime) >>= \report -> do
          length report.readWorkers @?= 0
          length report.unresolved @?= 0
        atomically (R.usage runtime) >>= (@?= B.Usage True 1 0 0)
        pure (expected, immediate <> detached)
      mapM_ (expectValue expected) detached
      forM_ detached $ \request ->
        atomically (R.readStatus request) >>= (@?= S.Status S.OperationComplete (Just S.Succeeded) False)

  , testCase "typed server versions survive close and share the owned read lifecycle" $ do
      (expected, detached) <- withRuntime P.normalFork $ \runtime client fixture -> do
        expected <- serverVersion fixture
        requests <- forM [R.ScalarRead, R.InspectionRead] $ \allocation -> do
          request <- R.readServerVersion runtime client (Bytes.pack fixture.executable) allocation
          expectValue expected request
          pure request
        atomically (R.inspect runtime) >>= \report -> do
          length report.readWorkers @?= 0
          length report.unresolved @?= 0
        atomically (R.usage runtime) >>= (@?= B.Usage True 1 0 0)
        pure (expected, requests)
      mapM_ (expectValue expected) detached
      forM_ detached $ \request ->
        atomically (R.readStatus request) >>= (@?= S.Status S.OperationComplete (Just S.Succeeded) False)

  , testCase "foreign clients and invalid deadlines refuse before reservation or fork" $
      withRuntime P.normalFork $ \runtime client fixture -> do
        forks <- newIORef (0 :: Int)
        let tracked :: P.Fork
            tracked action = modifyIORef' forks (+ 1) >> P.normalFork action
        bracket (R.newRuntime tracked) R.awaitCleanup $ \other -> do
          try @R.ReadError (start other client fixture R.InspectionRead) >>= \case
            Left R.ForeignClient -> pure ()
            _ -> assertFailure "foreign client crossed Runtime budgets"
          readIORef forks >>= (@?= 0)
          atomically (R.usage other) >>= (@?= B.Usage True 0 0 0)
        forM_ [0, -1, 10000001, maxBound] $ \duration ->
          try @R.ReadError (startWith P.defaultHooks duration runtime client fixture R.ScalarRead) >>= \case
            Left (R.InvalidReadDeadline actual) -> actual @?= duration
            _ -> assertFailure "invalid deadline entered the request registry"
        atomically (R.usage runtime) >>= (@?= B.Usage True 1 0 0)

  , testCase "cancelling an outcome waiter leaves the actual request owned" $
      withRuntime P.normalFork $ \runtime client fixture -> G.withGate $ \gate -> do
        expected <- serverPid fixture
        let hooks = P.defaultHooks {P.launchNative = G.launch G.BeforeLaunch gate}
        request <- startWith hooks 1000000 runtime client fixture R.InspectionRead
        G.awaitGate gate
        flip finally (G.releaseGate gate) $
          withAsync (R.awaitRead request) $ \waiter -> do
            cancel waiter
            waitCatch waiter >>= assertCancelled
            observed <- atomically (R.readStatus request)
            observed.outcome @?= Nothing
            observed.retained @?= True
            atomically (R.usage runtime) >>= (@?= B.Usage True 1 1 (P.childBytes + P.retainedBytes))
        expectValue expected request
        atomically (R.usage runtime) >>= (@?= B.Usage True 1 0 0)

  , testCase "queued expiry proves non-dispatch behind four claimed inspections" $
      withRuntime P.normalFork $ \runtime client fixture -> withGates 4 $ \gates -> do
        expected <- serverPid fixture
        requests <- forM gates $ \gate ->
          startWith (P.defaultHooks {P.launchNative = G.launch G.BeforeLaunch gate})
            1000000 runtime client fixture R.InspectionRead
        flip finally (mapM_ G.releaseGate gates) $ do
          mapM_ G.awaitGate gates
          cancelled <- R.readServerVersion runtime client (Bytes.pack fixture.executable) R.InspectionRead
          R.cancelRead runtime cancelled
          R.awaitRead cancelled >>= \case
            R.ReadUnavailable S.NotDispatched (Just problem) ->
              case fromException problem of
                Just R.ReadCancelled -> pure ()
                _ -> assertFailure "queued cancellation lost its cause"
            _ -> assertFailure "queued cancellation was not undispatched"
          atomically (R.inspect runtime >>= check . (== 4) . length . (.readWorkers))
          queued <- R.readServerVersionWith P.defaultHooks 50000 runtime client
            (Bytes.pack fixture.executable) R.InspectionRead
          expectUnavailable S.NotDispatched queued
          atomically (R.readStatus queued) >>= \status -> status.retained @?= False
          atomically (R.usage runtime) >>= (@?= B.Usage True 1 4 (4 * (P.childBytes + P.retainedBytes)))
          atomically (R.inspect runtime) >>= \report -> length report.readWorkers @?= 4
        mapM_ (expectValue expected) requests

  , testCase "active expiry retains physical credits and logical debt until explicit detach" $
      withRuntime P.normalFork $ \runtime client fixture -> G.withGate $ \gate -> do
        request <- startWith (P.defaultHooks
          { P.launchNative = G.launch G.BeforeLaunch gate
          , P.afterStart = throwIO (userError "post-birth checkpoint")
          })
          50000 runtime client fixture R.ScalarRead
        G.awaitGate gate
        flip finally (G.releaseGate gate) $ do
          expectUnavailable S.OutcomeUnknown request
          atomically (R.readStatus request) >>= \status -> status.retained @?= True
          atomically (R.usage runtime) >>= (@?= B.Usage True 1 1 (P.childBytes + P.retainedBytes))
          atomically (readTVar (R.clientPool client).jobs) >>= \jobs -> do
            Map.size jobs @?= 1
            forM_ (Map.elems jobs) $ \ticket -> atomically (readTVar ticket.cancelled) >>= (@?= True)
        waitWorkers runtime
        atomically (R.usage runtime) >>= (@?= B.Usage True 1 0 0)
        atomically (R.inspect runtime) >>= \report -> map fst report.unresolved @?= [R.readOperation request]
        atomically (R.detachOperation runtime (R.readOperation request)) >>= (@?= True)
        atomically (R.readStatus request) >>= \status -> do
          status.outcome @?= Just S.OutcomeUnknown
          status.retained @?= False
        expectUnavailable S.OutcomeUnknown request

  , testCase "late native refusal retires debt without replacing the expired outcome" $
      withRuntime P.normalFork $ \runtime client fixture -> G.withGate $ \gate -> do
        let hooks = P.defaultHooks
              { P.launchNative = G.launch G.BeforeLaunch gate
              , P.afterStart = throwIO (userError "after-refusal checkpoint")
              }
            absent = Bytes.pack (fixture.directory <> "/absent-tmux")
        request <- R.readServerPidWith hooks 50000 runtime client absent R.ScalarRead
        G.awaitGate gate
        flip finally (G.releaseGate gate) $ expectUnavailable S.OutcomeUnknown request
        waitWorkers runtime
        atomically (R.readStatus request) >>= \status -> do
          status.outcome @?= Just S.OutcomeUnknown
          status.retained @?= False
        atomically (R.usage runtime) >>= (@?= B.Usage True 1 0 0)
        expectUnavailable S.OutcomeUnknown request

  , testCase "supervisor and native-worker allocation failures refund proven non-dispatch" $
      forM_ [1, 2 :: Int] $ \refused -> do
        forks <- newIORef (0 :: Int)
        let fork :: P.Fork
            fork action = do
              number <- atomicModifyIORef' forks (\n -> (n + 1, n + 1))
              if number == refused then throwIO (userError "request worker allocation refused")
                else P.normalFork action
        withRuntime fork $ \runtime client fixture -> do
          attempted <- try @IOException (start runtime client fixture R.ScalarRead)
          case (refused, attempted) of
            (1, Left problem) -> ioeGetErrorString problem @?= "request worker allocation refused"
            (2, Right request) -> R.awaitRead request >>= \case
              R.ReadUnavailable S.NotDispatched (Just problem) ->
                case fromException problem of
                  Just io -> ioeGetErrorString io @?= "request worker allocation refused"
                  Nothing -> assertFailure "allocation exception was translated"
              _ -> assertFailure "native allocation refusal was not classified"
            _ -> assertFailure "wrong allocation failure boundary"
          waitWorkers runtime
          atomically (R.inspect runtime) >>= \report -> length report.unresolved @?= 0
          atomically (R.usage runtime) >>= (@?= B.Usage True 1 0 0)
          expected <- serverPid fixture
          start runtime client fixture R.InspectionRead >>= expectValue expected

  , testCase "pending cancellation at the accepted worker handoff cannot prove non-dispatch" $
      G.withGate $ \gate -> do
        forks <- newIORef (0 :: Int)
        let fork :: P.Fork
            fork action = do
              number <- atomicModifyIORef' forks (\n -> (n + 1, n + 1))
              thread <- P.normalFork action
              if number == 2 then G.pauseConstructor gate else pure ()
              pure thread
        withRuntime fork $ \runtime client fixture -> do
          request <- start runtime client fixture R.ScalarRead
          G.awaitGate gate
          target <- atomically (G.gateThread gate)
          withAsync (throwTo target AsyncCancelled) $ \sender -> do
            finally (G.awaitPending (asyncThreadId sender)) (G.releaseGate gate)
            wait sender
          expectUnavailable S.OutcomeUnknown request
          waitWorkers runtime
          atomically (R.usage runtime) >>= (@?= B.Usage True 1 0 0)
          atomically (R.readStatus request) >>= \status ->
            if status.retained then
              atomically (R.detachOperation runtime (R.readOperation request)) >>= (@?= True)
            else pure ()

  , testCase "interpreter recovery retains buffers and retries a refused cleanup worker" $ do
      interpreter <- newEmptyTMVarIO
      refuse <- newIORef False
      let fork :: P.Fork
          fork action = atomicModifyIORef' refuse (\old -> (False, old)) >>= \case
            True -> throwIO (userError "request recovery allocation refused")
            False -> P.normalFork $ \unmask -> do
              identity <- myThreadId
              atomically (void (tryPutTMVar interpreter identity))
              action unmask
      withRuntime fork $ \runtime client fixture -> G.withGate $ \gate -> do
        request <- startWith (P.defaultHooks {P.launchNative = G.launch G.BeforeLaunch gate})
          1000000 runtime client fixture R.ScalarRead
        worker <- atomically (readTMVar interpreter)
        G.awaitGate gate
        flip finally (writeIORef refuse False >> G.releaseGate gate) $ do
          throwTo worker AsyncCancelled
          R.awaitRead request >>= \case
            R.ReadUnavailable S.OutcomeUnknown (Just problem) ->
              case fromException problem of
                Just AsyncCancelled -> pure ()
                Nothing -> assertFailure "interpreter failure lost its original cancellation"
            _ -> assertFailure "interpreter failure did not publish uncertainty"
          withAsync (R.awaitCleanup runtime) $ \joiner -> do
            G.awaitBlocked (asyncThreadId joiner) BlockedOnSTM
            throwTo worker AsyncCancelled
            observed <- timeout 250000 (waitCatch joiner)
            case observed of
              Just (Left problem) -> case fromException problem of
                Just AsyncCancelled -> pure ()
                Nothing -> assertFailure "blocked join lost the recovery failure"
              _ -> assertFailure "recovery failure did not wake the blocked join"
          atomically $ do
            report <- R.inspect runtime
            check (any (maybe False (const True) . snd) report.readWorkers)
          atomically (R.usage runtime) >>= (@?= B.Usage False 1 1 (P.childBytes + P.retainedBytes))
          writeIORef refuse True
          failed <- timeout 250000 (try @IOException (R.awaitCleanup runtime))
          case failed of
            Just (Left problem) -> ioeGetErrorString problem @?= "request recovery allocation refused"
            _ -> assertFailure "known recovery allocation failure became an unbounded join"
          atomically (R.usage runtime) >>= (@?= B.Usage False 1 1 (P.childBytes + P.retainedBytes))
        R.awaitCleanup runtime
        atomically (R.usage runtime) >>= (@?= B.Usage False 0 0 0)
        atomically (R.readStatus request) >>= \status ->
          if status.retained then
            atomically (R.detachOperation runtime (R.readOperation request)) >>= (@?= True)
          else status.stage @?= S.OperationComplete

  , testCase "an inspection executes using protected physical and parent credits" $
      withRuntime P.normalFork $ \runtime client fixture -> do
        let budget = (R.clientPool client).budget
        expected <- serverPid fixture
        bracket (atomically (replicateM 15 (B.acquireChild budget B.Ordinary 0)))
          (atomically . mapM_ B.releaseChild) $ \_ ->
            bracket (atomically (B.acquireBytes budget B.Ordinary (128 * 1024 * 1024 - P.inspectionBytes)))
              (atomically . B.releaseBytes) $ \_ -> do
                try @B.LimitError (start runtime client fixture R.ScalarRead) >>= \case
                  Left _ -> pure ()
                  Right _ -> assertFailure "ordinary request consumed protected bytes"
                start runtime client fixture R.InspectionRead >>= expectValue expected
                atomically (R.usage runtime) >>= (@?= B.Usage True 1 15 (128 * 1024 * 1024 - P.inspectionBytes))
        atomically (R.usage runtime) >>= (@?= B.Usage True 1 0 0)

  , testCase "a successful child with contaminated framing is not a successful request" $
      withRuntime P.normalFork $ \runtime client fixture -> do
        Fixture.command fixture ["set-hook", "-g", "after-display-message", "display-message -p extra"] >>= (@?= (ExitSuccess, "", ""))
        request <- start runtime client fixture R.ScalarRead
        expectUnavailable S.OutcomeUnknown request
        waitWorkers runtime
        atomically (R.readStatus request) >>= \status -> status.retained @?= True
        atomically (R.usage runtime) >>= (@?= B.Usage True 1 0 0)
        atomically (R.detachOperation runtime (R.readOperation request)) >>= (@?= True)

  , testCase "close settles queued requests and preserves active grace and uncertainty" $
      withRuntime P.normalFork $ \runtime client fixture -> withGates 3 $ \gates -> do
        expected <- serverPid fixture
        requests <- forM (zip [0 :: Int ..] gates) $ \(index, gate) ->
          startWith (P.defaultHooks {P.launchNative = G.launch G.BeforeLaunch gate,
            P.afterStart = if index == 0 then throwIO (userError "post-grace checkpoint") else pure ()})
            1000000 runtime client fixture R.ScalarRead
        flip finally (mapM_ G.releaseGate gates) $ do
          mapM_ G.awaitGate gates
          queued <- start runtime client fixture R.ScalarRead
          withAsync (R.shutdown runtime) $ \closer -> do
            expectUnavailable S.NotDispatched queued
            case zip gates requests of
              (held, uncertain) : released -> do
                forM_ released $ \(gate, request) -> G.releaseGate gate >> expectValue expected request
                expectUnavailable S.OutcomeUnknown uncertain
                G.releaseGate held
                waitCatch closer >>= \case
                  Left problem -> assertFailure ("request shutdown failed: " <> show problem)
                  Right report -> do
                    length report.pending @?= 0
                    length report.readWorkers @?= 0
                    map fst report.unresolved @?= [R.readOperation uncertain]
                atomically (R.usage runtime) >>= (@?= B.Usage False 0 0 0)
                repeated <- timeout 250000 (R.shutdown runtime)
                case repeated of
                  Just report -> forM_ report.unresolved $ \(operation, _) ->
                    atomically (R.detachOperation runtime operation) >>= (@?= True)
                  Nothing -> assertFailure "logical uncertainty restarted physical phase waits"
              [] -> assertFailure "no held request"
  ]

withRuntime :: P.Fork -> (R.Runtime -> R.Client -> Fixture.Fixture -> IO a) -> IO a
withRuntime fork action = Fixture.withFixture $ \fixture ->
  bracket (R.newRuntime fork) R.awaitCleanup $ \runtime -> do
    client <- R.adopt runtime (Bytes.pack fixture.socket) (Bytes.pack fixture.directory)
    action runtime client fixture

start :: R.Runtime -> R.Client -> Fixture.Fixture -> R.ReadClass -> IO R.PidRead
start runtime client fixture = R.readServerPid runtime client (Bytes.pack fixture.executable)

startWith :: P.Hooks -> Int -> R.Runtime -> R.Client -> Fixture.Fixture -> R.ReadClass -> IO R.PidRead
startWith hooks duration runtime client fixture =
  R.readServerPidWith hooks duration runtime client (Bytes.pack fixture.executable)

serverPid :: Fixture.Fixture -> IO Integer
serverPid fixture = Fixture.command fixture ["display-message", "-p", "#{pid}"] >>= \case
  (ExitSuccess, output, "") -> case Lazy.readInteger output of
    Just (pid, "\n") | pid > 0 -> pure pid
    _ -> assertFailure "invalid independent PID receipt" >> pure 0
  other -> assertFailure ("independent PID receipt failed: " <> show other) >> pure 0

serverVersion :: Fixture.Fixture -> IO Version.TmuxVersion
serverVersion fixture = Fixture.command fixture ["-V"] >>= \case
  (ExitSuccess, output, "") -> do
    text <- either throwIO pure (Utf8.decodeUtf8' (Lazy.toStrict output))
    either (throwIO . userError . show) pure (Version.parseVersion text)
  other -> throwIO (userError ("independent version receipt failed: " <> show other))

expectValue :: (Eq value, Show value) => value -> R.Request value -> Assertion
expectValue expected request = R.awaitRead request >>= \case
  R.ReadValue actual -> actual @?= expected
  other -> assertFailure ("expected a verified value: " <> show other)

expectUnavailable :: Show value => S.Outcome -> R.Request value -> Assertion
expectUnavailable expected request = R.awaitRead request >>= \case
  R.ReadUnavailable actual _ -> actual @?= expected
  other -> assertFailure ("expected an unavailable request: " <> show other)

waitWorkers :: R.Runtime -> IO ()
waitWorkers runtime = atomically (R.inspect runtime >>= check . null . (.readWorkers))

withGates :: Int -> ([G.Gate] -> IO a) -> IO a
withGates 0 action = action []
withGates count action = G.withGate $ \gate -> withGates (count - 1) (action . (gate :))

assertCancelled :: Either SomeException a -> Assertion
assertCancelled (Left problem) = case fromException problem of
  Just AsyncCancelled -> pure ()
  Nothing -> assertFailure ("wrong waiter exception: " <> show problem)
assertCancelled (Right _) = assertFailure "cancelled waiter returned a value"
