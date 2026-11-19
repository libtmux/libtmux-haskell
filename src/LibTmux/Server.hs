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
-- 'createSession', 'createWindow' and 'splitPane' return historical identities.
-- 'renameSession',
-- 'renameWindow' and 'setPaneTitle' update generation-bound targets.
-- 'killSession', 'killWindow' and 'killPane' remove those targets.
-- Capture again to observe their effects.
--
-- Operational failures use t'TmuxException'. 'tryTmux' catches that type only.
-- Cancellation retains its original exception class. If bounded cleanup
-- cannot finish, 'cleanupRecoveries' retrieves the owning recovery scope
-- from the exception context. A failed callback remains the primary failure.
module LibTmux.Server
  ( -- * Open and observe
    Server, ServerConfig (..), serverConfig, withServer, capture, serverGeneration, serverCapabilities
    -- * Mutation deadlines
  , MutationOptions (..), defaultMutationOptions
    -- * Session, window and pane creation
  , createSession, createSessionWith
  , createWindow, createWindowWith, splitPane, splitPaneWith
    -- * Owned terminal applications
  , withProgram, runProgram
    -- * Rename and title
  , renameSession, renameSessionWith, renameWindow, renameWindowWith, setPaneTitle, setPaneTitleWith
    -- * Remove a target
  , killSession, killSessionWith, killWindow, killWindowWith, killPane, killPaneWith
    -- * Pane input
  , PaneInput (..), sendKeys, sendKeysWith
    -- * Pane text
  , PaneText, capturePane, paneText
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
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (isJust)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Utf8
import Data.Time.Clock (NominalDiffTime)
import Data.Type.Coercion (coerceWith, sym)
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.Capture (CaptureRecovery)
import LibTmux.Internal.Capture qualified as C
import LibTmux.Creation qualified as Creation
import LibTmux.Capabilities qualified as Capabilities
import LibTmux.Internal.Creation (CreationRecovery)
import LibTmux.Internal.Creation qualified as Create
import LibTmux.Internal.Command qualified as Command
import LibTmux.Internal.Graph qualified as G
import LibTmux.Internal.Mutation qualified as M
import LibTmux.Internal.Mutation (MutationRecovery)
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Native qualified as N
import LibTmux.Internal.Program qualified as Program
import LibTmux.Program (Program, ProgramOptions, ProgramResult)
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
import LibTmux.Pane (PaneCaptureOptions (..))
import LibTmux.Version qualified as Version
import LibTmux.Snapshot (Generation, Snapshot, SessionRef, WindowRef, PaneRef, TmuxText)
import System.Directory.OsPath qualified as Directory
import System.OsPath.Posix (PosixPath)
import System.OsPath.Posix qualified as Path
import System.OsString qualified as Platform
import System.OsString.Posix qualified as Os

-- | One pinned endpoint and connection generation.
-- Retaining this value after 'withServer' or 'withServerIn' keeps no admission open.
data Server = Server !R.Runtime !R.ServerHandle !ByteString !Int !Capabilities.Capabilities

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
-- Before the callback, opening refuses a daemon release older than 3.3a or an
-- unrecognized version reply.
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
    version <- operational (qualifyVersion runtime handle executable duration)
    action (Server runtime handle executable duration (Capabilities.capabilitiesFor version))

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

-- | Pin the endpoint, check the daemon release against the 3.3a admission
-- minimum, run the callback, then perform bounded owned cleanup. Version
-- observation runs no command hook. A release older than 3.3a or an
-- unrecognized reply fails before entering the callback.
-- Cleanup never replaces a callback exception. Incomplete cleanup raises
-- 'CleanupFailed' after success, or annotates the original callback failure
-- with a reachable t'CleanupRecovery'. No daemon shutdown is requested.
withServer :: ServerConfig -> (Server -> IO a) -> IO a
withServer config action = do
  (executable, duration) <- checkedConfiguration config
  runtime <- R.newRuntime P.normalFork
  Scope.runScope runtime $ do
    handle <- operational (R.adopt runtime (posixBytes config.socketPath) (posixBytes config.pinDirectory))
    version <- operational (qualifyVersion runtime handle executable duration)
    action (Server runtime handle executable duration (Capabilities.capabilitiesFor version))

qualifyVersion :: R.Runtime -> R.ServerHandle -> ByteString -> Int -> IO Version.TmuxVersion
qualifyVersion runtime handle executable duration = do
  (_, _, version) <- C.captureVersionWith P.defaultHooks runtime handle executable duration
  either (throwIO . UnsupportedTmuxVersion) pure (Version.requireSupported version)

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
capture (Server runtime handle executable duration _) = operational $ do
  closed <- atomically (readTVar (R.serverPool handle).closing)
  when closed (throwIO ServerClosed)
  (started, finished, decoded) <- C.captureSnapshot runtime handle executable duration
  stamped <- either (throwIO . InvalidObservation . Text.pack . show) pure
    (G.stampSnapshot started finished decoded)
  evaluate (force stamped)

-- | The handle's opaque generation, available without contacting tmux.
serverGeneration :: Server -> Generation
serverGeneration (Server _ handle _ _ _) = Pin.pinGeneration (R.serverPin handle)

-- | Capabilities evaluated against the daemon release observed during endpoint
-- adoption. This pure lookup performs no operation and never substitutes
-- the client executable's release. A dead pinned endpoint cannot enable a
-- replacement daemon; subsequent operations fail through that same pin.
serverCapabilities :: Server -> Capabilities.Capabilities
serverCapabilities (Server _ _ _ _ available) = available

-- | Run a literal executable/argv application in a new owned session on this
-- daemon, then terminate its group and remove its resources. The callback may
-- send input and observe bounded rendered output. Cancellation of this owning
-- scope initiates bounded cleanup; cancellation of 'LibTmux.Program.waitProgram'
-- alone does not. Async exceptions retain their original class.
--
-- tmux 3.8 and Linux 6.9 pidfd process-group signaling are required and checked
-- before application effects. A separately owned pin and bounded native Runtime
-- keep t'LibTmux.Program.ProgramRecovery' usable after this Server closes. The
-- borrowed daemon and its other sessions remain running. See "LibTmux.Program"
-- for the initial contract and explicit limits.
withProgram :: Server -> ProgramOptions -> (Program -> IO a) -> IO a
withProgram (Server _ handle executable _ available) =
  Program.withOwnedProgram handle executable available

-- | Wait for a terminal application, capture its bounded final rendered output,
-- and clean up before returning a detached result. Cancellation initiates bounded
-- cleanup. Set 'LibTmux.Program.executionTimeout' for an owning setup/observation
-- deadline; cleanup has a separate budget. Without it there is no total limit.
runProgram :: Server -> ProgramOptions -> IO ProgramResult
runProgram (Server _ handle executable _ available) =
  Program.runOwnedProgram handle executable available

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
-- Oversized options raise 'InvalidMutationArgument' before admission. A caller
-- environment beyond the native launch budget raises 'InvalidConfiguration'
-- without admitting an operation.
createSessionWith :: MutationOptions -> Server -> Creation.SessionOptions -> IO Creation.CreatedSession
createSessionWith options server settings = create options server [] (Command.NewSession settings)

-- | Create a window at an explicit session placement. The default options
-- request no selection and refuse an occupied slot. tmux prints the actual
-- session, index, window and pane before after-hooks. Capture again to observe
-- geometry and liveness; hooks may already have removed the new entities.
createWindow :: Server -> Creation.WindowPlacement -> Creation.WindowOptions -> IO Creation.CreatedWindow
createWindow = createWindowWith defaultMutationOptions

-- | 'createWindow' with one deadline covering caller context, admission and
-- completion. Generation checks precede dispatch. Insertion and replacement
-- can affect existing links before a later failure; no rollback or replay is
-- promised. See 'creationReceipt' for known IDs after uncertain completion.
createWindowWith :: MutationOptions -> Server -> Creation.WindowPlacement -> Creation.WindowOptions -> IO Creation.CreatedWindow
createWindowWith options server placement settings =
  let (generation, target) = lower placement
  in create options server [generation] (Command.NewWindow target settings)
  where
    lower (Creation.NextFree (G.SessionRef generation session)) = (generation, Command.NextFree session)
    lower (Creation.At slot) = at Command.At slot
    lower (Creation.Before slot) = at Command.Before slot
    lower (Creation.After slot) = at Command.After slot
    at constructor (Creation.WindowSlot (G.SessionRef generation session) index) =
      (generation, constructor session index)

-- | Split one explicit pane in an exact session/index link. The slot must
-- contain that pane's physical window when tmux executes the command; an
-- inactive pane stays the target. No ambient active-pane lookup occurs.
-- The result records the new pane and its historical execution context.
splitPane :: Server -> Creation.WindowSlot -> PaneRef -> Creation.SplitOptions -> IO Creation.CreatedPane
splitPane = splitPaneWith defaultMutationOptions

-- | 'splitPane' with one deadline. Both references must belong to this Server
-- generation. Missing panes and mismatched link occupants are native
-- 'MutationRejected' outcomes. Invalid sizes fail before admission. Geometry
-- is a request subject to native constraints; observe it through 'capture'.
-- Cancellation, hook errors and timeout retain the common 'CreationRecovery'.
splitPaneWith :: MutationOptions -> Server -> Creation.WindowSlot -> PaneRef -> Creation.SplitOptions -> IO Creation.CreatedPane
splitPaneWith options server (Creation.WindowSlot (G.SessionRef slotGeneration session) index)
    (G.PaneRef generation pane) settings =
  create options server [slotGeneration, generation] (Command.SplitPane session index pane settings)

create :: MutationOptions -> Server -> [Generation] -> Command.CreationCommand -> IO Creation.CreatedEntities
create options server@(Server runtime handle executable _ _) generations command = operational $ do
  duration <- mutationDuration options
  closed <- atomically (readTVar (R.serverPool handle).closing)
  when closed (throwIO ServerClosed)
  unless (all (== serverGeneration server) generations)
    (throwIO (InvalidTarget "reference belongs to a different Server generation or an offline fixture"))
  Create.performCommandCreation P.defaultHooks duration runtime handle executable command

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

-- | Remove a session from this Server generation. A window linked from
-- another session survives. Use 'killSessionWith' to choose a deadline.
killSession :: Server -> SessionRef -> IO ()
killSession = killSessionWith defaultMutationOptions

-- | 'killSession' with an explicit deadline. tmux may exit when its last
-- session closes. Observe the daemon separately.
killSessionWith :: MutationOptions -> Server -> SessionRef -> IO ()
killSessionWith options server (G.SessionRef generation ident) =
  mutate options server generation (Command.KillSession ident)

-- | Remove a physical window across all its links. tmux closes sessions
-- left without windows. Use 'killWindowWith' to choose a deadline.
killWindow :: Server -> WindowRef -> IO ()
killWindow = killWindowWith defaultMutationOptions

-- | 'killWindow' with an explicit deadline. Missing windows raise
-- 'MutationRejected'. Foreign and offline references raise 'InvalidTarget'.
killWindowWith :: MutationOptions -> Server -> WindowRef -> IO ()
killWindowWith options server (G.WindowRef generation ident) =
  mutate options server generation (Command.KillWindow ident)

-- | Remove one physical pane. Removing the last pane also closes its
-- window. Use 'killPaneWith' to choose a deadline.
killPane :: Server -> PaneRef -> IO ()
killPane = killPaneWith defaultMutationOptions

-- | 'killPane' with an explicit deadline. Success confirms the native
-- removal command. Observe descendant process exit separately.
killPaneWith :: MutationOptions -> Server -> PaneRef -> IO ()
killPaneWith options server (G.PaneRef generation ident) =
  mutate options server generation (Command.KillPane ident)

-- | Input to an exact pane. Literal text bypasses key-name lookup.
-- 'NamedKeys' accepts tmux key names such as @Enter@ or @C-c@ in order.
-- The type omits a Show instance so logging does not disclose pane input.
data PaneInput
  = LiteralText !Text.Text
  | NamedKeys !(NonEmpty Text.Text)
  deriving stock (Eq)

-- | Send literal text or named keys to a pane from this Server generation.
-- The command never appends Enter. Success confirms tmux processed the
-- request. Application response can be observed separately.
sendKeys :: Server -> PaneRef -> PaneInput -> IO ()
sendKeys = sendKeysWith defaultMutationOptions

-- | 'sendKeys' with one deadline for validation, submission and completion.
-- tmux validates every key name before input is sent. An invalid name raises
-- 'InvalidMutationArgument' without typing any part of the sequence.
sendKeysWith :: MutationOptions -> Server -> PaneRef -> PaneInput -> IO ()
sendKeysWith options server (G.PaneRef generation ident) input =
  mutate options server generation $ case input of
    LiteralText text -> Command.SendPaneText ident text
    NamedKeys names -> Command.SendPaneKeys ident names

-- | A detached pane observation. It retains its target, range and rendering
-- with the text. Use 'paneText' to read the content.
data PaneText = PaneText !PaneRef !PaneCaptureOptions !Text.Text
  deriving stock (Eq)

-- | Read the pane's visible rows or an explicit range from the pinned daemon.
-- Blank rows and line endings are retained. ANSI rendering uses tmux's
-- escape sequences. The Server capture deadline covers the request.
-- Oversized text raises 'PaneTextTooLarge'. A missing target raises
-- 'PaneCaptureRejected'. Earlier captures stay readable.
capturePane :: Server -> PaneRef -> PaneCaptureOptions -> IO PaneText
capturePane server@(Server runtime handle executable duration _) pane@(G.PaneRef generation ident) options =
  operational $ do
    checkTarget server generation
    let acquire = C.capturePaneWith runtime handle executable duration ident options
    (_, _, reply) <- catchNoPropagate acquire $ \original@(ExceptionWithContext context problem) ->
      case problem of
        R.InvalidCommandOperands (Command.InvalidOperand field reason) ->
          rethrowIO (ExceptionWithContext context (InvalidConfiguration (field <> ": " <> reason)))
        R.InvalidCommandReply Command.ReplyTooLarge ->
          rethrowIO (ExceptionWithContext context (PaneTextTooLarge options.byteLimit))
        _ -> rethrowIO original
    case reply of
      Command.CaptureExceedsLimit -> throwIO (PaneTextTooLarge options.byteLimit)
      Command.CaptureRejected diagnostic -> throwIO (PaneCaptureRejected diagnostic)
      Command.CapturedPaneText bytes ->
        either (const (throwIO (InvalidObservation "pane text is not valid UTF-8")))
          (pure . PaneText pane options) (Utf8.decodeUtf8' bytes)

-- | Read the captured Unicode text without contacting tmux.
paneText :: PaneText -> Text.Text
paneText (PaneText _ _ text) = text

mutate :: MutationOptions -> Server -> Generation -> Command.Mutation -> IO ()
mutate options server@(Server runtime handle executable _ _) generation command = operational $ do
  duration <- mutationDuration options
  checkTarget server generation
  M.performMutation P.defaultHooks duration runtime handle executable command

checkTarget :: Server -> Generation -> IO ()
checkTarget server@(Server _ handle _ _ _) generation = do
  closed <- atomically (readTVar (R.serverPool handle).closing)
  when closed (throwIO ServerClosed)
  unless (generation == serverGeneration server)
    (throwIO (InvalidTarget "reference belongs to a different Server generation or an offline fixture"))

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
-- no entity was created; unread or incomplete evidence cannot supply IDs.
creationReceipt :: CreationRecovery -> IO (Maybe Creation.CreatedEntities)
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
