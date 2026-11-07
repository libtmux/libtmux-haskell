module SchedulerTest (tests) where

import Control.Concurrent.Async (AsyncCancelled (..), cancel, wait, waitCatch, withAsync)
import Control.Concurrent.STM (STM, atomically, newEmptyTMVarIO, orElse, putTMVar, takeTMVar)
import Control.Exception (ErrorCall, fromException, try)
import Control.Monad (replicateM, replicateM_)
import LibTmux.Internal.Scheduler qualified as S
import Test.Tasty (TestTree, localOption, mkTimeout, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests = localOption (mkTimeout 500000) $ testGroup "logical admission"
  [ testCase "ordinary admission preserves inspection capacity" $ do
      scheduler <- S.newScheduler
      _ <- atomically (replicateM 63 (S.admit scheduler S.Waiting))
      refused S.OrdinaryFull (S.admit scheduler S.Mutation)
      _ <- atomically (S.admit scheduler S.Inspection)
      refused S.AdmissionFull (S.admit scheduler S.Inspection)
  , testCase "a saturated waiting lane does not obstruct later inspection" $ do
      scheduler <- S.newScheduler
      waiting <- atomically (replicateM 5 (S.admit scheduler S.Waiting))
      inspection <- atomically (S.admit scheduler S.Inspection)
      atomically (S.status inspection) >>= (@?= S.Status S.Queued Nothing True)
      mapM_ (claimIs scheduler) (take 4 waiting)
      claimIs scheduler inspection
      atomically (S.status inspection) >>= (@?= S.Status S.Dispatching Nothing True)
      claimBlocked scheduler
  , testCase "ordinary reads preserve the fourth read permit for inspection" $ do
      scheduler <- S.newScheduler
      readOperations <- atomically (replicateM 4 (S.admit scheduler S.ScalarRead))
      inspection <- atomically (S.admit scheduler S.Inspection)
      mapM_ (claimIs scheduler) (take 3 readOperations)
      claimIs scheduler inspection
      claimBlocked scheduler
  , testCase "a second mutation waits while a different lane can dispatch" $ do
      scheduler <- S.newScheduler
      first <- atomically (S.admit scheduler S.Mutation)
      replicateM_ 2 (atomically (S.admit scheduler S.Mutation))
      readOperation <- atomically (S.admit scheduler S.ScalarRead)
      claimIs scheduler first
      claimIs scheduler readOperation
      claimBlocked scheduler
  , testCase "completion retires once and releases the mutation lane" $ do
      scheduler <- S.newScheduler
      first <- dispatch scheduler S.Mutation
      atomically (S.markResponseClosed scheduler first)
      atomically (S.finish scheduler first S.Success) >>= (@?= True)
      atomically (S.await first) >>= (@?= S.Succeeded)
      atomically (S.status first) >>= (@?= S.Status S.OperationComplete (Just S.Succeeded) False)
      atomically (S.finish scheduler first S.CommandFailure) >>= (@?= False)
      failed <- dispatch scheduler S.Mutation
      atomically (S.markResponseClosed scheduler failed)
      atomically (S.finish scheduler failed S.CommandFailure) >>= (@?= True)
      atomically (S.await failed) >>= (@?= S.Failed)
      atomically (S.await first) >>= (@?= S.Succeeded)
  , testCase "unknown work retains its lane and late proof preserves the published outcome" $ do
      scheduler <- S.newScheduler
      first <- dispatch scheduler S.Mutation
      next <- atomically (S.admit scheduler S.Mutation)
      atomically (S.markUnknown scheduler first) >>= (@?= True)
      atomically (S.markUnknown scheduler first) >>= (@?= False)
      atomically (S.cancelQueued scheduler first) >>= (@?= False)
      atomically (S.status first) >>= (@?= S.Status S.Dispatched (Just S.OutcomeUnknown) True)
      claimBlocked scheduler
      atomically (S.markResponseClosed scheduler first)
      atomically (S.finish scheduler first S.Success) >>= (@?= True)
      atomically (S.await first) >>= (@?= S.OutcomeUnknown)
      atomically (S.status first) >>= (@?= S.Status S.OperationComplete (Just S.OutcomeUnknown) False)
      claimIs scheduler next
  , testCase "deferred completion is forced before outcome publication and retirement" $ do
      scheduler <- S.newScheduler
      operation <- dispatch scheduler S.Mutation
      atomically (S.markResponseClosed scheduler operation)
      result <- try @ErrorCall (atomically (S.finish scheduler operation (error "deferred completion")))
      case result of
        Left _ -> pure ()
        Right _ -> assertFailure "published an unevaluated completion outcome"
      atomically (S.status operation) >>= (@?= S.Status S.ResponseClosed Nothing True)
      atomically (S.finish scheduler operation S.Success) >>= (@?= True)
      atomically (S.await operation) >>= (@?= S.Succeeded)
  , testCase "retiring a connection retains uncertain work until explicit detach" $ do
      scheduler <- S.newScheduler
      first <- dispatch scheduler S.Mutation
      next <- atomically (S.admit scheduler S.Mutation)
      atomically (S.connectionRetired scheduler first) >>= (@?= True)
      atomically (S.status first) >>= (@?= S.Status S.Dispatched (Just S.ConnectionRetired) True)
      claimBlocked scheduler
      atomically (S.detachResponsibility scheduler first) >>= (@?= True)
      atomically (S.detachResponsibility scheduler first) >>= (@?= False)
      atomically (S.status first) >>= (@?= S.Status S.Dispatched (Just S.ConnectionRetired) False)
      claimIs scheduler next
  , testCase "explicit detach cannot release work whose outcome is still certain" $ do
      scheduler <- S.newScheduler
      operation <- dispatch scheduler S.Mutation
      _ <- atomically (S.admit scheduler S.Mutation)
      atomically (S.detachResponsibility scheduler operation) >>= (@?= False)
      atomically (S.status operation) >>= (@?= S.Status S.Dispatched Nothing True)
      claimBlocked scheduler
  , testCase "retired admission is reusable while old metadata stays detached" $ do
      scheduler <- S.newScheduler
      original <- atomically (replicateM 63 (S.admit scheduler S.Waiting))
      inspection <- atomically (S.admit scheduler S.Inspection)
      atomically (mapM (S.cancelQueued scheduler) (inspection : original)) >>= (@?= replicate 64 True)
      _ <- atomically (replicateM 64 (S.admit scheduler S.Inspection))
      refused S.AdmissionFull (S.admit scheduler S.Inspection)
      atomically (S.status inspection) >>= (@?= S.Status S.Queued (Just S.NotDispatched) False)
  , testCase "late completion preserves ConnectionRetired" $ do
      scheduler <- S.newScheduler
      operation <- dispatch scheduler S.Waiting
      atomically (S.connectionRetired scheduler operation) >>= (@?= True)
      atomically (S.markResponseClosed scheduler operation)
      atomically (S.finish scheduler operation S.CommandFailure) >>= (@?= True)
      atomically (S.status operation) >>= (@?= S.Status S.OperationComplete (Just S.ConnectionRetired) False)
  , testCase "known pre-birth refusal retires uncertainty without rewriting it" $ do
      scheduler <- S.newScheduler
      operation <- atomically (S.admit scheduler S.Mutation)
      claimIs scheduler operation
      atomically (S.markUnknown scheduler operation) >>= (@?= True)
      atomically (S.refuseBeforeBirth scheduler operation) >>= (@?= True)
      atomically (S.status operation) >>= (@?= S.Status S.Dispatching (Just S.OutcomeUnknown) False)
      _ <- dispatch scheduler S.Mutation
      pure ()
  , testCase "only queued cancellation and proven refusal publish NotDispatched" $ do
      scheduler <- S.newScheduler
      queued <- atomically (S.admit scheduler S.Waiting)
      atomically (S.cancelQueued scheduler queued) >>= (@?= True)
      atomically (S.cancelQueued scheduler queued) >>= (@?= False)
      atomically (S.status queued) >>= (@?= S.Status S.Queued (Just S.NotDispatched) False)
      starting <- atomically (S.admit scheduler S.Waiting)
      claimIs scheduler starting
      atomically (S.refuseBeforeBirth scheduler starting) >>= (@?= True)
      atomically (S.status starting) >>= (@?= S.Status S.Dispatching (Just S.NotDispatched) False)
  , testCase "invalid phase jumps fail without changing ownership" $ do
      scheduler <- S.newScheduler
      operation <- atomically (S.admit scheduler S.Waiting)
      refused (S.InvalidTransition S.Dispatching S.Queued) (S.markDispatched scheduler operation)
      refused (S.InvalidTransition S.Dispatched S.Queued) (S.markResponseClosed scheduler operation)
      refused (S.InvalidTransition S.ResponseClosed S.Queued) (S.finish scheduler operation S.Success)
      refused (S.InvalidTransition S.Dispatching S.Queued) (S.markUnknown scheduler operation)
      atomically (S.status operation) >>= (@?= S.Status S.Queued Nothing True)
      claimIs scheduler operation
      refused (S.InvalidTransition S.Dispatched S.Dispatching) (S.markResponseClosed scheduler operation)
      atomically (S.status operation) >>= (@?= S.Status S.Dispatching Nothing True)
  , testCase "a foreign handle cannot resolve the same numeric key" $ do
      first <- S.newScheduler
      second <- S.newScheduler
      original <- atomically (S.admit first S.Waiting)
      other <- atomically (S.admit second S.Waiting)
      refused S.ForeignContext (S.markDispatched second original)
      refused S.ForeignContext (S.markResponseClosed second original)
      refused S.ForeignContext (S.finish second original S.Success)
      refused S.ForeignContext (S.markUnknown second original)
      refused S.ForeignContext (S.cancelQueued second original)
      refused S.ForeignContext (S.refuseBeforeBirth second original)
      refused S.ForeignContext (S.connectionRetired second original)
      refused S.ForeignContext (S.detachResponsibility second original)
      atomically (S.status original) >>= (@?= S.Status S.Queued Nothing True)
      atomically (S.status other) >>= (@?= S.Status S.Queued Nothing True)
      atomically (S.cancelQueued first original) >>= (@?= True)
      refused S.ForeignContext (S.cancelQueued second original)
  , testCase "close settles queued work and retains active debt" $ do
      scheduler <- S.newScheduler
      active <- dispatch scheduler S.Waiting
      queued <- atomically (S.admit scheduler S.Inspection)
      pending <- atomically (S.closeAdmission scheduler)
      assertBool "close lost active responsibility" (pending == [active])
      atomically (S.status queued) >>= (@?= S.Status S.Queued (Just S.NotDispatched) False)
      refused S.AdmissionClosed (S.admit scheduler S.Inspection)
      closed <- atomically (S.claim scheduler)
      assertBool "claim returned work after close" (closed == Nothing)
      atomically (S.closeAdmission scheduler) >>= (\again -> assertBool "repeated close lost debt" (again == [active]))
      atomically (S.markUnknown scheduler active) >>= (@?= True)
      atomically (S.detachResponsibility scheduler active) >>= (@?= True)
      atomically (S.closeAdmission scheduler) >>= (\remaining -> assertBool "retired debt remained" (null remaining))
  , testCase "a claimant retries while open and observes close despite active debt" $ do
      scheduler <- S.newScheduler
      _ <- dispatch scheduler S.Mutation
      claimBlocked scheduler
      retried <- newEmptyTMVarIO
      withAsync (do
          blocked <- atomically ((S.claim scheduler >> pure False) `orElse` pure True)
          atomically (putTMVar retried blocked)
          atomically (S.claim scheduler)) $ \worker -> do
        atomically (takeTMVar retried) >>= (@?= True)
        _ <- atomically (S.closeAdmission scheduler)
        result <- wait worker
        assertBool "claimant did not stop on close" (result == Nothing)
  , testCase "cancelling a pending outcome waiter does not release a waiting permit" $ do
      scheduler <- S.newScheduler
      operation <- dispatch scheduler S.Waiting
      mapM_ (const (dispatch scheduler S.Waiting)) [1 :: Int .. 3]
      _ <- atomically (S.admit scheduler S.Waiting)
      retried <- newEmptyTMVarIO
      withAsync (do
          blocked <- atomically ((S.await operation >> pure False) `orElse` pure True)
          atomically (putTMVar retried blocked)
          atomically (S.await operation)) $ \worker -> do
        atomically (takeTMVar retried) >>= (@?= True)
        cancel worker
        waitCatch worker >>= \case
          Left problem -> case fromException problem of
            Just AsyncCancelled -> pure ()
            Nothing -> assertFailure ("unexpected waiter exception: " <> show problem)
          Right _ -> assertFailure "pending waiter returned without an outcome"
      atomically (S.status operation) >>= (@?= S.Status S.Dispatched Nothing True)
      claimBlocked scheduler
      atomically (S.markUnknown scheduler operation) >>= (@?= True)
      atomically (S.detachResponsibility scheduler operation) >>= (@?= True)
      available <- atomically (S.claim scheduler)
      assertBool "explicit detach did not release the waiting permit" (available /= Nothing)
  ]

dispatch :: S.Scheduler -> S.Lane -> IO S.Operation
dispatch scheduler lane = do
  operation <- atomically (S.admit scheduler lane)
  claimIs scheduler operation
  atomically (S.markDispatched scheduler operation)
  pure operation

claimIs :: S.Scheduler -> S.Operation -> IO ()
claimIs scheduler expected = do
  actual <- atomically (S.claim scheduler `orElse` pure Nothing)
  assertBool "claim did not choose the oldest eligible operation" (actual == Just expected)

claimBlocked :: S.Scheduler -> IO ()
claimBlocked scheduler = do
  blocked <- atomically ((S.claim scheduler >> pure False) `orElse` pure True)
  assertBool "open dispatcher did not retry without an eligible operation" blocked

refused :: S.AdmissionError -> STM a -> IO ()
refused expected action = try @S.AdmissionError (atomically action) >>= \case
  Left actual | actual == expected -> pure ()
  Left actual -> assertFailure ("expected " <> show expected <> ", got " <> show actual)
  Right _ -> assertFailure ("admitted work despite " <> show expected)
