-- | Observe and change an existing tmux daemon through an owned Server handle.
--
-- A t'Server' represents one adoption of one endpoint. 'withServer' owns its
-- socket pin, native command clients and cleanup workers. Closing this scope
-- releases those resources; it does not send @kill-server@. The tmux noun
-- @Client@ refers to detached observations in "LibTmux.Snapshot".
-- 'withRuntime' and 'withServerIn' give several handles shared resource limits
-- and independent Server scopes.
--
-- 'capture' returns fully decoded, validated values. Field access and graph
-- navigation are pure. Captures use an observation interval, not an atomic
-- transaction over tmux and operating-system state.
-- 'createSession' returns historical created identities. 'renameSession',
-- 'renameWindow' and 'setPaneTitle' perform explicit mutations
-- against generation-bound references. Earlier observations stay detached.
--
-- Operational failures use t'TmuxException'. 'tryTmux' catches that type only.
-- Cancellation retains its original exception class. If bounded cleanup
-- cannot finish, 'cleanupRecoveries' retrieves the owning recovery scope
-- from the exception context. A failed callback remains the primary failure.
module LibTmux.Server
  ( -- * Open and observe
    Server, ServerConfig (..), serverConfig, withServer, capture, serverGeneration
    -- * Mutation deadlines
  , MutationOptions (..), defaultMutationOptions
    -- * Detached session creation
  , createSession, createSessionWith
    -- * Rename and title
  , renameSession, renameSessionWith, renameWindow, renameWindowWith, setPaneTitle, setPaneTitleWith
    -- * Shared ownership
  , Runtime, withRuntime, withServerIn
    -- * Operational failures
  , TmuxException (..), tryTmux
    -- * Scope cleanup
  , CleanupRecovery, CleanupStatus (..), cleanupRecoveries, cleanupFailure, cleanupObservation
  , inspectCleanup, resumeCleanup, awaitCleanup, detachUnresolved
    -- * Correlated capture recovery
  , CaptureRecovery, captureRecoveries, recoveryOperation, recoveryGeneration
  , ReadRecovery (..), inspectCaptureRecovery, resumeCaptureRecovery, detachCaptureRecovery
    -- * Correlated creation recovery
  , CreationRecovery, creationRecoveries, creationOperation, creationGeneration
  , creationReceipt, inspectCreationRecovery, resumeCreationRecovery, awaitCreationRecovery, detachCreationRecovery
    -- * Correlated mutation recovery
  , MutationRecovery, mutationRecoveries, mutationOperation, mutationGeneration
  , inspectMutationRecovery, resumeMutationRecovery, awaitMutationRecovery, detachMutationRecovery
  , Operation, Status (..), Stage (..), Outcome (..), operationStatus
  ) where

import Control.Concurrent.STM (atomically, readTVar)
import Control.DeepSeq (force)
import Control.Exception
  ( ExceptionWithContext (..), IOException, SomeAsyncException, SomeException
  , catchNoPropagate, evaluate, fromException, mask, rethrowIO, throwIO, tryWithContext
  )
import Control.Exception.Context (ExceptionContext)
import Control.Exception.Context qualified as Context
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.Maybe (isJust)
import Data.Text qualified as Text
import Data.Time.Clock (NominalDiffTime)
import Data.Type.Coercion (coerceWith, sym)
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.Capture (CaptureRecovery)
import LibTmux.Internal.Capture qualified as C
import LibTmux.Creation qualified as Creation
import LibTmux.Internal.Creation (CreationRecovery)
import LibTmux.Internal.Creation qualified as Create
import LibTmux.Internal.Command qualified as Command
import LibTmux.Internal.Graph qualified as G
import LibTmux.Internal.Mutation qualified as M
import LibTmux.Internal.Mutation (MutationRecovery)
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Native qualified as N
import LibTmux.Internal.Runtime (ReadRecovery (..))
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.Scheduler (Operation, Status (..), Stage (..), Outcome (..))
import LibTmux.Internal.Scheduler qualified as S
import LibTmux.Internal.Scope
  ( TmuxException (..), CleanupRecovery, CleanupStatus (..)
  , cleanupFailure, cleanupObservation, inspectCleanup, resumeCleanup, awaitCleanup
  )
import LibTmux.Internal.Scope qualified as Scope
import LibTmux.Internal.SocketPin qualified as Pin
import LibTmux.Version qualified as Version
import LibTmux.Snapshot (Generation, Snapshot, SessionRef, WindowRef, PaneRef, TmuxText)
import System.Directory.OsPath qualified as Directory
import System.OsPath.Posix (PosixPath)
import System.OsPath.Posix qualified as Path
import System.OsString qualified as Platform
import System.OsString.Posix qualified as Os

-- | One pinned endpoint and connection generation.
-- Retaining this value after 'withServer' or 'withServerIn' keeps no admission open.
data Server = Server !R.Runtime !R.ServerHandle !ByteString !Int

-- | Shared resource limits and cleanup ownership for Server handles. Create
-- one with 'withRuntime', then adopt endpoints through 'withServerIn'.
-- Detached t'Snapshot' values retain no Runtime.
newtype Runtime = Runtime R.Runtime

-- | Own a Runtime for the callback and perform bounded cleanup afterward.
-- Closing it retires every adopted handle; application-owned threads remain
-- the application's responsibility. Late adoption fails with 'RuntimeClosed'.
-- The daemon remains running.
--
-- Callback failures and cancellation keep their original exception class.
-- Incomplete cleanup retains a t'CleanupRecovery' in the exception context;
-- use 'tryTmux' and 'cleanupRecoveries' to keep that responsibility reachable.
withRuntime :: (Runtime -> IO a) -> IO a
withRuntime action = do
  runtime <- R.newRuntime P.normalFork
  Scope.runScope runtime (action (Runtime runtime))

-- | Adopt one endpoint within an existing Runtime and close only that handle
-- after the callback. Other handles remain admitted under the shared limits;
-- each adoption has its own 'serverGeneration'. Use 'withServer' for one handle.
-- Opening validates the daemon's supported version before the callback.
--
-- Failed adoption can retain a t'CleanupRecovery' before a t'Server' exists.
-- Inspection, retry and waiting through that owner stay scoped to the failed
-- adoption. Cleanup preserves application exceptions, incoming masking state
-- and cancellation; known acquisition failures use t'TmuxException'.
withServerIn :: Runtime -> ServerConfig -> (Server -> IO a) -> IO a
withServerIn (Runtime runtime) config action = mask $ \restore -> do
  current <- atomically (R.usage runtime)
  when (not current.accepting) (throwIO RuntimeClosed)
  (executable, duration) <- restore (checkedConfiguration config)
  owner <- operational $
    catchNoPropagate (R.newServerOwner runtime) $
      \original@(ExceptionWithContext context (problem :: B.LimitError)) -> case problem of
        B.AdmissionClosed -> rethrowIO (ExceptionWithContext context RuntimeClosed)
        _ -> rethrowIO original
  Scope.runServerScope runtime owner $ restore $ do
    handle <- operational (R.adoptServerOwnerWith (\_ _ -> pure ()) runtime owner
      (posixBytes config.socketPath) (posixBytes config.pinDirectory))
    operational (qualifyVersion runtime handle executable duration)
    action (Server runtime handle executable duration)

-- | Pure configuration, checked when 'withServer' or 'withServerIn' opens the handle.
-- Paths retain POSIX bytes; no text decoding or shell interpretation occurs.
data ServerConfig = ServerConfig
  { socketPath :: !PosixPath -- ^ Existing tmux socket, with an absolute trusted path.
  , executable :: !PosixPath -- ^ Executable path or a program resolved once through PATH.
  , pinDirectory :: !PosixPath -- ^ Writable trusted directory on the socket's filesystem.
  , captureTimeout :: !NominalDiffTime -- ^ Capture and initial version-check deadline in seconds, positive and at most ten.
  }
  deriving stock (Eq, Show)

-- | Configure an existing socket, resolving @tmux@ through PATH when opened.
-- The private pin uses the socket's parent directory. The capture timeout is
-- two seconds; callers can change it before opening a Server scope.
serverConfig :: PosixPath -> ServerConfig
serverConfig socket = ServerConfig socket (Os.fromBytestring "tmux") (Path.takeDirectory socket) 2

-- | Pin the endpoint, validate its supported daemon version, run the callback,
-- then perform bounded owned cleanup. Version observation runs no command hook.
-- Unsupported or unrecognized replies fail before entering the callback.
-- Cleanup never replaces a callback exception. Incomplete cleanup raises
-- 'CleanupFailed' after success, or annotates the original callback failure
-- with a reachable t'CleanupRecovery'. No daemon shutdown is requested.
withServer :: ServerConfig -> (Server -> IO a) -> IO a
withServer config action = do
  (executable, duration) <- checkedConfiguration config
  runtime <- R.newRuntime P.normalFork
  Scope.runScope runtime $ do
    handle <- operational (R.adopt runtime (posixBytes config.socketPath) (posixBytes config.pinDirectory))
    operational (qualifyVersion runtime handle executable duration)
    action (Server runtime handle executable duration)

qualifyVersion :: R.Runtime -> R.ServerHandle -> ByteString -> Int -> IO ()
qualifyVersion runtime handle executable duration = do
  (_, _, version) <- C.captureVersionWith P.defaultHooks runtime handle executable duration
  either (throwIO . UnsupportedTmuxVersion) (const (pure ())) (Version.requireSupported version)

checkedConfiguration :: ServerConfig -> IO (ByteString, Int)
checkedConfiguration config = do
  let seconds = toRational config.captureTimeout
  when (seconds <= 0 || seconds > 10) $
    throwIO (InvalidConfiguration "captureTimeout must be greater than zero and at most ten seconds")
  executable <- operational (resolveExecutable config.executable)
  pure (executable, fromInteger (ceiling (seconds * 1000000)))

-- | Acquire the complete baseline graph, metadata and attached clients.
-- Returned values own their data and remain usable after 'withServer' exits.
-- Capacity and acquisition failure are errors; they never become empty lists.
capture :: Server -> IO Snapshot
capture (Server runtime handle executable duration) = operational $ do
  closed <- atomically (readTVar (R.serverPool handle).closing)
  when closed (throwIO ServerClosed)
  (started, finished, decoded) <- C.captureSnapshot runtime handle executable duration
  stamped <- either (throwIO . InvalidObservation . Text.pack . show) pure
    (G.stampSnapshot started finished decoded)
  evaluate (force stamped)

-- | The handle's opaque generation, available without contacting tmux.
serverGeneration :: Server -> Generation
serverGeneration (Server _ handle _ _) = Pin.pinGeneration (R.serverPin handle)

-- | Per-command deadline, checked before admission. Start from
-- 'defaultMutationOptions' and update 'timeout' in seconds.
data MutationOptions = MutationOptions
  { timeout :: !NominalDiffTime -- ^ Positive seconds, at most ten; the default is one.
  }
  deriving stock (Eq, Show)

-- | One second for command submission and its complete response.
defaultMutationOptions :: MutationOptions
defaultMutationOptions = MutationOptions 1

-- | Create a detached session through this pinned Server. Start from
-- 'LibTmux.Creation.defaultSessionOptions'. The result contains actual created refs,
-- not observed records; capture again before inspecting the new graph.
-- After-hooks may already have renamed or destroyed these targets.
createSession :: Server -> Creation.SessionOptions -> IO Creation.CreatedSession
createSession = createSessionWith defaultMutationOptions

-- | Create with one 'timeout' covering caller-context acquisition, admission
-- and completion. 'MutationAppliedWithErrors', cancellation and timeout may
-- retain a t'CreationRecovery' with known IDs. A missing receipt proves no
-- absence. Creation never retries and never starts a replacement daemon.
createSessionWith :: MutationOptions -> Server -> Creation.SessionOptions -> IO Creation.CreatedSession
createSessionWith options (Server runtime handle executable _) settings = operational $ do
  duration <- mutationDuration options
  closed <- atomically (readTVar (R.serverPool handle).closing)
  when closed (throwIO ServerClosed)
  Create.performCreation P.defaultHooks duration runtime handle executable settings

-- | Rename the session targeted by a reference from this Server generation.
-- The name is literal text. Earlier t'Snapshot' values keep their old names;
-- call 'capture' for a new observation. Use 'renameSessionWith' for a deadline.
renameSession :: Server -> SessionRef -> Text.Text -> IO ()
renameSession = renameSessionWith defaultMutationOptions

-- | 'renameSession' with an explicit 'timeout'. A known primary rejection raises
-- 'MutationRejected'; an applied command with a failed hook raises
-- 'MutationAppliedWithErrors'. Neither result implies rollback.
renameSessionWith :: MutationOptions -> Server -> SessionRef -> Text.Text -> IO ()
renameSessionWith options server (G.SessionRef generation ident) label =
  mutate options server generation (Command.RenameSession ident label)

-- | Rename one physical window across all its session links. The label retains
-- bytes through t'TmuxText'; tmux may reject names its release does not accept.
-- Format-looking text stays literal. See 'renameWindowWith' for a deadline.
renameWindow :: Server -> WindowRef -> TmuxText -> IO ()
renameWindow = renameWindowWith defaultMutationOptions

-- | 'renameWindow' with an explicit deadline. Success confirms the primary
-- command's response, not completion of background jobs started by hooks.
-- 'capture' observes the current label; existing snapshots remain detached.
renameWindowWith :: MutationOptions -> Server -> WindowRef -> TmuxText -> IO ()
renameWindowWith options server (G.WindowRef generation ident) label =
  mutate options server generation (Command.RenameWindow ident label)

-- | Set the literal title of a pane from this Server generation. The pane's
-- application can replace it later. Use 'setPaneTitleWith' for a deadline.
setPaneTitle :: Server -> PaneRef -> Text.Text -> IO ()
setPaneTitle = setPaneTitleWith defaultMutationOptions

-- | 'setPaneTitle' with an explicit deadline. Missing panes fail with
-- 'MutationRejected'. Foreign and offline references fail with 'InvalidTarget'
-- before dispatch. No mutation retries after cancellation or timeout.
setPaneTitleWith :: MutationOptions -> Server -> PaneRef -> Text.Text -> IO ()
setPaneTitleWith options server (G.PaneRef generation ident) label =
  mutate options server generation (Command.SetPaneTitle ident label)

mutate :: MutationOptions -> Server -> Generation -> Command.Mutation -> IO ()
mutate options server@(Server runtime handle executable _) generation command = operational $ do
  duration <- mutationDuration options
  closed <- atomically (readTVar (R.serverPool handle).closing)
  when closed (throwIO ServerClosed)
  unless (generation == serverGeneration server)
    (throwIO (InvalidTarget "reference belongs to a different Server generation or an offline fixture"))
  M.performMutation P.defaultHooks duration runtime handle executable command

mutationDuration :: MutationOptions -> IO Int
mutationDuration options = do
  let seconds = toRational options.timeout
  when (seconds <= 0 || seconds > 10)
    (throwIO (InvalidConfiguration "mutation timeout must be positive and at most ten seconds"))
  pure (fromInteger (ceiling (seconds * 1000000)))

-- | Correlated creation owners from 'tryTmux' or 'tryWithContext'. Keep the
-- context when handling failure, including an applied command's hook error.
creationRecoveries :: ExceptionContext -> [CreationRecovery]
creationRecoveries = Context.getExceptionAnnotations

-- | Metadata-only identity of the original creation operation.
creationOperation :: CreationRecovery -> Operation
creationOperation = R.receiptOperation . Create.recoveryReceipt

-- | Originating Server generation, including after the scope closes.
creationGeneration :: CreationRecovery -> Generation
creationGeneration = R.receiptGeneration . Create.recoveryReceipt

-- | Read any complete historical receipt already observed by the library.
-- This reads owned metadata without contacting tmux. 'Nothing' does not mean
-- no session was created; unread or incomplete evidence cannot supply IDs.
creationReceipt :: CreationRecovery -> IO (Maybe Creation.CreatedSession)
creationReceipt = atomically . Create.observedReceipt

-- | Inspect logical outcome and native ownership without external operations.
inspectCreationRecovery :: CreationRecovery -> IO ReadRecovery
inspectCreationRecovery = atomically . Create.inspectRecovery

-- | Resume existing cleanup; never execute the creation again.
resumeCreationRecovery :: CreationRecovery -> IO ()
resumeCreationRecovery = operational . Create.resumeRecovery

-- | Join the original native child and decoder. Logical uncertainty can
-- remain, and this wait proves no hook/background-job completion.
awaitCreationRecovery :: CreationRecovery -> IO ReadRecovery
awaitCreationRecovery = operational . Create.awaitRecovery

-- | Relinquish logical uncertainty while preserving physical cleanup owners.
-- This does not remove the created session or repeat the command.
detachCreationRecovery :: CreationRecovery -> IO Bool
detachCreationRecovery = operational . atomically . Create.detachRecovery

-- | Catch library failures with their exception context. Retain this value
-- when handling an error so cleanup and operation owners stay reachable.
-- Application exceptions and asynchronous cancellation propagate.
tryTmux :: IO a -> IO (Either (ExceptionWithContext TmuxException) a)
tryTmux = tryWithContext

-- | Cleanup owners retained by a failed or cancelled scope. The context
-- comes from 'tryTmux' or 'tryWithContext'. Inspection performs no tmux IO.
-- Nested scopes can contribute overlapping owners; inspect and resume each
-- retained responsibility through 'inspectCleanup' and 'resumeCleanup'.
cleanupRecoveries :: ExceptionContext -> [CleanupRecovery]
cleanupRecoveries = Context.getExceptionAnnotations

-- | Relinquish one logical operation from this cleanup scope. This releases
-- no native resources and does not prove that daemon-side work completed.
detachUnresolved :: CleanupRecovery -> Operation -> IO Bool
detachUnresolved recovery = operational . Scope.detachUnresolved recovery

-- | Read owners retained by a capture or Server version check, including cancellation.
captureRecoveries :: ExceptionContext -> [CaptureRecovery]
captureRecoveries = Context.getExceptionAnnotations

-- | Metadata-only operation identity for the failed capture.
recoveryOperation :: CaptureRecovery -> Operation
recoveryOperation = R.receiptOperation . C.recoveryReceipt

-- | Correlate the failed capture with its Server generation.
recoveryGeneration :: CaptureRecovery -> Generation
recoveryGeneration = R.receiptGeneration . C.recoveryReceipt

-- | Observe logical outcome, decoder ownership and native cleanup locally.
-- This reads runtime metadata and performs no tmux command.
inspectCaptureRecovery :: CaptureRecovery -> IO ReadRecovery
inspectCaptureRecovery = atomically . C.inspectRecovery

-- | Resume existing cleanup without dispatching the capture again.
resumeCaptureRecovery :: CaptureRecovery -> IO ()
resumeCaptureRecovery = operational . C.resumeRecovery

-- | Explicitly detach logical uncertainty while preserving native ownership.
detachCaptureRecovery :: CaptureRecovery -> IO Bool
detachCaptureRecovery = operational . atomically . C.detachRecovery

-- | Recover the exact operation after failure, timeout or cancellation. The
-- context comes from 'tryTmux' or 'tryWithContext'; cancellation keeps its
-- original exception class and is not caught by 'tryTmux'.
mutationRecoveries :: ExceptionContext -> [MutationRecovery]
mutationRecoveries = Context.getExceptionAnnotations

-- | Metadata-only identity of the original command. 'operationStatus' remains
-- available after native cleanup; this value contains no command operands.
mutationOperation :: MutationRecovery -> Operation
mutationOperation = R.receiptOperation . M.recoveryReceipt

-- | Server generation associated with this mutation's recovery owner.
mutationGeneration :: MutationRecovery -> Generation
mutationGeneration = R.receiptGeneration . M.recoveryReceipt

-- | Inspect the original operation's logical and physical ownership locally.
-- This performs no tmux command. An unknown outcome does not become success
-- merely because the native child has exited.
inspectMutationRecovery :: MutationRecovery -> IO ReadRecovery
inspectMutationRecovery = atomically . M.inspectRecovery

-- | Resume existing native cleanup and decoder ownership, without repeating
-- the command. Allocation failure retains the same recovery owner.
resumeMutationRecovery :: MutationRecovery -> IO ()
resumeMutationRecovery = operational . M.resumeRecovery

-- | Wait for the original decoder and native child to retire. This may still
-- return retained 'OutcomeUnknown'; it does not wait for a daemon hook job.
-- Cancellation keeps this recovery owner in the new exception context.
awaitMutationRecovery :: MutationRecovery -> IO ReadRecovery
awaitMutationRecovery = operational . M.awaitRecovery

-- | Relinquish this operation's logical uncertainty. This neither cancels
-- daemon work nor releases native resources, and never repeats the mutation.
detachMutationRecovery :: MutationRecovery -> IO Bool
detachMutationRecovery = operational . atomically . M.detachRecovery

-- | Read retained operation metadata, including after its physical cleanup.
operationStatus :: Operation -> IO Status
operationStatus = atomically . S.status

resolveExecutable :: PosixPath -> IO ByteString
resolveExecutable executable = case Platform.coercionToPlatformTypes of
  Left _ -> throwIO (InvalidConfiguration "this package requires Linux POSIX paths")
  Right (_, proof) -> do
    selected <- Directory.findExecutable (coerceWith (sym proof) executable)
    path <- maybe (throwIO (InvalidConfiguration "tmux executable was not found")) Directory.makeAbsolute selected
    pure (posixBytes (coerceWith proof path))

posixBytes :: PosixPath -> ByteString
posixBytes = Bytes.pack . map (fromIntegral . fromEnum . Os.toChar) . Os.unpack

operational :: IO a -> IO a
operational action = catchNoPropagate action $ \original@(ExceptionWithContext context (problem :: SomeException)) ->
  let known = or
        [ isJust (fromException @IOException problem)
        , isJust (fromException @Pin.PinError problem)
        , isJust (fromException @R.ReadError problem)
        , isJust (fromException @C.CaptureError problem)
        , isJust (fromException @B.LimitError problem)
        , isJust (fromException @P.OwnerError problem)
        , isJust (fromException @N.Failure problem)
        , isJust (fromException @S.AdmissionError problem)
        ]
  in if known && not (isJust (fromException @SomeAsyncException problem))
       then rethrowIO (ExceptionWithContext context (OperationFailed problem))
       else rethrowIO original
