{-# LANGUAGE RankNTypes #-}
-- | Bounded child ownership independent of callers awaiting a result.
--
-- A t'Pool' retains its socket pin, pending launches, descriptors, reap
-- obligations and shared "LibTmux.Internal.Budget" leases until cleanup finishes.
-- Closing admission does not cancel a native call or imply that an external
-- tmux command was reversed.
module LibTmux.Internal.Process where

import Control.Concurrent (ThreadId, forkIOWithUnmask)
import Control.Concurrent.Async (wait, waitEitherCatch, withAsync)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (forM_, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.IntMap.Strict qualified as Map
import Data.IntSet qualified as Set
import Data.Word (Word64)
import Control.DeepSeq (force)
import Data.IORef
import Foreign.C.Types (CInt)
import GHC.Conc (threadWaitRead)
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.SocketPin (PinOwner, closePin)
import LibTmux.Internal.Process.Native qualified as N
import System.Posix.Types (Fd (..))

type Fork = ((forall a. IO a -> IO a) -> IO ()) -> IO ThreadId

data OwnerError = PoolClosed | ResourceLimit | Aborted
  deriving stock (Eq, Show)
instance Exception OwnerError

data Hooks = Hooks
  { afterStart :: !(IO ()), afterReap :: !(IO ()), beforeSecondStream :: !(IO ())
  , signalChild :: !(N.Child -> IO CInt)
  , launchNative :: !(N.Spec -> IO N.Start), waitNative :: !(N.Child -> IO (Maybe N.Exit))
  }

data Pool = Pool
  { jobs :: !(TVar (Map.IntMap Ticket)), closing :: !(TVar Bool)
  , nextKey :: !(TVar Int), capacity :: !Int, forker :: Fork
  , budget :: !B.Budget, clientLease :: !B.ClientLease
  , pinOwner :: !PinOwner, pinBusy :: !(TVar Bool)
  , pinResult :: !(TMVar (Either SomeException ()))
  }

data Progress = Progress {outputBytes :: !Int, errorBytes :: !Int}
  deriving stock (Eq, Show)

data Ticket = Ticket
  { key :: !Int, result :: !(TMVar (Either SomeException Completion))
  , cancelled :: !(TVar Bool), exitCache :: !(TVar (Maybe N.Exit))
  , signalErrors :: !(TVar [CInt]), signalErrorCount :: !(TVar Word64), counts :: !(TVar Progress)
  , descriptors :: !(IORef Set.IntSet), child :: !(IORef (Maybe N.Child))
  , signalLock :: !(MVar ())
  , busy :: !(TVar Bool), failure :: !(TVar (Maybe SomeException))
  , cleanupFailure :: !(TVar (Maybe SomeException))
  , hooks :: !Hooks, lease :: !B.ChildLease
  }

data Completion = Completion
  { launchFailure :: !(Maybe N.Failure), output :: !ByteString, errors :: !ByteString
  , exit :: !(Maybe N.Exit), signalFailures :: ![CInt], signalFailureCount :: !Word64
  } deriving stock (Eq, Show)

data CloseReport
  = PoolOpen ![Int] | CleanupIncomplete ![Int]
  | CleanupComplete | PinCleanupFailed !SomeException
  deriving stock (Show)

normalFork :: Fork
normalFork = forkIOWithUnmask

forkIn :: Pool -> Fork
forkIn Pool {forker} = forker

defaultHooks :: Hooks
defaultHooks = Hooks (pure ()) (pure ()) (pure ()) (\child -> N.signalChild child 9) N.launch N.waitChild

newPool :: B.Budget -> Fork -> PinOwner -> Int -> IO Pool
-- The caller masks through cleanup registration; PinOwner transfers on success.
newPool budget forker pinOwner capacity = mask_ $
  atomically (newPoolSTM budget forker pinOwner capacity)

-- | Reserve the client and construct its owner in the caller's registration
-- transaction. Failed registration rolls back every credit and TVar.
newPoolSTM :: B.Budget -> Fork -> PinOwner -> Int -> STM Pool
newPoolSTM budget forker pinOwner capacity = do
  unless (capacity > 0 && capacity <= 16 && B.inspectionAllowance budget >= inspectionBytes)
    (throwSTM ResourceLimit)
  clientLease <- B.acquireClient budget
  jobs <- newTVar Map.empty
  closing <- newTVar False
  nextKey <- newTVar 0
  pinBusy <- newTVar False
  pinResult <- newEmptyTMVar
  pure Pool {jobs, closing, nextKey, capacity, forker, budget, clientLease, pinOwner, pinBusy, pinResult}

inputLimitBytes, streamLimitBytes :: Int
inputLimitBytes = 65536
streamLimitBytes = 1048576

-- Both stream chunk lists and concatenations coexist until forced publication.
childBytes :: Word64
childBytes = fromIntegral (4 * streamLimitBytes + inputLimitBytes
  + 2 * N.vectorLimitBytes + 4 * N.chunkBytes)

-- Allow both completed streams and equally bounded decoded copies. Consumers
-- must enforce those copy bounds or reserve a larger parent envelope.
retainedBytes, inspectionBytes :: Word64
retainedBytes = fromIntegral (4 * streamLimitBytes)
inspectionBytes = childBytes + retainedBytes

-- | Return a detached caller-owned t'Ticket'. Reserve shared child/byte credits
-- before copying or forking; allocation failure rolls back both credits.
-- Ordinary work leaves the pool's final position for inspection. A pool with
-- capacity one therefore admits inspections only; Runtime pools use sixteen.
-- Internal consumers precharge a separate parent envelope in
-- "LibTmux.Internal.Budget" for output retained after result publication.
submit :: B.Class -> Hooks -> Pool -> N.Spec -> ByteString -> IO Ticket
submit allocation hooks pool spec input = mask_ $ do
  N.validate spec
  when (Bytes.length input > inputLimitBytes) (throwIO ResourceLimit)
  ticket <- Ticket (-1) <$> newEmptyTMVarIO <*> newTVarIO False <*> newTVarIO Nothing
    <*> newTVarIO [] <*> newTVarIO 0 <*> newTVarIO (Progress 0 0) <*> newIORef Set.empty
    <*> newIORef Nothing <*> newMVar () <*> newTVarIO True
    <*> newTVarIO Nothing <*> newTVarIO Nothing <*> pure hooks
  registered <- atomically $ do
    closed <- readTVar pool.closing
    when closed (throwSTM PoolClosed)
    jobs <- readTVar pool.jobs
    let available = pool.capacity - if allocation == B.Ordinary then 1 else 0
    when (Map.size jobs >= available) (throwSTM ResourceLimit)
    key <- readTVar pool.nextKey
    when (key == maxBound) (throwSTM ResourceLimit)
    lease <- B.acquireChild pool.budget allocation childBytes
    let owned = (ticket lease) {key}
    writeTVar pool.nextKey (key + 1)
    writeTVar pool.jobs (Map.insert key owned jobs)
    pure owned
  (do
    ownedSpec <- N.copySpec spec
    ownedInput <- evaluate (force (Bytes.copy input))
    void (forkIn pool (\unmask -> worker unmask pool registered ownedSpec ownedInput)))
    `onException` do
      atomically $ do
        modifyTVar' pool.jobs (Map.delete registered.key)
        B.releaseChild registered.lease
      finishPin pool
  pure registered

worker :: (forall a. IO a -> IO a) -> Pool -> Ticket -> N.Spec -> ByteString -> IO ()
worker unmask pool ticket spec input = do
  outcome <- try @SomeException (unmask (runJob ticket spec input >>= evaluate))
  case outcome of
    Right completed -> finish pool ticket (Right completed)
    Left problem -> do
      atomically (writeTVar ticket.failure (Just problem))
      recover pool ticket problem

runJob :: Ticket -> N.Spec -> ByteString -> IO Completion
runJob ticket spec input = do
  start <- mask_ $ do
    native <- ticket.hooks.launchNative spec
    case native of
      N.Refused _ -> pure ()
      N.Owned child -> do
        writeIORef ticket.child (Just child)
        writeIORef ticket.descriptors (Set.fromList (filter (>= 0)
          (map fromIntegral [child.pidfd, child.input, child.output, child.errors])))
    pure native
  ticket.hooks.afterStart
  case start of
    N.Refused problem -> pure (Completion (Just problem) "" "" Nothing [] 0)
    N.Owned child -> do
      let guarded :: IO a -> IO a
          guarded action = action `catch` \(original :: SomeException) ->
            preservingFinally ticket.cleanupFailure (throwIO original) (stop ticket)
          collect = both (pure ())
            (both ticket.hooks.beforeSecondStream (guarded (readStream ticket True child.output))
              (guarded (readStream ticket False child.errors)))
            (both (pure ())
              (guarded (preservingFinally ticket.cleanupFailure
                (N.writeBytes (Fd child.input) input) (retire ticket child.input)))
              (guarded (reap ticket)))
          aborting = atomically (readTVar ticket.cancelled >>= check) >> stop ticket >> throwIO Aborted
      first aborting collect >>= \case
        Left _ -> throwIO Aborted
        Right ((output, errors), (_, _)) -> do
          retireAll ticket
          completion ticket Nothing output errors

-- Establish the first scope before attempting the second worker's creation.
both :: IO () -> IO a -> IO b -> IO (a,b)
both beforeRight left right = withAsync left $ \a -> do
  beforeRight
  withAsync right $ \b -> waitEitherCatch a b >>= \case
    Left (Left problem) -> throwIO problem
    Right (Left problem) -> throwIO problem
    Left (Right value) -> (value,) <$> wait b
    Right (Right value) -> (,value) <$> wait a

first :: IO a -> IO b -> IO (Either a b)
first left right = withAsync left $ \a -> withAsync right $ \b ->
  waitEitherCatch a b >>= \case
    Left value -> Left <$> either throwIO pure value
    Right value -> Right <$> either throwIO pure value

completion :: Ticket -> Maybe N.Failure -> ByteString -> ByteString -> IO Completion
completion ticket problem output errors = atomically $
  Completion problem output errors <$> readTVar ticket.exitCache <*> readTVar ticket.signalErrors <*> readTVar ticket.signalErrorCount

readStream :: Ticket -> Bool -> CInt -> IO ByteString
readStream ticket stdout fd = preservingFinally ticket.cleanupFailure (loop [] 0) (retire ticket fd)
  where
    loop chunks size = N.readChunk fd >>= \case
      Nothing -> threadWaitRead (Fd fd) >> loop chunks size
      Just bytes | Bytes.null bytes -> pure (Bytes.concat (reverse chunks))
      Just bytes -> do
        let total = size + Bytes.length bytes
        when (total > streamLimitBytes) (throwIO ResourceLimit)
        atomically $ modifyTVar' ticket.counts $ \old ->
          if stdout then old {outputBytes = total} else old {errorBytes = total}
        loop (bytes : chunks) total

-- | Keep an action failure primary and retain a simultaneous cleanup failure.
-- A cleanup failure on its own remains a thrown exception.
preservingFinally :: TVar (Maybe SomeException) -> IO a -> IO () -> IO a
preservingFinally journal action cleanupAction = mask $ \restore -> do
  primary <- try @SomeException (restore action)
  cleaned <- try @SomeException cleanupAction
  case cleaned of
    Left problem -> atomically (writeTVar journal (Just problem))
    Right () -> pure ()
  case primary of
    Left problem -> throwIO problem
    Right value -> either throwIO (const (pure value)) cleaned

-- | One masked consume/cache transition serves normal waiting and cleanup.
reap :: Ticket -> IO N.Exit
reap ticket = atomically (readTVar ticket.exitCache) >>= \case
  Just status -> pure status
  Nothing -> readIORef ticket.child >>= \case
    Nothing -> fail "reap without owned child"
    Just child -> do
      threadWaitRead (Fd child.pidfd)
      status <- mask_ $ do
        received <- ticket.hooks.waitNative child
        forM_ received $ \value -> atomically (writeTVar ticket.exitCache (Just value))
        pure received
      case status of
        Nothing -> reap ticket
        Just value -> ticket.hooks.afterReap >> pure value

stop :: Ticket -> IO ()
stop ticket = withMVar ticket.signalLock $ \_ -> mask_ $ do
  cached <- atomically (readTVar ticket.exitCache)
  readIORef ticket.child >>= \case
    Nothing -> pure ()
    Just child | cached == Nothing -> do
      owned <- Set.member (fromIntegral child.pidfd) <$> readIORef ticket.descriptors
      unless owned (fail "signaling an unowned child descriptor")
      rc <- ticket.hooks.signalChild child
      when (rc /= 0) $ atomically $ do
        modifyTVar' ticket.signalErrors (force . take 8 . (rc :))
        modifyTVar' ticket.signalErrorCount (\n -> if n == maxBound then n else n + 1)
    Just _ -> pure ()

-- | Close stream endpoints, terminate if still owned, then retain the reap.
cleanup :: Ticket -> IO ()
cleanup ticket = do
  stop ticket
  readIORef ticket.child >>= \case
    Nothing -> pure ()
    Just child -> do
      mapM_ (retire ticket) [child.input, child.output, child.errors]
      -- Recovery skips experiment hooks and gates; cached status is authoritative.
      let recovery = ticket {hooks = ticket.hooks {afterReap = pure (), waitNative = N.waitChild}}
      _ <- reap recovery
      pure ()
  retireAll ticket

retire :: Ticket -> CInt -> IO ()
retire ticket fd = when (fd >= 0) $ do
  ownedChild <- readIORef ticket.child
  let closeOwned = uninterruptibleMask_ $ do
        owned <- atomicModifyIORef' ticket.descriptors $ \fds ->
          (Set.delete (fromIntegral fd) fds, Set.member (fromIntegral fd) fds)
        when owned (N.close fd)
  -- Signaling borrows the pidfd integer; do not close it until that borrow ends.
  if maybe False (\child -> child.pidfd == fd) ownedChild
    then withMVar ticket.signalLock (const closeOwned)
    else closeOwned

retireAll :: Ticket -> IO ()
retireAll ticket = readIORef ticket.descriptors >>= mapM_ (retire ticket . fromIntegral) . Set.toList

recover :: Pool -> Ticket -> SomeException -> IO ()
recover pool ticket original = try @SomeException (cleanup ticket) >>= \case
  Right () -> finish pool ticket (Left original)
  Left cleanupProblem -> atomically $ do
    -- Keep the reservation and resources; requestClose can resume this cleanup.
    void (tryPutTMVar ticket.result (Left original))
    writeTVar ticket.cleanupFailure (Just cleanupProblem)
    writeTVar ticket.busy False

finish :: Pool -> Ticket -> Either SomeException Completion -> IO ()
finish pool ticket outcome = do
  remaining <- readIORef ticket.descriptors
  unless (Set.null remaining) (fail "retiring job with live descriptors")
  atomically $ do
    void (tryPutTMVar ticket.result outcome)
    modifyTVar' pool.jobs (Map.delete ticket.key)
    B.releaseChild ticket.lease
  finishPin pool

finishPin :: Pool -> IO ()
finishPin pool = mask_ $ do
  claimed <- atomically $ do
    ready <- (&&) <$> readTVar pool.closing <*> (Map.null <$> readTVar pool.jobs)
    busy <- readTVar pool.pinBusy
    previous <- tryReadTMVar pool.pinResult
    let finished = case previous of Just (Right ()) -> True; _ -> False
    if ready && not busy && not finished then do
      writeTVar pool.pinBusy True
      void (tryTakeTMVar pool.pinResult)
      pure True
    else pure False
  when claimed $ do
    let publish outcome = atomically $ do
          void (tryTakeTMVar pool.pinResult)
          putTMVar pool.pinResult outcome
          writeTVar pool.pinBusy False
          case outcome of
            Right () -> B.releaseClient pool.clientLease
            Left _ -> pure ()
    try @SomeException (forkIn pool (\_ -> try @SomeException (closePin pool.pinOwner) >>= publish)) >>= \case
      Left problem -> publish (Left problem)
      Right _ -> pure ()

-- | Stop admission and report pending work without waiting for native calls.
requestClose :: Pool -> IO CloseReport
requestClose pool = mask_ $ do
  debts <- atomically $ do
    writeTVar pool.closing True
    Map.elems <$> readTVar pool.jobs
  forM_ debts $ \ticket -> do
    claimed <- atomically $ do
      present <- Map.member ticket.key <$> readTVar pool.jobs
      running <- readTVar ticket.busy
      if present && not running then writeTVar ticket.busy True >> pure True else pure False
    when claimed $ do
      original <- atomically (readTVar ticket.failure)
      case original of
        Nothing -> atomically (writeTVar ticket.busy False)
        Just problem -> void (forkIn pool (\_ -> recover pool ticket problem))
          `onException` atomically (writeTVar ticket.busy False)
  finishPin pool
  atomically (report pool)

report :: Pool -> STM CloseReport
report pool = do
  closed <- readTVar pool.closing
  jobs <- Map.keys <$> readTVar pool.jobs
  if not closed then pure (PoolOpen jobs) else
    if not (null jobs) then pure (CleanupIncomplete jobs) else
      tryReadTMVar pool.pinResult >>= \case
        Nothing -> pure (CleanupIncomplete [])
        Just (Left problem) -> pure (PinCleanupFailed problem)
        Just (Right ()) -> pure CleanupComplete

awaitCleanup :: Pool -> IO ()
awaitCleanup pool = atomically (readTMVar pool.pinResult) >>= either throwIO pure

await :: Ticket -> IO Completion
await ticket = atomically (readTMVar ticket.result) >>= either throwIO pure

abort :: Ticket -> IO ()
abort ticket = atomically (writeTVar ticket.cancelled True)

abortAll :: Pool -> IO ()
abortAll pool = atomically $ readTVar pool.jobs >>= mapM_ (\ticket -> writeTVar ticket.cancelled True) . Map.elems

activeCount :: Pool -> STM Int
activeCount pool = Map.size <$> readTVar pool.jobs

progress :: Ticket -> STM Progress
progress ticket = readTVar ticket.counts
