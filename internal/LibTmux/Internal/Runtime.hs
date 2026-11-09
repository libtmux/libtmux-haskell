{-# LANGUAGE RankNTypes #-}
-- | Bounded ownership before, during and after endpoint adoption.
--
-- A t'Runtime' registers a fresh pin owner and its process pool before
-- adoption can create filesystem names. Failed or cancelled adoption leaves
-- cleanup owned here. 'inspect' retires only successfully cleaned entries;
-- 'awaitCleanup' may wait without a deadline. 'shutdown' bounds its two
-- observation phases while retaining incomplete cleanup. Typed framed server
-- reads bind logical admission and deadlines to native ownership. The common
-- Server scope is public; shared scopes and other command bindings remain open.
module LibTmux.Internal.Runtime
  ( Runtime, ServerHandle, Report (..), newRuntime, adopt, adoptWith
  , serverPool, serverPin, usage, inspect, closeServerHandle, requestClose, awaitCleanup, shutdown
  , Request, PidRead, VersionRead, ReadClass (..), ReadResult (..), ReadError (..)
  , readServerPid, readServerPidWith, awaitRead, readStatus, readOperation
  , readServerVersion, readServerVersionWith
  , EntityField (..), readTopologyWith, readEntityFieldWith, readGraphWith, readSnapshotWith, withCaptureBudget
  , ReadReceipt, ReadRecovery (..), readReceipt, receiptGeneration, receiptOperation, inspectReceipt, resumeReceipt
  , cancelReceipt, detachReceipt
  , cancelRead, detachOperation
  ) where

import Control.Concurrent.STM
import Control.DeepSeq (force)
import Control.Exception
import Control.Exception.Annotation (ExceptionAnnotation)
import Control.Exception.Context qualified as Context
import Control.Monad (forM, forM_, unless, void, when)
import Data.Bits ((.&.), shiftR)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.IntMap.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text.Encoding qualified as Utf8
import Data.Unique (Unique, newUnique)
import Data.Word (Word64)
import Foreign.C.Types (CInt)
import GHC.Clock (getMonotonicTimeNSec)
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.Entropy qualified as Entropy
import LibTmux.Internal.Frame qualified as F
import LibTmux.Internal.Field qualified as Field
import LibTmux.Internal.Graph qualified as Graph
import LibTmux.Internal.Record qualified as Record
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Native qualified as N
import LibTmux.Internal.Scheduler qualified as S
import LibTmux.Internal.SocketPin
import LibTmux.Internal.Topology qualified as Topology
import LibTmux.Id qualified as Id
import LibTmux.Version qualified as Version
import System.Timeout (timeout)

data Runtime = Runtime
  { identity :: !Unique
  , budget :: !B.Budget, entries :: !(TVar (Map.IntMap Entry)), nextKey :: !(TVar Int)
  , forker :: P.Fork
  , shutdownRun :: !(TVar (Maybe (TMVar (Either SomeException ()))))
  , scheduler :: !S.Scheduler, reads :: !(TVar [ReadOwner])
  }
data Entry = Entry {pool :: !P.Pool, closeFailure :: !(TVar (Maybe SomeException))}
data ServerHandle = ServerHandle !Entry !SocketPin

-- | Physical cleanup, owned read workers and logical uncertainty are separate.
-- An empty 'pending' list alone does not establish complete Runtime cleanup.
data Report = Report
  { accepting :: !Bool, pending :: ![(Int, P.CloseReport)]
  , closeFailures :: ![(Int, SomeException)]
  , unresolved :: ![(S.Operation, S.Status)]
  , readWorkers :: ![(S.Operation, Maybe SomeException)]
  } deriving stock (Show)

-- | Inspection can use protected read, child and parent-byte capacity.
data ReadClass = InspectionRead | ScalarRead
  deriving stock (Eq, Show)

-- | A typed observation handle with no reference to its t'Runtime', t'ServerHandle',
-- native ticket or input buffers. 'awaitRead' also works after cleanup.
data Request value = Request !ReadReceipt !(TMVar (ReadResult value))

-- | Correlation metadata only: no Runtime, pool, ticket or result payload.
-- The native key remains useful after its decoder owner has retired.
data ReadReceipt = ReadReceipt !Unique !Graph.Generation !S.Operation !(TVar (Maybe Int))
  deriving stock (Eq)
instance Show ReadReceipt where
  showsPrec precedence (ReadReceipt _ _ operation _) =
    showParen (precedence > 10) (showString "ReadReceipt " . shows operation)
instance ExceptionAnnotation ReadReceipt

-- | Logical responsibility and this read's physical owners, observed together.
-- A released native child does not establish a daemon-side command outcome.
data ReadRecovery = ReadRecovery
  { logical :: !S.Status -- ^ Logical progress, original result and retained responsibility.
  , workerOwned :: !Bool -- ^ A decoder or recovery worker still owns this read.
  , workerFailure :: !(Maybe SomeException) -- ^ Retained decoder or recovery failure.
  , nativeOwned :: !Bool -- ^ A native child or its cleanup remains owned.
  , nativeFailure :: !(Maybe SomeException) -- ^ Retained native cleanup failure.
  } deriving stock (Show)
-- | A checked positive server PID, observed by 'readServerPid'.
type PidRead = Request Integer
-- | A stable release identity, observed by 'readServerVersion'.
type VersionRead = Request Version.TmuxVersion

data ReadResult value = ReadValue !value | ReadUnavailable !S.Outcome !(Maybe SomeException)
  deriving stock (Show)

-- Pair each fixed wire format with its decoded result type.
data ReadCommand value where
  ReadPid :: ReadCommand Integer
  ReadVersion :: ReadCommand Version.TmuxVersion
  ReadTopology :: ReadCommand ByteString
  ReadEntityField :: !EntityField -> ReadCommand ByteString
  ReadGraph :: !Graph.Generation -> ReadCommand Graph.EntityGraph
  ReadSnapshot :: !Graph.Generation -> ReadCommand Graph.Snapshot

-- | Closed scalar acquisition targets; callers cannot supply format fragments.
data EntityField
  = SessionName !Id.SessionId | WindowName !Id.WindowId
  | PaneTitle !Id.PaneId | PaneCommand !Id.PaneId | PanePath !Id.PaneId
  deriving stock (Eq, Show)

data ReadError
  = ForeignServer | InvalidReadDeadline !Int | ReadClockOverflow
  | ReadExpired | ReadCancelled | ReadClosing
  | InvalidReadFrame !F.FrameError | InvalidServerPid
  | InvalidRecordFrame !Record.RecordError
  | InvalidVersionEncoding | InvalidServerVersion !Version.VersionError
  | InvalidEntityReceipt
  | ReadExit !(Maybe N.Exit) | ReadStderr !Int
  deriving stock (Eq, Show)
instance Exception ReadError

data Submission = NotSubmitted | Registering !P.Ticket | Submitted !P.Ticket | SubmissionRefused
-- Retain the result's type witness until its worker releases ownership.
data ReadOwner where
  ReadOwner ::
    { operation :: !S.Operation
    , receipt :: !ReadReceipt
    , command :: !(ReadCommand value), result :: !(TMVar (ReadResult value))
    , nonce :: !F.Nonce, deadline :: !Word64
    , envelope :: !B.ByteLease, submission :: !(TVar Submission)
    , cancelled :: !(TVar Bool), busy :: !(TVar Bool)
    , failure :: !(TVar (Maybe SomeException))
    } -> ReadOwner

newRuntime :: P.Fork -> IO Runtime
newRuntime forker = do
  identity <- newUnique
  budget <- B.newBudget P.inspectionBytes
  entries <- newTVarIO Map.empty
  nextKey <- newTVarIO 0
  shutdownRun <- newTVarIO Nothing
  scheduler <- S.newScheduler
  readOwners <- newTVarIO []
  pure Runtime {identity, budget, entries, nextKey, forker, shutdownRun, scheduler, reads = readOwners}

-- | Adopt one endpoint through a private socket pin. Reserve a client credit
-- before filesystem acquisition. Cancellation preserves its original exception
-- while the Runtime retains cleanup; use 'requestClose' and 'awaitCleanup'.
adopt :: Runtime -> ByteString -> ByteString -> IO ServerHandle
adopt = adoptWith (\_ _ -> pure ())

-- | Adoption with the socket pin's existing deterministic checkpoints.
adoptWith :: (PinCheckpoint -> ByteString -> IO ()) -> Runtime -> ByteString -> ByteString -> IO ServerHandle
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
    pure (ServerHandle entry pin)) `onException` abandon

serverPool :: ServerHandle -> P.Pool
serverPool (ServerHandle entry _) = entry.pool

serverPin :: ServerHandle -> SocketPin
serverPin (ServerHandle _ pin) = pin

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
  unresolved <- S.outstanding runtime.scheduler
  owners <- readTVar runtime.reads
  readWorkers <- forM owners $ \owner ->
    (owner.operation,) <$> readTVar owner.failure
  pure Report {accepting = current.accepting,
    pending = [(key, status) | (key, _, status, _) <- retained],
    closeFailures = catMaybes [fmap (key,) problem | (key, _, _, problem) <- retained],
    unresolved, readWorkers}
  where
    complete P.CleanupComplete = True
    complete _ = False

closeServerHandle :: ServerHandle -> IO P.CloseReport
closeServerHandle (ServerHandle entry _) = closeEntry entry >>= either throwIO pure

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
    _ <- S.closeAdmission runtime.scheduler
    owners <- readTVar runtime.reads
    forM_ owners $ \owner -> do
      state <- S.status owner.operation
      when (state.outcome == Just S.NotDispatched) $
        publishUnavailable owner (toException ReadClosing)
    Map.elems <$> readTVar runtime.entries
  forM_ entries (void . closeEntry)
  atomically (readTVar runtime.reads) >>= mapM_ (resumeRead runtime)
  atomically (inspect runtime)

-- | Close admission and wait for every retained pool. A cleanup failure throws
-- without deleting its owner; repair the obstacle and retry. This wait has no
-- hard deadline. It joins read workers but does not await uncertain logical
-- outcomes; inspect 'unresolved' afterward rather than inferring job completion.
awaitCleanup :: Runtime -> IO ()
awaitCleanup runtime = do
  report <- requestClose runtime
  case report.closeFailures of
    (_, problem) : _ -> throwIO problem
    [] -> pure ()
  atomically $ do
    owners <- readTVar runtime.reads
    -- Failure publication must wake this join even if membership is unchanged.
    forM_ owners $ \owner -> readTVar owner.failure >>= mapM_ throwSTM
    check (null owners)
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
      if null report.pending && null report.readWorkers then pure (False, Nothing) else do
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
      atomically (readTVar runtime.reads) >>= mapM_ (cancelOwner runtime ReadClosing)
      entries <- atomically (Map.elems <$> readTVar runtime.entries)
      forM_ entries (P.abortAll . (.pool))
      _ <- requestClose runtime
      void observe
  where
    observe = timeout 250000 $ atomically $ do
      report <- inspect runtime
      check (null report.pending && null report.readWorkers)

readOperation :: Request value -> S.Operation
readOperation (Request (ReadReceipt _ _ operation _) _) = operation

readReceipt :: Request value -> ReadReceipt
readReceipt (Request receipt _) = receipt

receiptGeneration :: ReadReceipt -> Graph.Generation
receiptGeneration (ReadReceipt _ generation _ _) = generation

receiptOperation :: ReadReceipt -> S.Operation
receiptOperation (ReadReceipt _ _ operation _) = operation

validateReceipt :: Runtime -> ServerHandle -> ReadReceipt -> STM ()
validateReceipt runtime client (ReadReceipt identity generation _ _) =
  unless (identity == runtime.identity && (serverPool client).budget == runtime.budget
    && generation == pinGeneration (serverPin client)) (throwSTM ForeignServer)

-- | Inspect only the originating operation, even after its decoder retires.
-- Another handle to the same endpoint cannot inspect or detach this receipt.
inspectReceipt :: Runtime -> ServerHandle -> ReadReceipt -> STM ReadRecovery
inspectReceipt runtime client receipt@(ReadReceipt _ _ operation key) = do
  validateReceipt runtime client receipt
  logical <- S.status operation
  owners <- readTVar runtime.reads
  let matching = filter ((== operation) . (.operation)) owners
  workerFailure <- case matching of
    owner : _ -> readTVar owner.failure
    [] -> pure Nothing
  selected <- readTVar key
  jobs <- readTVar (serverPool client).jobs
  let ticket = selected >>= (`Map.lookup` jobs)
  nativeFailure <- maybe (pure Nothing) (readTVar . (.cleanupFailure)) ticket
  pure ReadRecovery {logical, workerOwned = not (null matching), workerFailure,
    nativeOwned = maybe False (const True) ticket, nativeFailure}

-- | Retry existing cleanup and decoder ownership without redispatching tmux.
-- This leaves admission open. Allocation failure retains the original owners.
resumeReceipt :: Runtime -> ServerHandle -> ReadReceipt -> IO ()
resumeReceipt runtime client receipt@(ReadReceipt _ _ operation key) = mask_ $ do
  (ticket, owners) <- atomically $ do
    validateReceipt runtime client receipt
    selected <- readTVar key
    jobs <- readTVar (serverPool client).jobs
    owners <- filter ((== operation) . (.operation)) <$> readTVar runtime.reads
    pure (selected >>= (`Map.lookup` jobs), owners)
  mapM_ (P.resumeCleanup (serverPool client)) ticket
  mapM_ (resumeRead runtime) owners
  observed <- atomically (inspectReceipt runtime client receipt)
  mapM_ throwIO observed.workerFailure

-- | Request cancellation of the correlated read, retaining unresolved debt.
cancelReceipt :: Runtime -> ServerHandle -> ReadReceipt -> IO ()
cancelReceipt runtime client receipt@(ReadReceipt _ _ operation _) = atomically $ do
  validateReceipt runtime client receipt
  cancelOperation runtime operation

-- | Relinquish only this receipt's logical responsibility. Native cleanup and
-- decoder ownership remain registered until their own completion.
detachReceipt :: Runtime -> ServerHandle -> ReadReceipt -> STM Bool
detachReceipt runtime client receipt@(ReadReceipt _ _ operation _) = do
  validateReceipt runtime client receipt
  detachOperation runtime operation

readStatus :: Request value -> STM S.Status
readStatus = S.status . readOperation

-- | Wait only for this read's first result. Caller cancellation changes no
-- ownership. Use 'cancelRead' to request cancellation of the owned operation.
awaitRead :: Request value -> IO (ReadResult value)
awaitRead (Request _ result) = atomically (readTMVar result)

-- | Acquire a fresh, nonce-framed PID using a one-second deadline. This fixed
-- read is the first private logical/physical binding, not a raw command API.
readServerPid :: Runtime -> ServerHandle -> ByteString -> ReadClass -> IO PidRead
readServerPid = readServerPidWith P.defaultHooks 1000000

-- | Use existing process checkpoints and a checked 1..10000000 microsecond
-- deadline. The same expiration governs queueing, submission and validation.
readServerPidWith :: P.Hooks -> Int -> Runtime -> ServerHandle -> ByteString -> ReadClass -> IO PidRead
readServerPidWith = startRead ReadPid

-- | Observe a stable release identity through the pinned server. Use
-- 'Version.requireSupported' separately for minimum-version admission;
-- this observation establishes no feature capabilities.
readServerVersion :: Runtime -> ServerHandle -> ByteString -> ReadClass -> IO VersionRead
readServerVersion = readServerVersionWith P.defaultHooks 1000000

-- | The same owned deadline and checkpoints as 'readServerPidWith'.
readServerVersionWith :: P.Hooks -> Int -> Runtime -> ServerHandle -> ByteString -> ReadClass -> IO VersionRead
readServerVersionWith = startRead ReadVersion

readTopologyWith :: P.Hooks -> Int -> Runtime -> ServerHandle -> ByteString -> ReadClass -> IO (Request ByteString)
readTopologyWith = startRead ReadTopology

readEntityFieldWith :: EntityField -> P.Hooks -> Int -> Runtime -> ServerHandle -> ByteString -> ReadClass -> IO (Request ByteString)
readEntityFieldWith field = startRead (ReadEntityField field)

-- | Read the physical/link profile in one tagged format expansion. Its
-- registered owner retains the capture reservation through decoding and
-- forcing, including after caller cancellation. This does not acquire clients.
readGraphWith :: P.Hooks -> Int -> Runtime -> ServerHandle -> ByteString -> IO (Request Graph.EntityGraph)
readGraphWith hooks duration runtime client executable =
  startRead (ReadGraph (pinGeneration (serverPin client))) hooks duration runtime client executable ScalarRead

-- | Acquire the finite metadata, physical and attached-client profile in one
-- owned command queue. It retains ordinary graph credit through publication.
readSnapshotWith :: P.Hooks -> Int -> Runtime -> ServerHandle -> ByteString -> IO (Request Graph.Snapshot)
readSnapshotWith hooks duration runtime client executable =
  startRead (ReadSnapshot (pinGeneration (serverPin client))) hooks duration runtime client executable ScalarRead

-- | Retain the complete capture envelope while fields and graphs accumulate.
-- Native requests keep their independent child/parent reservations.
withCaptureBudget :: Runtime -> IO a -> IO a
withCaptureBudget runtime action = bracket
  (atomically (B.acquireBytes runtime.budget B.Ordinary (64 * 1024 * 1024)))
  (atomically . B.releaseBytes) (const action)

commandArguments :: F.Nonce -> ReadCommand value -> [ByteString]
commandArguments nonce command = case command of
  ReadPid -> framed "#{pid}"
  ReadVersion -> framed "#{version}"
  ReadTopology -> framed Topology.topologyFormat
  ReadEntityField field -> let (_, receipt, value) = entityField field in
    framed (receipt <> ":" <> F.escapedFieldFormat value)
  ReadGraph generation -> display (Record.graphFormat generation nonce)
  ReadSnapshot generation -> Record.snapshotCommands generation nonce
  where
    framed = display . F.scalarFormat nonce
    display format = ["display-message", "-p"] <> commandTarget command <> ["-F", format]

entityField :: EntityField -> (ByteString, ByteString, ByteString)
entityField (SessionName ident) = (Utf8.encodeUtf8 (Id.renderSessionId ident),
  fieldFormat Field.SessionId, Field.formatVariable Field.SessionName)
entityField (WindowName ident) = (Utf8.encodeUtf8 (Id.renderWindowId ident),
  fieldFormat Field.WindowId, Field.formatVariable Field.WindowName)
entityField (PaneTitle ident) = (Utf8.encodeUtf8 (Id.renderPaneId ident),
  fieldFormat Field.PaneId, Field.formatVariable Field.PaneTitle)
entityField (PaneCommand ident) = (Utf8.encodeUtf8 (Id.renderPaneId ident),
  fieldFormat Field.PaneId, Field.formatVariable Field.PaneCommand)
entityField (PanePath ident) = (Utf8.encodeUtf8 (Id.renderPaneId ident),
  fieldFormat Field.PaneId, Field.formatVariable Field.PanePath)

fieldFormat :: Field.Field row value -> ByteString
fieldFormat field = "#{" <> Field.formatVariable field <> "}"

commandTarget :: ReadCommand value -> [ByteString]
commandTarget (ReadEntityField field) = let (target, _, _) = entityField field in ["-t", target]
commandTarget _ = []

startRead :: ReadCommand value -> P.Hooks -> Int -> Runtime -> ServerHandle -> ByteString -> ReadClass -> IO (Request value)
startRead command hooks duration runtime@Runtime {forker} client executable allocation = mask_ $ do
  let pool = serverPool client
  unless (pool.budget == runtime.budget) (throwIO ForeignServer)
  when (duration < 1 || duration > 10000000) (throwIO (InvalidReadDeadline duration))
  token <- Entropy.freshToken32
  let hex = "0123456789abcdef" :: ByteString
      encoded = Bytes.pack (concatMap (\byte ->
        [Bytes.index hex (fromIntegral (shiftR byte 4)),
         Bytes.index hex (fromIntegral (byte .&. 15))]) (Bytes.unpack token))
  nonce <- either (throwIO . InvalidReadFrame) pure (F.parseNonce encoded)
  let spec = N.spec executable ([executable, "-u", "-N", "-S", pinPath (serverPin client)]
        <> commandArguments nonce command)
      (lane, resourceClass) = case allocation of
        InspectionRead -> (S.Inspection, B.Inspection)
        ScalarRead -> (S.ScalarRead, B.Ordinary)
  N.validate spec
  now <- getMonotonicTimeNSec
  let delta = fromIntegral duration * 1000
  when (now > maxBound - delta) (throwIO ReadClockOverflow)
  (owner, request) <- atomically $ do
    readTVar pool.closing >>= flip when (throwSTM P.PoolClosed)
    operation <- S.admit runtime.scheduler lane
    let parentBytes = case command of
          -- The caller may stop waiting while the worker still constructs the
          -- graph. Keep the former capture lease with that registered owner.
          ReadGraph _ -> P.retainedBytes + 64 * 1024 * 1024
          ReadSnapshot _ -> P.retainedBytes + 64 * 1024 * 1024
          _ -> P.retainedBytes
    envelope <- B.acquireBytes runtime.budget resourceClass parentBytes
    result <- newEmptyTMVar
    submission <- newTVar NotSubmitted
    cancelled <- newTVar False
    busy <- newTVar True
    failure <- newTVar Nothing
    key <- newTVar Nothing
    let receipt = ReadReceipt runtime.identity (pinGeneration (serverPin client)) operation key
        owner = ReadOwner {operation, receipt, command, result, nonce, deadline = now + delta, envelope,
          submission, cancelled, busy, failure}
    modifyTVar' runtime.reads (<> [owner])
    pure (owner, Request receipt result)
  allocated <- tryWithContext @SomeException $ do
    copied <- N.copySpec spec
    void (forker (\unmask -> readWorker unmask runtime owner
      (readAction unmask runtime owner pool resourceClass hooks copied)))
  case allocated of
    Left (ExceptionWithContext context problem) -> do
      atomically (retireRefusal runtime owner problem)
      let !receipt = owner.receipt
      rethrowIO (ExceptionWithContext (Context.addExceptionAnnotation receipt context) problem)
    Right () -> pure request

remaining :: ReadOwner -> IO Int
remaining owner = do
  now <- getMonotonicTimeNSec
  if now >= owner.deadline then pure 0 else do
    let (whole, fraction) = quotRem (owner.deadline - now) 1000
    pure (fromIntegral whole + if fraction == 0 then 0 else 1)

claimRead :: Runtime -> ReadOwner -> STM Bool
claimRead runtime owner = do
  state <- S.status owner.operation
  if not state.retained then pure False else
    S.claim runtime.scheduler >>= \case
      Nothing -> pure False
      Just selected -> check (selected == owner.operation) >> pure True

readAction :: (forall a. IO a -> IO a) -> Runtime -> ReadOwner -> P.Pool -> B.Class -> P.Hooks -> N.Spec -> IO ()
readAction unmask runtime owner pool resourceClass hooks spec = do
  left <- remaining owner
  claimed <- timeout left (unmask (atomically (claimRead runtime owner)))
  case claimed of
    Just True -> do
      leftAfterClaim <- remaining owner
      cancelled <- atomically (readTVar owner.cancelled)
      if leftAfterClaim == 0 || cancelled then
        atomically (retireRefusal runtime owner (toException ReadExpired))
      else do
        let register ticket = do
              writeTVar owner.submission (Registering ticket)
              let ReadReceipt _ _ _ key = owner.receipt
                  -- A lazy projection here would keep the entire ticket alive.
                  !nativeKey = ticket.key
              writeTVar key (Just nativeKey)
              readTVar owner.cancelled >>= \flag ->
                when flag (writeTVar ticket.cancelled True)
        created <- try @SomeException (P.submitRegistered register resourceClass hooks pool spec "")
        case created of
          Left problem -> do
            atomically (writeTVar owner.submission SubmissionRefused)
            atomically (retireRefusal runtime owner problem)
          Right ticket -> do
            atomically (writeTVar owner.submission (Submitted ticket))
            leftAfterSubmit <- remaining owner
            response <- timeout leftAfterSubmit (unmask (atomically (readTMVar ticket.result)))
            case response of
              Just completed -> finishRead runtime owner ticket completed
              Nothing -> do
                cancelOwner runtime ReadExpired owner
                completed <- unmask (atomically (readTMVar ticket.result))
                finishRead runtime owner ticket completed
    _ -> atomically (retireRefusal runtime owner (toException ReadExpired))

readWorker :: (forall a. IO a -> IO a) -> Runtime -> ReadOwner -> IO () -> IO ()
readWorker unmask runtime owner action = mask_ $ do
  completed <- try @SomeException action
  case completed of
    Right () -> pure ()
    Left problem -> do
      atomically $ do
        state <- S.status owner.operation
        if state.stage == S.Queued then void (S.cancelQueued runtime.scheduler owner.operation)
          else void (S.markUnknown runtime.scheduler owner.operation)
        publishUnavailable owner problem
      recoverRead unmask runtime owner

recoverRead :: (forall a. IO a -> IO a) -> Runtime -> ReadOwner -> IO ()
recoverRead unmask runtime owner = mask_ $ do
  cleaned <- try @SomeException $ do
    submission <- atomically (readTVar owner.submission)
    case submission of
      NotSubmitted -> atomically (retireRefusal runtime owner (toException ReadCancelled))
      SubmissionRefused -> atomically (retireRefusal runtime owner (toException ReadCancelled))
      _ -> case submittedTicket submission of
        Nothing -> throwIO ReadCancelled
        Just ticket -> do
          atomically (writeTVar ticket.cancelled True)
          completed <- unmask (atomically (readTMVar ticket.result))
          finishRead runtime owner ticket completed
  case cleaned of
    Right () -> pure ()
    Left problem -> atomically $ do
      writeTVar owner.failure (Just problem)
      writeTVar owner.busy False

resumeRead :: Runtime -> ReadOwner -> IO ()
resumeRead runtime@Runtime {forker} owner = mask_ $ do
  claimed <- atomically $ do
    owners <- readTVar runtime.reads
    running <- readTVar owner.busy
    if running || not (any ((== owner.operation) . (.operation)) owners)
      then pure False else do
        writeTVar owner.busy True
        writeTVar owner.failure Nothing
        pure True
  when claimed $ do
    created <- try @SomeException (forker (\unmask -> recoverRead unmask runtime owner))
    case created of
      Right _ -> pure ()
      Left problem -> do
        atomically $ do
          writeTVar owner.failure (Just problem)
          writeTVar owner.busy False
        case fromException problem of
          Just (_ :: SomeAsyncException) -> throwIO problem
          Nothing -> pure ()

submittedTicket :: Submission -> Maybe P.Ticket
submittedTicket (Registering ticket) = Just ticket
submittedTicket (Submitted ticket) = Just ticket
submittedTicket _ = Nothing

finishRead :: Runtime -> ReadOwner -> P.Ticket -> Either SomeException P.Completion -> IO ()
finishRead runtime owner@ReadOwner {command, result} ticket completed = do
  evidence <- atomically (tryReadTMVar ticket.launchEvidence)
  case evidence of
    Just (P.LaunchRefused problem) ->
      atomically (retireRefusal runtime owner (either id (const (toException problem)) completed))
    _ -> case completed >>= decodeRead command owner.nonce of
      Left problem -> atomically $ do
        void (S.markUnknown runtime.scheduler owner.operation)
        publishUnavailable owner problem
        releaseRead runtime owner
      Right value -> do
        -- Complete detached byte copies before publishing or releasing credit.
        case command of
          ReadPid -> void (evaluate value)
          ReadVersion -> void (evaluate value)
          ReadTopology -> void (evaluate (force value))
          ReadEntityField _ -> void (evaluate (force value))
          ReadGraph _ -> void (evaluate (force value))
          ReadSnapshot _ -> void (evaluate (force value))
        left <- remaining owner
        atomically $ do
          when (left == 0) $ do
            void (S.markUnknown runtime.scheduler owner.operation)
            publishUnavailable owner (toException ReadExpired)
          let operation = owner.operation
          S.markDispatched runtime.scheduler operation
          S.markResponseClosed runtime.scheduler operation
          void (S.finish runtime.scheduler operation S.Success)
          state <- S.status operation
          case state.outcome of
            Just S.Succeeded -> void (tryPutTMVar result (ReadValue value))
            _ -> pure ()
          releaseRead runtime owner

decodeRead :: ReadCommand value -> F.Nonce -> P.Completion -> Either SomeException value
decodeRead command nonce completed
  | completed.exit /= Just (N.Exited 0) = Left (toException (ReadExit completed.exit))
  | not (Bytes.null completed.errors) = Left (toException (ReadStderr (Bytes.length completed.errors)))
  | otherwise = case command of
      ReadPid -> do
        bytes <- scalar F.decodeScalar 32
        case Ascii.readInteger bytes of
          Just (pid, "") | Bytes.length bytes <= 10 && Bytes.all (\byte -> byte >= 48 && byte <= 57) bytes
              && pid > 0 && pid <= toInteger (maxBound @CInt) -> Right $! pid
          _ -> Left (toException InvalidServerPid)
      ReadVersion -> do
        bytes <- scalar F.decodeScalar 64
        text <- either (const (Left (toException InvalidVersionEncoding))) Right (Utf8.decodeUtf8' bytes)
        case Version.parseVersion text of
          Left problem -> Left (toException (InvalidServerVersion problem))
          Right version -> Right $! version
      ReadTopology -> scalar F.decodeScalar 1048576
      ReadEntityField field -> do
        bytes <- scalar F.decodeEscapedScalar 1048576
        let (target, _, _) = entityField field
        maybe (Left (toException InvalidEntityReceipt)) (Right . Bytes.copy)
          (Bytes.stripPrefix (target <> ":") bytes)
      ReadGraph generation -> either (Left . toException . InvalidRecordFrame) Right
        (Record.decodeGraph generation nonce completed.output)
      ReadSnapshot generation -> either (Left . toException . InvalidRecordFrame) Right
        (Record.decodeSnapshot generation nonce completed.output)
  where
    scalar decoder bound = either (Left . toException . InvalidReadFrame) Right
      (decoder nonce bound completed.output)

publishUnavailable :: ReadOwner -> SomeException -> STM ()
publishUnavailable owner@ReadOwner {result} problem = do
  state <- S.status owner.operation
  case state.outcome of
    Just outcome -> void (tryPutTMVar result (ReadUnavailable outcome (Just problem)))
    _ -> pure ()

retireRefusal :: Runtime -> ReadOwner -> SomeException -> STM ()
retireRefusal runtime owner problem = do
  state <- S.status owner.operation
  if state.stage == S.Queued then void (S.cancelQueued runtime.scheduler owner.operation)
    else void (S.refuseBeforeBirth runtime.scheduler owner.operation)
  publishUnavailable owner problem
  releaseRead runtime owner

releaseRead :: Runtime -> ReadOwner -> STM ()
releaseRead runtime owner = do
  writeTVar owner.submission NotSubmitted
  writeTVar owner.busy False
  B.releaseBytes owner.envelope
  modifyTVar' runtime.reads (filter ((/= owner.operation) . (.operation)))

-- | Publish cancellation intent without claiming the external command stopped.
-- Cancelling an ordinary 'awaitRead' waiter does not invoke this operation.
cancelRead :: Runtime -> Request value -> IO ()
cancelRead runtime request = atomically (cancelOperation runtime (readOperation request))

cancelOperation :: Runtime -> S.Operation -> STM ()
cancelOperation runtime operation = do
  _ <- S.cancelQueued runtime.scheduler operation
  owners <- readTVar runtime.reads
  forM_ (filter ((== operation) . (.operation)) owners)
    (cancelOwnerSTM runtime ReadCancelled)

cancelOwner :: Runtime -> ReadError -> ReadOwner -> IO ()
cancelOwner runtime reason owner = atomically (cancelOwnerSTM runtime reason owner)

cancelOwnerSTM :: Runtime -> ReadError -> ReadOwner -> STM ()
cancelOwnerSTM runtime reason owner = do
  void (S.cancelQueued runtime.scheduler owner.operation)
  void (S.markUnknown runtime.scheduler owner.operation)
  publishUnavailable owner (toException reason)
  writeTVar owner.cancelled True
  readTVar owner.submission >>= mapM_ (\ticket -> writeTVar ticket.cancelled True) . submittedTicket

-- | Relinquish uncertain logical responsibility. This releases no parent,
-- child or pin ownership and also accepts handles returned in 'unresolved'.
detachOperation :: Runtime -> S.Operation -> STM Bool
detachOperation runtime = S.detachResponsibility runtime.scheduler
