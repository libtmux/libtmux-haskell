{-# LANGUAGE RankNTypes #-}
-- | Bounded ownership before, during and after endpoint adoption.
--
-- A t'Runtime' registers a fresh pin owner and its process pool before
-- adoption can create filesystem names. Failed or cancelled adoption leaves
-- cleanup owned here. 'inspect' retires only successfully cleaned entries;
-- 'awaitCleanup' may wait without a deadline. 'shutdown' bounds its two
-- observation phases while retaining incomplete cleanup. Read and mutation
-- requests bind logical admission and deadlines to native ownership.
-- "LibTmux.Server" exposes the Server and shared Runtime scopes.
module LibTmux.Internal.Runtime
  ( Runtime, ServerHandle, ServerOwner, Report (..), newRuntime, adopt, adoptWith
  , newServerOwner, adoptServerOwnerWith, inspectServerOwner, shutdownServerOwner
  , awaitServerOwnerCleanup, detachServerOwnerOperation
  , serverPool, serverPin, usage, inspect, closeServerHandle, requestClose, awaitCleanup, shutdown
  , inspectServerHandle, shutdownServerHandle
  , Request, PidRead, VersionRead, ReadClass (..), ReadResult (..), ReadError (..)
  , readServerPid, readServerPidWith, awaitRead, readStatus, readOperation
  , readServerVersion, readServerVersionWith
  , EntityField (..), readTopologyWith, readEntityFieldWith, readGraphWith, readSnapshotWith, withCaptureBudget
  , ReadReceipt, ReadRecovery (..), readReceipt, receiptGeneration, receiptOperation, inspectReceipt, resumeReceipt
  , cancelReceipt, detachReceipt
  , cancelRead, detachOperation
  , mutateWith
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
import LibTmux.Internal.Command qualified as Command
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
  , budget :: !B.Budget, entries :: !(TVar (Map.IntMap ServerOwner)), nextKey :: !(TVar Int)
  , forker :: P.Fork
  , shutdownRun :: !(TVar (Maybe (TMVar (Either SomeException ()))))
  , scheduler :: !S.Scheduler, owners :: !(TVar [NativeOwner])
  }
data ServerOwner = ServerOwner
  { key :: !Int, group :: !S.Group, pool :: !P.Pool
  , closeFailure :: !(TVar (Maybe SomeException))
  , shutdownRun :: !(TVar (Maybe (TMVar (Either SomeException ()))))
  }
data ServerHandle = ServerHandle !ServerOwner !SocketPin

-- | Physical cleanup, operation workers and logical uncertainty are separate.
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

-- | A typed operation handle with no reference to its t'Runtime', t'ServerHandle',
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

-- | Logical responsibility and an operation's physical owners, observed together.
-- A released native child does not establish a daemon-side command outcome.
data ReadRecovery = ReadRecovery
  { logical :: !S.Status -- ^ Logical progress, original result and retained responsibility.
  , workerOwned :: !Bool -- ^ A decoder or recovery worker still owns this operation.
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

data ReadCommand value where
  ReadPid :: ReadCommand Integer
  ReadVersion :: ReadCommand Version.TmuxVersion
  ReadTopology :: ReadCommand ByteString
  ReadEntityField :: !EntityField -> ReadCommand ByteString
  ReadGraph :: !Graph.Generation -> ReadCommand Graph.EntityGraph
  ReadSnapshot :: !Graph.Generation -> ReadCommand Graph.Snapshot

data NativeCommand value where
  Observe :: !(ReadCommand value) -> NativeCommand value
  Mutate :: !Command.Mutation -> NativeCommand Command.MutationReply

-- The mutation decoder is nullary so it cannot retain caller operands.
data ResultDecoder value where
  ObservationResult :: !(ReadCommand value) -> ResultDecoder value
  MutationResult :: ResultDecoder Command.MutationReply

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
  | InvalidCommandOperands !Command.ArgumentError
  | InvalidCommandReply !Command.ReplyError
  | ReadExit !(Maybe N.Exit) | ReadStderr !Int
  deriving stock (Eq, Show)
instance Exception ReadError

data Submission = NotSubmitted | Registering !P.Ticket | Submitted !P.Ticket | SubmissionRefused
-- Retain the result's type witness until its worker releases ownership.
data NativeOwner where
  NativeOwner ::
    { operation :: !S.Operation
    , receipt :: !ReadReceipt
    , decoder :: !(ResultDecoder value), result :: !(TMVar (ReadResult value))
    , nonce :: !F.Nonce, deadline :: !Word64
    , envelope :: !B.ByteLease, submission :: !(TVar Submission)
    , cancelled :: !(TVar Bool), busy :: !(TVar Bool)
    , failure :: !(TVar (Maybe SomeException))
    } -> NativeOwner

newRuntime :: P.Fork -> IO Runtime
newRuntime forker = do
  identity <- newUnique
  budget <- B.newBudget P.inspectionBytes
  entries <- newTVarIO Map.empty
  nextKey <- newTVarIO 0
  shutdownRun <- newTVarIO Nothing
  scheduler <- S.newScheduler
  owners <- newTVarIO []
  pure Runtime {identity, budget, entries, nextKey, forker, shutdownRun, scheduler, owners}

-- | Adopt one endpoint through a private socket pin. Reserve a client credit
-- before filesystem acquisition. Cancellation preserves its original exception
-- while the Runtime retains cleanup; use 'requestClose' and 'awaitCleanup'.
adopt :: Runtime -> ByteString -> ByteString -> IO ServerHandle
adopt = adoptWith (\_ _ -> pure ())

-- | Adoption with the socket pin's existing deterministic checkpoints.
adoptWith :: (PinCheckpoint -> ByteString -> IO ()) -> Runtime -> ByteString -> ByteString -> IO ServerHandle
adoptWith checkpoint runtime source parent = mask $ \restore -> do
  entry <- newServerOwner runtime
  let abandon = void (try @SomeException (closeEntry entry))
  restore (adoptServerOwnerWith checkpoint runtime entry source parent) `onException` abandon

-- | Reserve and register one provisional owner before acquiring filesystem
-- resources. A caller installing its own scope policy must mask the handoff.
newServerOwner :: Runtime -> IO ServerOwner
newServerOwner runtime@Runtime {forker} = mask_ $ do
  owner <- newPinOwner
  group <- S.newGroup
  atomically $ do
    _ <- inspect runtime
    key <- readTVar runtime.nextKey
    when (key == maxBound) (throwSTM P.ResourceLimit)
    pool <- P.newPoolSTM runtime.budget forker owner 16
    closeFailure <- newTVar Nothing
    shutdownRun <- newTVar Nothing
    let entry = ServerOwner {key, group, pool, closeFailure, shutdownRun}
    writeTVar runtime.nextKey (key + 1)
    modifyTVar' runtime.entries (Map.insert key entry)
    pure entry

-- | Acquire a complete handle for an already registered owner. Its caller
-- retains responsibility for cleanup when acquisition fails or is cancelled.
-- Foreign or closed ownership refuses before filesystem acquisition; admission
-- is checked again before publishing the handle.
adoptServerOwnerWith
  :: (PinCheckpoint -> ByteString -> IO ()) -> Runtime -> ServerOwner
  -> ByteString -> ByteString -> IO ServerHandle
adoptServerOwnerWith checkpoint runtime entry source parent = mask $ \restore -> do
  let requireOpen = atomically $ do
        validateEntry runtime entry
        current <- usage runtime
        closed <- readTVar entry.pool.closing
        when (not current.accepting || closed) (throwSTM P.PoolClosed)
  requireOpen
  pin <- restore (acquirePinWith checkpoint entry.pool.pinOwner source parent)
  requireOpen
  pure (ServerHandle entry pin)

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
  owners <- readTVar runtime.owners
  readWorkers <- mapM workerStatus owners
  pure Report {accepting = current.accepting,
    pending = [(key, status) | (key, _, status, _) <- retained],
    closeFailures = catMaybes [fmap (key,) problem | (key, _, _, problem) <- retained],
    unresolved, readWorkers}
  where
    complete P.CleanupComplete = True
    complete _ = False

-- | Observe only this handle's physical owners and logical group. Membership
-- survives either kind of retirement; a foreign handle changes no state.
inspectServerHandle :: Runtime -> ServerHandle -> STM Report
inspectServerHandle runtime (ServerHandle entry _) = inspectServerOwner runtime entry

inspectServerOwner :: Runtime -> ServerOwner -> STM Report
inspectServerOwner runtime entry = do
  validateEntry runtime entry
  status <- P.report entry.pool
  failure <- readTVar entry.closeFailure
  current <- usage runtime
  closed <- readTVar entry.pool.closing
  unresolved <- S.outstandingIn runtime.scheduler entry.group
  readWorkers <- serverReads runtime entry >>= mapM workerStatus
  let finished = case status of P.CleanupComplete -> True; _ -> False
  pure Report
    { accepting = current.accepting && not closed
    , pending = [(entry.key, status) | not finished]
    , closeFailures = [(entry.key, problem) | not finished, Just problem <- [failure]]
    , unresolved, readWorkers
    }

validateEntry :: Runtime -> ServerOwner -> STM ()
validateEntry runtime entry =
  unless (entry.pool.budget == runtime.budget) (throwSTM ForeignServer)

serverReads :: Runtime -> ServerOwner -> STM [NativeOwner]
serverReads runtime entry =
  filter (S.memberOf entry.group . (.operation)) <$> readTVar runtime.owners

workerStatus :: NativeOwner -> STM (S.Operation, Maybe SomeException)
workerStatus NativeOwner {operation, failure} = (operation,) <$> readTVar failure

-- | Close one handle and settle its queued operations in the same STM cut.
-- Other groups keep their admission, lane permits and first outcomes.
closeServerAdmission :: Runtime -> ServerOwner -> STM ()
closeServerAdmission runtime entry = do
  validateEntry runtime entry
  writeTVar entry.pool.closing True
  owners <- serverReads runtime entry
  forM_ owners $ \owner -> do
    cancelled <- S.cancelQueued runtime.scheduler owner.operation
    when cancelled (publishUnavailable owner (toException ReadClosing))

requestServerClose :: Runtime -> ServerOwner -> IO Report
requestServerClose runtime entry = mask_ $ do
  atomically (closeServerAdmission runtime entry)
  _ <- closeEntry entry
  atomically (serverReads runtime entry) >>= mapM_ (resumeRead runtime)
  atomically (inspectServerOwner runtime entry)

-- | Bound one handle's physical cleanup under the Runtime's shared limits.
-- Concurrent callers join its owned attempt; cancelling a waiter leaves it
-- running. Logical uncertainty remains in the scoped and global reports.
shutdownServerHandle :: Runtime -> ServerHandle -> IO Report
shutdownServerHandle runtime (ServerHandle entry _) = shutdownServerOwner runtime entry

shutdownServerOwner :: Runtime -> ServerOwner -> IO Report
shutdownServerOwner runtime@Runtime {forker} entry =
  runShutdown forker entry.shutdownRun
    (closeServerAdmission runtime entry) (inspectServerOwner runtime entry)
    (shutdownServerPhases runtime entry)

-- | Join only the selected owner's physical cleanup. Logical uncertainty is
-- still explicit; cancellation leaves the registered owner available.
awaitServerOwnerCleanup :: Runtime -> ServerOwner -> IO ()
awaitServerOwnerCleanup runtime entry = do
  report <- requestServerClose runtime entry
  case report.closeFailures of
    (_, problem) : _ -> throwIO problem
    [] -> pure ()
  atomically $ do
    owners <- serverReads runtime entry
    forM_ owners $ \owner -> readTVar owner.failure >>= mapM_ throwSTM
    check (null owners)
  P.awaitCleanup entry.pool
  void (atomically (inspectServerOwner runtime entry))

-- | Relinquish only this owner's logical debt, including after pool cleanup.
-- Runtime and immutable group checks precede any operation-state change.
detachServerOwnerOperation :: Runtime -> ServerOwner -> S.Operation -> STM Bool
detachServerOwnerOperation runtime entry operation = do
  validateEntry runtime entry
  unless (S.memberOf entry.group operation) (throwSTM ForeignServer)
  detachOperation runtime operation

closeServerHandle :: ServerHandle -> IO P.CloseReport
closeServerHandle (ServerHandle entry _) = closeEntry entry >>= either throwIO pure

closeEntry :: ServerOwner -> IO (Either SomeException P.CloseReport)
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
    owners <- readTVar runtime.owners
    forM_ owners $ \owner -> do
      state <- S.status owner.operation
      when (state.outcome == Just S.NotDispatched) $
        publishUnavailable owner (toException ReadClosing)
    Map.elems <$> readTVar runtime.entries
  forM_ entries (void . closeEntry)
  atomically (readTVar runtime.owners) >>= mapM_ (resumeRead runtime)
  atomically (inspect runtime)

-- | Close admission and wait for every retained pool. A cleanup failure throws
-- without deleting its owner; repair the obstacle and retry. This wait has no
-- hard deadline. It joins operation workers but does not await uncertain logical
-- outcomes; inspect 'unresolved' afterward rather than inferring job completion.
awaitCleanup :: Runtime -> IO ()
awaitCleanup runtime = do
  report <- requestClose runtime
  case report.closeFailures of
    (_, problem) : _ -> throwIO problem
    [] -> pure ()
  atomically $ do
    owners <- readTVar runtime.owners
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
shutdown runtime@Runtime {forker} = runShutdown forker runtime.shutdownRun
  (B.closeAdmission runtime.budget) (inspect runtime) (shutdownPhases runtime)

runShutdown
  :: P.Fork -> TVar (Maybe (TMVar (Either SomeException ())))
  -> STM () -> STM Report -> IO () -> IO Report
runShutdown forker attempt closeAdmission inspectTarget phases = mask $ \restore -> do
  (start, selected) <- atomically $ do
    closeAdmission
    previous <- readTVar attempt
    running <- case previous of
      Nothing -> pure False
      Just run -> isEmptyTMVar run
    if running then pure (False, previous) else do
      report <- inspectTarget
      if null report.pending && null report.readWorkers then pure (False, Nothing) else do
        run <- newEmptyTMVar
        writeTVar attempt (Just run)
        pure (True, Just run)
  forM_ selected $ \run -> do
    when start $ do
      let failed (problem :: SomeException) = do
            atomically (putTMVar run (Left problem))
            throwIO problem
      void (forker (\unmask -> do
        result <- try @SomeException (unmask phases)
        atomically (putTMVar run result))) `catch` failed
    restore (atomically (readTMVar run)) >>= either throwIO pure
  atomically inspectTarget

shutdownPhases :: Runtime -> IO ()
shutdownPhases runtime = do
  _ <- requestClose runtime
  graceful <- observeCleanup (inspect runtime)
  case graceful of
    Just () -> pure ()
    Nothing -> do
      atomically (readTVar runtime.owners) >>= mapM_ (cancelOwner runtime ReadClosing)
      entries <- atomically (Map.elems <$> readTVar runtime.entries)
      forM_ entries (P.abortAll . (.pool))
      _ <- requestClose runtime
      void (observeCleanup (inspect runtime))

shutdownServerPhases :: Runtime -> ServerOwner -> IO ()
shutdownServerPhases runtime entry = do
  _ <- requestServerClose runtime entry
  graceful <- observeCleanup (inspectServerOwner runtime entry)
  case graceful of
    Just () -> pure ()
    Nothing -> do
      atomically (serverReads runtime entry) >>= mapM_ (cancelOwner runtime ReadClosing)
      P.abortAll entry.pool
      _ <- requestServerClose runtime entry
      void (observeCleanup (inspectServerOwner runtime entry))

observeCleanup :: STM Report -> IO (Maybe ())
observeCleanup inspectTarget = timeout 250000 $ atomically $ do
  report <- inspectTarget
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
  owners <- readTVar runtime.owners
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
    owners <- filter ((== operation) . (.operation)) <$> readTVar runtime.owners
    pure (selected >>= (`Map.lookup` jobs), owners)
  mapM_ (P.resumeCleanup (serverPool client)) ticket
  mapM_ (resumeRead runtime) owners
  observed <- atomically (inspectReceipt runtime client receipt)
  mapM_ throwIO observed.workerFailure

-- | Request cancellation of the correlated operation, retaining unresolved debt.
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

-- | Wait only for this operation's first result. Caller cancellation changes no
-- ownership. Use 'cancelRead' to request cancellation of the owned operation.
awaitRead :: Request value -> IO (ReadResult value)
awaitRead (Request _ result) = atomically (readTMVar result)

-- | Acquire a fresh, nonce-framed PID using a one-second deadline.
readServerPid :: Runtime -> ServerHandle -> ByteString -> ReadClass -> IO PidRead
readServerPid = readServerPidWith P.defaultHooks 1000000

-- | Use existing process checkpoints and a checked 1..10000000 microsecond
-- deadline. The same expiration governs queueing, submission and validation.
readServerPidWith :: P.Hooks -> Int -> Runtime -> ServerHandle -> ByteString -> ReadClass -> IO PidRead
readServerPidWith = startRead ReadPid

-- | Admit a literal mutation in the serialized ordinary lane. Known failures
-- preserve their reply; uncertainty retains the correlated operation.
mutateWith :: P.Hooks -> Int -> Runtime -> ServerHandle -> ByteString -> Command.Mutation -> IO (Request Command.MutationReply)
mutateWith hooks duration runtime client executable mutation =
  startNative (Mutate mutation) hooks duration runtime client executable ScalarRead

-- | Observe a stable release identity through the pinned server. Use
-- 'Version.requireSupported' separately for supported-range admission;
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
startRead = startNative . Observe

startNative :: NativeCommand value -> P.Hooks -> Int -> Runtime -> ServerHandle -> ByteString -> ReadClass -> IO (Request value)
startNative selected hooks duration runtime@Runtime {forker} client@(ServerHandle entry _) executable allocation = mask_ $ do
  let pool = serverPool client
  unless (pool.budget == runtime.budget) (throwIO ForeignServer)
  when (duration < 1 || duration > 10000000) (throwIO (InvalidReadDeadline duration))
  token <- Entropy.freshToken32
  let hex = "0123456789abcdef" :: ByteString
      encoded = Bytes.pack (concatMap (\byte ->
        [Bytes.index hex (fromIntegral (shiftR byte 4)),
         Bytes.index hex (fromIntegral (byte .&. 15))]) (Bytes.unpack token))
  nonce <- either (throwIO . InvalidReadFrame) pure (F.parseNonce encoded)
  (decoder, arguments, input) <- either (throwIO . InvalidCommandOperands) pure (compileNative nonce selected)
  when (P.inputSize input > P.inputLimitBytes) (throwIO P.ResourceLimit)
  case input of
    P.BytesInput bytes -> void (evaluate (force bytes))
    P.KeepInputOpen -> pure ()
  let spec = N.spec executable ([executable, "-u", "-N", "-S", pinPath (serverPin client)]
        <> arguments)
      (lane, resourceClass) = case decoder of
        MutationResult -> (S.Mutation, B.Ordinary)
        ObservationResult _ -> case allocation of
          InspectionRead -> (S.Inspection, B.Inspection)
          ScalarRead -> (S.ScalarRead, B.Ordinary)
  N.validate spec
  now <- getMonotonicTimeNSec
  let delta = fromIntegral duration * 1000
  when (now > maxBound - delta) (throwIO ReadClockOverflow)
  (owner, request) <- atomically $ do
    readTVar pool.closing >>= flip when (throwSTM P.PoolClosed)
    operation <- S.admitIn runtime.scheduler entry.group lane
    let parentBytes = case decoder of
          -- Retain graph construction credit with its worker after caller cancellation.
          ObservationResult (ReadGraph _) -> P.retainedBytes + 64 * 1024 * 1024
          ObservationResult (ReadSnapshot _) -> P.retainedBytes + 64 * 1024 * 1024
          MutationResult -> P.retainedBytes + fromIntegral N.vectorLimitBytes
          _ -> P.retainedBytes
    envelope <- B.acquireBytes runtime.budget resourceClass parentBytes
    result <- newEmptyTMVar
    submission <- newTVar NotSubmitted
    cancelled <- newTVar False
    busy <- newTVar True
    failure <- newTVar Nothing
    key <- newTVar Nothing
    let receipt = ReadReceipt runtime.identity (pinGeneration (serverPin client)) operation key
        owner = NativeOwner {operation, receipt, decoder, result, nonce, deadline = now + delta, envelope,
          submission, cancelled, busy, failure}
    modifyTVar' runtime.owners (<> [owner])
    pure (owner, Request receipt result)
  allocated <- tryWithContext @SomeException $ do
    copied <- N.copySpec spec
    void (forker (\unmask -> readWorker unmask runtime owner
      (readAction unmask runtime owner pool resourceClass hooks copied input)))
  case allocated of
    Left (ExceptionWithContext context problem) -> do
      atomically (retireRefusal runtime owner problem)
      let !receipt = owner.receipt
      rethrowIO (ExceptionWithContext (Context.addExceptionAnnotation receipt context) problem)
    Right () -> pure request

compileNative :: F.Nonce -> NativeCommand value -> Either Command.ArgumentError (ResultDecoder value, [ByteString], P.Input)
compileNative nonce (Observe command) = Right (ObservationResult command, commandArguments nonce command, P.BytesInput "")
compileNative _ (Mutate mutation) = do
  arguments <- Command.compileMutation mutation
  pure (MutationResult, "-C" : arguments, P.KeepInputOpen)

remaining :: NativeOwner -> IO Int
remaining owner = do
  now <- getMonotonicTimeNSec
  if now >= owner.deadline then pure 0 else do
    let (whole, fraction) = quotRem (owner.deadline - now) 1000
    pure (fromIntegral whole + if fraction == 0 then 0 else 1)

claimRead :: Runtime -> NativeOwner -> STM Bool
claimRead runtime owner = do
  state <- S.status owner.operation
  if not state.retained then pure False else
    S.claim runtime.scheduler >>= \case
      Nothing -> pure False
      Just selected -> check (selected == owner.operation) >> pure True

readAction :: (forall a. IO a -> IO a) -> Runtime -> NativeOwner -> P.Pool -> B.Class -> P.Hooks -> N.Spec -> P.Input -> IO ()
readAction unmask runtime owner pool resourceClass hooks spec input = do
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
        created <- try @SomeException (P.submitInputRegistered register resourceClass hooks pool spec input)
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

readWorker :: (forall a. IO a -> IO a) -> Runtime -> NativeOwner -> IO () -> IO ()
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

recoverRead :: (forall a. IO a -> IO a) -> Runtime -> NativeOwner -> IO ()
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

resumeRead :: Runtime -> NativeOwner -> IO ()
resumeRead runtime@Runtime {forker} owner = mask_ $ do
  claimed <- atomically $ do
    owners <- readTVar runtime.owners
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

finishRead :: Runtime -> NativeOwner -> P.Ticket -> Either SomeException P.Completion -> IO ()
finishRead runtime owner@NativeOwner {decoder, result} ticket completed = do
  evidence <- atomically (tryReadTMVar ticket.launchEvidence)
  case evidence of
    Just (P.LaunchRefused problem) ->
      atomically (retireRefusal runtime owner (either id (const (toException problem)) completed))
    _ -> case completed >>= decodeResult decoder owner.nonce of
      Left problem -> atomically $ do
        void (S.markUnknown runtime.scheduler owner.operation)
        publishUnavailable owner problem
        releaseRead runtime owner
      Right value -> do
        -- Complete detached byte copies before publishing or releasing credit.
        forceResult decoder value
        left <- remaining owner
        atomically $ do
          when (left == 0) $ do
            void (S.markUnknown runtime.scheduler owner.operation)
            publishUnavailable owner (toException ReadExpired)
          let operation = owner.operation
          S.markDispatched runtime.scheduler operation
          S.markResponseClosed runtime.scheduler operation
          void (S.finish runtime.scheduler operation (completionEvidence decoder value))
          state <- S.status operation
          case state.outcome of
            Just S.Succeeded -> void (tryPutTMVar result (ReadValue value))
            Just S.Failed -> void (tryPutTMVar result (ReadValue value))
            _ -> pure ()
          releaseRead runtime owner

forceResult :: ResultDecoder value -> value -> IO ()
forceResult MutationResult value = void (evaluate (force value))
forceResult (ObservationResult command) value = case command of
  ReadPid -> void (evaluate value)
  ReadVersion -> void (evaluate value)
  ReadTopology -> void (evaluate (force value))
  ReadEntityField _ -> void (evaluate (force value))
  ReadGraph _ -> void (evaluate (force value))
  ReadSnapshot _ -> void (evaluate (force value))

completionEvidence :: ResultDecoder value -> value -> S.Completion
completionEvidence (ObservationResult _) _ = S.Success
completionEvidence MutationResult Command.Applied = S.Success
completionEvidence MutationResult _ = S.CommandFailure

decodeResult :: ResultDecoder value -> F.Nonce -> P.Completion -> Either SomeException value
decodeResult (ObservationResult command) = decodeRead command
decodeResult MutationResult = \_ completed -> case completed.launchFailure of
  Just problem -> Left (toException problem)
  Nothing ->
    let exit = case completed.exit of
          Just (N.Exited status) -> Just (fromIntegral status)
          _ -> Nothing
    in either (Left . toException . InvalidCommandReply) Right
      (Command.decodeControlReply exit completed.output completed.errors)

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

publishUnavailable :: NativeOwner -> SomeException -> STM ()
publishUnavailable owner@NativeOwner {result} problem = do
  state <- S.status owner.operation
  case state.outcome of
    Just outcome -> void (tryPutTMVar result (ReadUnavailable outcome (Just problem)))
    _ -> pure ()

retireRefusal :: Runtime -> NativeOwner -> SomeException -> STM ()
retireRefusal runtime owner problem = do
  state <- S.status owner.operation
  if state.stage == S.Queued then void (S.cancelQueued runtime.scheduler owner.operation)
    else void (S.refuseBeforeBirth runtime.scheduler owner.operation)
  publishUnavailable owner problem
  releaseRead runtime owner

releaseRead :: Runtime -> NativeOwner -> STM ()
releaseRead runtime owner = do
  writeTVar owner.submission NotSubmitted
  writeTVar owner.busy False
  B.releaseBytes owner.envelope
  modifyTVar' runtime.owners (filter ((/= owner.operation) . (.operation)))

-- | Publish cancellation intent without claiming the external command stopped.
-- Cancelling an ordinary 'awaitRead' waiter does not invoke this operation.
cancelRead :: Runtime -> Request value -> IO ()
cancelRead runtime request = atomically (cancelOperation runtime (readOperation request))

cancelOperation :: Runtime -> S.Operation -> STM ()
cancelOperation runtime operation = do
  _ <- S.cancelQueued runtime.scheduler operation
  owners <- readTVar runtime.owners
  forM_ (filter ((== operation) . (.operation)) owners)
    (cancelOwnerSTM runtime ReadCancelled)

cancelOwner :: Runtime -> ReadError -> NativeOwner -> IO ()
cancelOwner runtime reason owner = atomically (cancelOwnerSTM runtime reason owner)

cancelOwnerSTM :: Runtime -> ReadError -> NativeOwner -> STM ()
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
