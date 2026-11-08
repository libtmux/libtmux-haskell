{-# LANGUAGE RankNTypes #-}
-- | Bounded ownership before, during and after endpoint adoption.
--
-- A t'Runtime' registers a fresh pin owner and its process pool before
-- adoption can create filesystem names. Failed or cancelled adoption leaves
-- cleanup owned here. 'inspect' retires only successfully cleaned entries;
-- 'awaitCleanup' may wait without a deadline. 'shutdown' bounds its two
-- observation phases while retaining incomplete cleanup. Logical dispatch
-- and operation deadlines remain separate, unfinished contracts.
module LibTmux.Internal.Runtime
  ( Runtime, Client, Report (..), newRuntime, adopt, adoptWith
  , clientPool, clientPin, usage, inspect, closeClient, requestClose, awaitCleanup, shutdown
  ) where

import Control.Concurrent.STM
import Control.Exception
import Control.Monad (forM, forM_, void, when)
import Data.ByteString (ByteString)
import Data.IntMap.Strict qualified as Map
import Data.Maybe (catMaybes)
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.SocketPin
import System.Timeout (timeout)

data Runtime = Runtime
  { budget :: !B.Budget, entries :: !(TVar (Map.IntMap Entry)), nextKey :: !(TVar Int)
  , forker :: P.Fork
  , shutdownRun :: !(TVar (Maybe (TMVar (Either SomeException ()))))
  }
data Entry = Entry {pool :: !P.Pool, closeFailure :: !(TVar (Maybe SomeException))}
data Client = Client !Entry !SocketPin
data Report = Report
  { accepting :: !Bool, pending :: ![(Int, P.CloseReport)]
  , closeFailures :: ![(Int, SomeException)]
  } deriving stock (Show)

newRuntime :: P.Fork -> IO Runtime
newRuntime forker = do
  budget <- B.newBudget P.inspectionBytes
  entries <- newTVarIO Map.empty
  nextKey <- newTVarIO 0
  shutdownRun <- newTVarIO Nothing
  pure Runtime {budget, entries, nextKey, forker, shutdownRun}

-- | Adopt one endpoint through a private socket pin. Reserve a client credit
-- before filesystem acquisition. Cancellation preserves its original exception
-- while the Runtime retains cleanup; use 'requestClose' and 'awaitCleanup'.
adopt :: Runtime -> ByteString -> ByteString -> IO Client
adopt = adoptWith (\_ _ -> pure ())

-- | Adoption with the socket pin's existing deterministic checkpoints.
adoptWith :: (PinCheckpoint -> ByteString -> IO ()) -> Runtime -> ByteString -> ByteString -> IO Client
adoptWith checkpoint runtime@Runtime {forker} source parent = mask $ \restore -> do
  owner <- newPinOwner
  entry <- atomically $ do
    _ <- inspect runtime
    key <- readTVar runtime.nextKey
    when (key == maxBound) (throwSTM P.ResourceLimit)
    pool <- P.newPoolSTM runtime.budget forker owner 16
    entry <- Entry pool <$> newTVar Nothing
    writeTVar runtime.nextKey (key + 1)
    modifyTVar' runtime.entries (Map.insert key entry)
    pure entry
  let abandon = void (try @SomeException (closeEntry entry))
  (do
    pin <- restore (acquirePinWith checkpoint owner source parent)
    atomically $ do
      current <- usage runtime
      closed <- readTVar entry.pool.closing
      when (not current.accepting || closed) (throwSTM P.PoolClosed)
    pure (Client entry pin)) `onException` abandon

clientPool :: Client -> P.Pool
clientPool (Client entry _) = entry.pool

clientPin :: Client -> SocketPin
clientPin (Client _ pin) = pin

usage :: Runtime -> STM B.Usage
usage runtime = B.usage runtime.budget

-- | Observe bounded cleanup debt, removing only entries whose pool reports
-- 'P.CleanupComplete'. Open and provisional clients count as pending ownership.
inspect :: Runtime -> STM Report
inspect runtime = do
  entries <- readTVar runtime.entries
  observed <- forM (Map.toList entries) $ \(key, entry) -> do
    status <- P.report entry.pool
    problem <- readTVar entry.closeFailure
    pure (key, entry, status, problem)
  let retained = [(key, entry, status, problem) |
        (key, entry, status, problem) <- observed, not (complete status)]
  writeTVar runtime.entries (Map.fromList [(key, entry) | (key, entry, _, _) <- retained])
  current <- usage runtime
  pure Report {accepting = current.accepting,
    pending = [(key, status) | (key, _, status, _) <- retained],
    closeFailures = catMaybes [fmap (key,) problem | (key, _, _, problem) <- retained]}
  where
    complete P.CleanupComplete = True
    complete _ = False

closeClient :: Client -> IO P.CloseReport
closeClient (Client entry _) = closeEntry entry >>= either throwIO pure

closeEntry :: Entry -> IO (Either SomeException P.CloseReport)
closeEntry entry = mask_ $ do
  outcome <- try @SomeException (P.requestClose entry.pool)
  case outcome of
    Left problem | Just (_ :: SomeAsyncException) <- fromException problem -> throwIO problem
    _ -> atomically (writeTVar entry.closeFailure (either Just (const Nothing) outcome))
  pure outcome

-- | Close admission and request cleanup for every registered owner. Ordinary
-- request failures remain in 'closeFailures'; caller cancellation propagates.
-- This starts no shutdown timer and does not terminate the tmux daemon.
requestClose :: Runtime -> IO Report
requestClose runtime = mask_ $ do
  entries <- atomically $ do
    B.closeAdmission runtime.budget
    Map.elems <$> readTVar runtime.entries
  forM_ entries (void . closeEntry)
  atomically (inspect runtime)

-- | Close admission and wait for every retained pool. A cleanup failure throws
-- without deleting its owner; repair the obstacle and retry. This wait has no
-- hard deadline and does not prove a daemon-side operation finished.
awaitCleanup :: Runtime -> IO ()
awaitCleanup runtime = do
  report <- requestClose runtime
  case report.closeFailures of
    (_, problem) : _ -> throwIO problem
    [] -> pure ()
  entries <- atomically (Map.elems <$> readTVar runtime.entries)
  forM_ entries (P.awaitCleanup . (.pool))
  void (atomically (inspect runtime))

-- | Close admission, allow 250 ms for graceful cleanup, request cancellation
-- of remaining command clients, then allow 250 ms for reaping. Each phase
-- finishes early when cleanup completes. Timeout retains owners and credits;
-- it neither proves a daemon-side outcome nor terminates the tmux daemon.
--
-- Concurrent callers join one Runtime-owned attempt. Cancelling a caller
-- leaves that attempt running. A later call can retry a finished attempt
-- with pending cleanup. Supervisor allocation failure throws without losing
-- its registered owners. Cleanup-request failures remain in 'closeFailures'.
shutdown :: Runtime -> IO Report
shutdown runtime@Runtime {forker} = mask $ \restore -> do
  (start, selected) <- atomically $ do
    B.closeAdmission runtime.budget
    previous <- readTVar runtime.shutdownRun
    running <- case previous of
      Nothing -> pure False
      Just run -> isEmptyTMVar run
    if running then pure (False, previous) else do
      report <- inspect runtime
      if null report.pending then pure (False, Nothing) else do
        run <- newEmptyTMVar
        writeTVar runtime.shutdownRun (Just run)
        pure (True, Just run)
  forM_ selected $ \run -> do
    when start $ do
      let failed (problem :: SomeException) = do
            atomically (putTMVar run (Left problem))
            throwIO problem
      void (forker (\unmask -> do
        result <- try @SomeException (unmask (shutdownPhases runtime))
        atomically (putTMVar run result))) `catch` failed
    restore (atomically (readTMVar run)) >>= either throwIO pure
  atomically (inspect runtime)

shutdownPhases :: Runtime -> IO ()
shutdownPhases runtime = do
  _ <- requestClose runtime
  graceful <- observe
  case graceful of
    Just () -> pure ()
    Nothing -> do
      entries <- atomically (Map.elems <$> readTVar runtime.entries)
      forM_ entries (P.abortAll . (.pool))
      _ <- requestClose runtime
      void observe
  where
    observe = timeout 250000 $ atomically $ do
      report <- inspect runtime
      check (null report.pending)
