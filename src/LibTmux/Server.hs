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
-- Cancellation and callback failures keep their original exception class.
-- Use "LibTmux.Recovery" to inspect retained owners after incomplete cleanup.
module LibTmux.Server
  ( -- * Open and observe
    Server, ServerConfig (..), serverConfig, withServer, capture, serverGeneration, serverCapabilities
  , withControl
    -- * Mutation deadlines
  , MutationOptions (..), defaultMutationOptions
    -- * Session, window and pane creation
  , createSession, createSessionWith
  , createWindow, createWindowWith, splitPane, splitPaneWith
    -- * Owned terminal applications
  , withProgram, runProgram
    -- * Rename and title
  , renameSession, renameSessionWith, renameWindow, renameWindowWith, setPaneTitle, setPaneTitleWith
    -- * Environment
  , getEnvironment, setEnvironment, setEnvironmentWith
  , markEnvironmentRemoved, markEnvironmentRemovedWith, unsetEnvironment, unsetEnvironmentWith
    -- * Option and hook stores
  , readOption, setOption, setOptionWith, unsetOption, unsetOptionWith
  , readHook, setHook, setHookWith, unsetHook, unsetHookWith
    -- * Window links, selection and layout
  , linkWindow, linkWindowWith, unlinkWindow, unlinkWindowWith
  , selectWindowLink, selectWindowLinkWith, selectExactPane, selectExactPaneWith
  , NamedLayout (..), selectLayout, selectLayoutWith
    -- * Absolute geometry
  , resizePane, resizePaneWith, resizeWindow, resizeWindowWith
    -- * Remove a target
  , killSession, killSessionWith, killWindow, killWindowWith, killPane, killPaneWith
    -- * Named paste buffers
  , loadBuffer, loadBufferWith, readBuffer, pasteBuffer, pasteBufferWith
    -- * Pane input
  , PaneInput (..), sendKeys, sendKeysWith
    -- * Pane text
  , PaneText, capturePane, paneText
  , PaneWaitOptions (..), defaultPaneWait, PaneMatch (..), PaneWaitResult (..), waitForText
    -- * Shared ownership
  , Runtime, withRuntime, withServerIn
    -- * Operational failures
  , TmuxException (..), tryTmux
  ) where

import Control.Concurrent.STM (atomically, readTVar)
import Control.DeepSeq (force)
import Control.Exception
  ( ExceptionWithContext (..)
  , catchNoPropagate, evaluate, mask, rethrowIO, throwIO, tryWithContext
  )
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.Char (isAlphaNum, isAscii)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Utf8
import Data.Time.Clock (NominalDiffTime)
import Data.Type.Coercion (coerceWith, sym)
import Data.Word (Word32)
import LibTmux.Environment (EnvironmentEntry (..), EnvironmentScope (..), EnvironmentVisibility)
import LibTmux.Id (SessionId)
import LibTmux.Id qualified as Id
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.Buffer qualified as Buffer
import LibTmux.Internal.Capture (CaptureRecovery)
import LibTmux.Internal.Capture qualified as C
import LibTmux.Internal.Control (Control, ControlOptions (..))
import LibTmux.Internal.Control qualified as Control
import LibTmux.Creation qualified as Creation
import LibTmux.Capabilities qualified as Capabilities
import LibTmux.Internal.Creation qualified as Create
import LibTmux.Internal.Command (NamedLayout (..))
import LibTmux.Internal.Command qualified as Command
import LibTmux.Internal.Graph qualified as G
import LibTmux.Internal.Mutation qualified as M
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Program qualified as Program
import LibTmux.Program (Program, ProgramOptions, ProgramResult)
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.Scope (TmuxException (..), operational)
import LibTmux.Internal.Scope qualified as Scope
import LibTmux.Internal.SocketPin qualified as Pin
import LibTmux.Options
  ( HookInfo (..), OptionError (..), OptionInfo (..), OptionKind (..)
  , OptionLookup (..), OptionScope (..), OptionShape (..), OptionTarget (..), OptionValue (..)
  )
import LibTmux.Options qualified as Options
import LibTmux.Pane (PaneCaptureOptions (..), PasteNewlines, defaultPaneCapture)
import LibTmux.Version qualified as Version
import LibTmux.Internal.VersionProbe qualified as VersionProbe
import LibTmux.Value (Resize)
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
-- Use 'tryTmux' to keep the exception context and "LibTmux.Recovery" to
-- inspect its cleanup owners.
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
-- Failed adoption can retain a cleanup owner before a t'Server' exists.
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
-- 'IncompatibleTmuxClientProtocol' means the client could not query this
-- daemon's release; no version is inferred from that protocol refusal.
-- Cleanup never replaces a callback exception. Incomplete cleanup raises
-- 'CleanupFailed' after success, or annotates the original callback failure
-- with a reachable cleanup owner. The daemon stays running.
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
  (_, _, version) <- catchNoPropagate
    (C.captureVersionWith P.defaultHooks runtime handle executable duration) $
    \original@(ExceptionWithContext annotations (problem :: R.ReadError)) ->
      if problem == R.InvalidVersionProbe VersionProbe.IncompatibleClientProtocol
        then rethrowIO (ExceptionWithContext annotations IncompatibleTmuxClientProtocol)
        else rethrowIO original
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

-- | Attach a read-only control client to a session from this Server. Start
-- the callback after tmux acknowledges the selected session. Read bounded
-- notifications through "LibTmux.Control" and make changes through the
-- normal Server operations. Closing the callback retires its own client.
withControl :: Server -> SessionRef -> ControlOptions -> (Control -> IO a) -> IO a
withControl server@(Server _ handle executable duration available) (G.SessionRef generation ident) options action = do
  checkTarget server generation
  either throwIO pure (Capabilities.requireCapability available Capabilities.ControlNotifications)
  let session = Utf8.encodeUtf8 (Id.renderSessionId ident)
      output = if options.includePaneOutput then [] else ["-f", "no-output"]
      args = [executable, "-u", "-N", "-S", Pin.pinPath (R.serverPin handle),
        "-C", "attach-session", "-r", "-E", "-t", session] <> output
      spec = N.spec executable args
  Control.withControlClient (R.serverPool handle) spec duration session options action

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
-- promised. See 'LibTmux.Recovery.creationReceipt' for known IDs after uncertain completion.
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

-- | Look up one name in the selected tmux environment. A removal marker and
-- an empty value are present entries. A missing name returns 'Nothing'. A
-- missing session raises 'EnvironmentReadRejected'. Bytes stay literal.
-- The Server capture deadline covers ordinary and hidden value observations.
getEnvironment :: Server -> EnvironmentScope -> ByteString -> IO (Maybe EnvironmentEntry)
getEnvironment server@(Server runtime handle executable duration _) scope name = operational $ do
  let (generation, target) = environmentTarget server scope
  checkTarget server generation
  (_, _, (visibility, reply)) <- catchNoPropagate
    (C.captureEnvironmentWith runtime handle executable duration target name) $
      \original@(ExceptionWithContext context problem) -> case problem of
        R.InvalidCommandOperands invalid ->
          rethrowIO (ExceptionWithContext context (InvalidConfiguration (Text.pack (show invalid))))
        _ -> rethrowIO original
  case reply of
    Command.ControlDataRejected diagnostic
      | diagnostic == "unknown variable: " <> name <> "\n" -> pure Nothing
      | otherwise -> throwIO (EnvironmentReadRejected diagnostic)
    Command.ControlDataHookFailed diagnostic -> throwIO (EnvironmentReadHookFailed diagnostic)
    Command.ControlDataExceedsLimit -> throwIO (InvalidObservation "environment response exceeded its byte limit")
    Command.ControlData bytes ->
      case Bytes.stripSuffix "\n" bytes of
        Just row | row == "-" <> name -> pure (Just (EnvironmentRemoved visibility))
        Just row | Just value <- Bytes.stripPrefix (name <> "=") row ->
          pure (Just (EnvironmentValue visibility (Bytes.copy value)))
        _ -> throwIO (InvalidObservation "environment reply did not contain the named entry")

-- | Set a literal value with explicit visibility. The name cannot be empty
-- or contain NUL or @=@. Values cannot contain NUL. An empty value is valid.
setEnvironment :: Server -> EnvironmentScope -> ByteString -> EnvironmentVisibility -> ByteString -> IO ()
setEnvironment = setEnvironmentWith defaultMutationOptions

-- | 'setEnvironment' with an explicit deadline.
setEnvironmentWith :: MutationOptions -> Server -> EnvironmentScope -> ByteString
  -> EnvironmentVisibility -> ByteString -> IO ()
setEnvironmentWith options server scope name visibility value =
  changeEnvironment options server scope name (Command.SetVariable visibility value)

-- | Store a removal marker. tmux preserves the visibility of an existing
-- entry and uses visible for a new marker.
markEnvironmentRemoved :: Server -> EnvironmentScope -> ByteString -> IO ()
markEnvironmentRemoved = markEnvironmentRemovedWith defaultMutationOptions

-- | 'markEnvironmentRemoved' with an explicit deadline.
markEnvironmentRemovedWith :: MutationOptions -> Server -> EnvironmentScope -> ByteString -> IO ()
markEnvironmentRemovedWith options server scope name =
  changeEnvironment options server scope name Command.MarkVariableRemoved

-- | Erase an entry from the selected table. Unsetting a session entry lets
-- later processes inherit the global value, when one exists.
unsetEnvironment :: Server -> EnvironmentScope -> ByteString -> IO ()
unsetEnvironment = unsetEnvironmentWith defaultMutationOptions

-- | 'unsetEnvironment' with an explicit deadline.
unsetEnvironmentWith :: MutationOptions -> Server -> EnvironmentScope -> ByteString -> IO ()
unsetEnvironmentWith options server scope name =
  changeEnvironment options server scope name Command.UnsetVariable

changeEnvironment :: MutationOptions -> Server -> EnvironmentScope -> ByteString -> Command.EnvironmentChange -> IO ()
changeEnvironment options server scope name change =
  let (generation, target) = environmentTarget server scope
  in mutate options server generation (Command.ChangeEnvironment target name change)

environmentTarget :: Server -> EnvironmentScope -> (Generation, Maybe SessionId)
environmentTarget server GlobalEnvironment = (serverGeneration server, Nothing)
environmentTarget _ (SessionEnvironment (G.SessionRef generation session)) = (generation, Just session)

-- | Read a scalar option from an explicit store. A missing value is
-- 'Nothing'. A present empty string is a 'StringValue' with zero bytes.
-- Use 'EffectiveOption' to include an inherited value. Replies are
-- bounded to 64 KiB and contain only the primary command's data.
readOption :: Server -> OptionTarget -> OptionLookup -> Text.Text -> IO (Maybe OptionValue)
readOption server target lookupMode name = do
  let (generation, destination, scope) = optionTarget server target
  (kind, choices) <- validateOption server scope name
  value <- readSetting server generation destination name (Command.ReadScalar (lookupMode == EffectiveOption))
  traverse (\bytes -> case Bytes.stripSuffix "\n" bytes >>= decodeOption kind choices of
    Just decoded -> pure decoded
    Nothing -> throwIO (InvalidObservation "option reply disagrees with its catalogue type")) value

-- | Replace one scalar option. Built-in names and types must match the
-- catalogue and selected scope. A user option starts with an at sign, followed
-- by ASCII letters, digits, hyphens, underscores or dots. Use 'readOption'
-- to observe tmux's stored value.
setOption :: Server -> OptionTarget -> Text.Text -> OptionValue -> IO ()
setOption = setOptionWith defaultMutationOptions

-- | 'setOption' with an explicit deadline. Native checks apply to option
-- values such as a key name, colour, numeric range or command.
setOptionWith :: MutationOptions -> Server -> OptionTarget -> Text.Text -> OptionValue -> IO ()
setOptionWith options server target name value = do
  let (generation, destination, scope) = optionTarget server target
      (actual, operand) = encodeOption value
  (expected, choices) <- validateOption server scope name
  unless (actual == expected) (throwIO (InvalidSetting (WrongOptionKind name expected)))
  case value of
    ChoiceValue choice | choice `notElem` choices -> throwIO (InvalidSetting (UnknownOptionChoice name))
    _ -> pure ()
  mutate options server generation (Command.ChangeSetting destination (Utf8.encodeUtf8 name) (Command.SetOptionValue operand))

-- | Remove a local scalar override. For built-ins in a global or server
-- store, tmux restores its default.
unsetOption :: Server -> OptionTarget -> Text.Text -> IO ()
unsetOption = unsetOptionWith defaultMutationOptions

-- | 'unsetOption' with an explicit deadline.
unsetOptionWith :: MutationOptions -> Server -> OptionTarget -> Text.Text -> IO ()
unsetOptionWith options server target name = do
  let (generation, destination, scope) = optionTarget server target
  _ <- validateOption server scope name
  mutate options server generation (Command.ChangeSetting destination (Utf8.encodeUtf8 name) Command.UnsetOptionValue)

-- | Read one built-in event's local hook as tmux serializes it, preserving
-- keys, order and line endings. 'Nothing' means no local hook. The native
-- empty-hook record, when present, contains the event name. The reply is
-- bounded to 64 KiB.
readHook :: Server -> OptionTarget -> Text.Text -> IO (Maybe ByteString)
readHook server target name = do
  let (generation, destination, scope) = optionTarget server target
  validateHook server scope name
  readSetting server generation destination name Command.ReadHookListing

-- | Set one numeric entry of a built-in event. The operand is tmux command
-- source, parsed when the daemon registers it. Other indices stay in place.
setHook :: Server -> OptionTarget -> Text.Text -> Word32 -> ByteString -> IO ()
setHook = setHookWith defaultMutationOptions

-- | 'setHook' with an explicit deadline. Indices range from 0 to
-- 2147483647 across the supported catalogue releases.
setHookWith :: MutationOptions -> Server -> OptionTarget -> Text.Text -> Word32 -> ByteString -> IO ()
setHookWith options server target name index source = do
  let (generation, destination, scope) = optionTarget server target
  validateHook server scope name
  when (index > 2147483647) (throwIO (InvalidSetting HookIndexOutOfRange))
  mutate options server generation (Command.ChangeSetting destination (Utf8.encodeUtf8 name) (Command.SetHookEntry index source))

-- | Remove the local override for an event, including every entry.
-- A local hook can inherit its parent's entries again.
unsetHook :: Server -> OptionTarget -> Text.Text -> IO ()
unsetHook = unsetHookWith defaultMutationOptions

-- | 'unsetHook' with an explicit deadline.
unsetHookWith :: MutationOptions -> Server -> OptionTarget -> Text.Text -> IO ()
unsetHookWith options server target name = do
  let (generation, destination, scope) = optionTarget server target
  validateHook server scope name
  mutate options server generation (Command.ChangeSetting destination (Utf8.encodeUtf8 name) Command.UnsetHookEntry)

optionTarget :: Server -> OptionTarget -> (Generation, Command.OptionDestination, OptionScope)
optionTarget server = \case
  ServerOptions -> global Command.ServerDestination ServerScope
  GlobalSessionOptions -> global Command.GlobalSessionDestination SessionScope
  SessionOptionsAt (G.SessionRef generation ident) -> (generation, Command.SessionDestination ident, SessionScope)
  GlobalWindowOptions -> global Command.GlobalWindowDestination WindowScope
  WindowOptionsAt (G.WindowRef generation ident) -> (generation, Command.WindowDestination ident, WindowScope)
  PaneOptionsAt (G.PaneRef generation ident) -> (generation, Command.PaneDestination ident, PaneScope)
  where
    global destination scope = (serverGeneration server, destination, scope)

validateOption :: Server -> OptionScope -> Text.Text -> IO (OptionKind, [Text.Text])
validateOption server scope name
  | Just suffix <- Text.stripPrefix "@" name = do
      unless (not (Text.null suffix) && Text.all valid suffix)
        (throwIO (InvalidSetting (InvalidUserOptionName name)))
      pure (StringKind, [])
  | otherwise = do
      capabilities <- settingCatalogue server
      info <- maybe (throwIO (InvalidSetting (UnknownOption name))) pure (Options.lookupOption capabilities name)
      validateSettingScope name scope info.optionScopes
      unless (info.optionShape == Scalar) (throwIO (InvalidSetting (ExpectedScalarOption name)))
      pure (info.optionKind, info.optionChoices)
  where
    valid char = isAscii char && (isAlphaNum char || char `elem` ("-_." :: String))

validateHook :: Server -> OptionScope -> Text.Text -> IO ()
validateHook server scope name = do
  capabilities <- settingCatalogue server
  info <- maybe (throwIO (InvalidSetting (UnknownHook name))) pure (Options.lookupHook capabilities name)
  validateSettingScope name scope info.hookScopes

validateSettingScope :: Text.Text -> OptionScope -> [OptionScope] -> IO ()
validateSettingScope name scope allowed =
  unless (scope `elem` allowed) (throwIO (InvalidSetting (WrongSettingScope name scope)))

settingCatalogue :: Server -> IO Capabilities.Capabilities
settingCatalogue server = do
  let capabilities = serverCapabilities server
      actual = Capabilities.daemonVersion capabilities
  unless (either (const False) (actual <=) (Version.parseVersion "3.8"))
    (throwIO (InvalidSetting (UnqualifiedOptionVersion actual)))
  pure capabilities

readSetting :: Server -> Generation -> Command.OptionDestination -> Text.Text
  -> Command.SettingRead -> IO (Maybe ByteString)
readSetting server@(Server runtime handle executable duration _) generation destination name request = operational $ do
  checkTarget server generation
  let nativeName = Utf8.encodeUtf8 name
  reply <- C.captureSettingWith runtime handle executable duration destination nativeName request
  case reply of
    Command.ControlData bytes -> pure (if Bytes.null bytes then Nothing else Just bytes)
    Command.ControlDataExceedsLimit -> throwIO (SettingReadTooLarge Command.settingReadLimit)
    Command.ControlDataHookFailed diagnostic -> throwIO (SettingReadHookFailed diagnostic)
    Command.ControlDataRejected diagnostic
      | "@" `Bytes.isPrefixOf` nativeName && diagnostic == "invalid option: " <> nativeName <> "\n" -> pure Nothing
      | otherwise -> throwIO (SettingReadRejected diagnostic)

encodeOption :: OptionValue -> (OptionKind, ByteString)
encodeOption = \case
  StringValue bytes -> (StringKind, bytes)
  NumberValue number -> (NumberKind, Ascii.pack (show number))
  KeyValue bytes -> (KeyKind, bytes)
  ColourValue bytes -> (ColourKind, bytes)
  FlagValue flag -> (FlagKind, if flag then "on" else "off")
  ChoiceValue choice -> (ChoiceKind, Utf8.encodeUtf8 choice)
  CommandValue bytes -> (CommandKind, bytes)
  StyleValue bytes -> (StyleKind, bytes)
  ColourStringValue bytes -> (ColourStringKind, bytes)

decodeOption :: OptionKind -> [Text.Text] -> ByteString -> Maybe OptionValue
decodeOption kind choices bytes = case kind of
  StringKind -> Just (StringValue bytes)
  NumberKind -> case Ascii.readInteger (Bytes.take 20 bytes) of
    Just (number, "") | Bytes.length bytes <= 20
      , number >= toInteger (minBound :: Int64), number <= toInteger (maxBound :: Int64) ->
          Just (NumberValue (fromInteger number))
    _ -> Nothing
  KeyKind -> Just (KeyValue bytes)
  ColourKind -> Just (ColourValue bytes)
  FlagKind -> case bytes of
    "on" -> Just (FlagValue True)
    "off" -> Just (FlagValue False)
    _ -> Nothing
  ChoiceKind -> ChoiceValue <$> lookup bytes [(Utf8.encodeUtf8 choice, choice) | choice <- choices]
  CommandKind -> Just (CommandValue bytes)
  StyleKind -> Just (StyleValue bytes)
  ColourStringKind -> Just (ColourStringValue bytes)

-- | Link the current occupant of the first slot at the second slot. Both
-- slots belong to this Server generation. The destination must be vacant.
-- Existing links remain and the new link starts unselected.
linkWindow :: Server -> Creation.WindowSlot -> Creation.WindowSlot -> IO ()
linkWindow = linkWindowWith defaultMutationOptions

-- | 'linkWindow' with an explicit deadline. Session groups can propagate a
-- link to their members. Capture the graph again for current indices.
linkWindowWith :: MutationOptions -> Server -> Creation.WindowSlot -> Creation.WindowSlot -> IO ()
linkWindowWith options server (Creation.WindowSlot (G.SessionRef fromGeneration source) sourceIndex)
    (Creation.WindowSlot (G.SessionRef toGeneration destination) destinationIndex) =
  mutateTargets options server [fromGeneration, toGeneration]
    (Command.LinkWindow source sourceIndex destination destinationIndex)

-- | Remove one exact window link. tmux refuses removal of the physical
-- window's last link. Session groups can propagate removal to their members.
unlinkWindow :: Server -> Creation.WindowSlot -> IO ()
unlinkWindow = unlinkWindowWith defaultMutationOptions

-- | 'unlinkWindow' with an explicit deadline.
unlinkWindowWith :: MutationOptions -> Server -> Creation.WindowSlot -> IO ()
unlinkWindowWith options server (Creation.WindowSlot (G.SessionRef generation session) index) =
  mutate options server generation (Command.UnlinkWindow session index)

-- | Select the link at the requested session and index, including one of
-- several links to the same physical window. Observe selection with 'capture'.
selectWindowLink :: Server -> Creation.WindowSlot -> IO ()
selectWindowLink = selectWindowLinkWith defaultMutationOptions

-- | 'selectWindowLink' with an explicit deadline.
selectWindowLinkWith :: MutationOptions -> Server -> Creation.WindowSlot -> IO ()
selectWindowLinkWith options server (Creation.WindowSlot (G.SessionRef generation session) index) =
  mutate options server generation (Command.SelectWindowLink session index)

-- | Select an exact pane through the given window link. tmux rejects a pane
-- that no longer belongs to the link's current window.
selectExactPane :: Server -> Creation.WindowSlot -> PaneRef -> IO ()
selectExactPane = selectExactPaneWith defaultMutationOptions

-- | 'selectExactPane' with an explicit deadline. Both targets belong to the
-- same Server generation.
selectExactPaneWith :: MutationOptions -> Server -> Creation.WindowSlot -> PaneRef -> IO ()
selectExactPaneWith options server (Creation.WindowSlot (G.SessionRef slotGeneration session) index)
    (G.PaneRef generation pane) =
  mutateTargets options server [slotGeneration, generation] (Command.SelectExactPane session index pane)

-- | Apply a named layout to the physical window at the given slot. All links
-- to that window see the resulting layout. tmux can unzoom it.
selectLayout :: Server -> Creation.WindowSlot -> NamedLayout -> IO ()
selectLayout = selectLayoutWith defaultMutationOptions

-- | 'selectLayout' with an explicit deadline. Capture the window again to
-- observe its resulting pane geometry.
selectLayoutWith :: MutationOptions -> Server -> Creation.WindowSlot -> NamedLayout -> IO ()
selectLayoutWith options server (Creation.WindowSlot (G.SessionRef generation session) index) layout =
  mutate options server generation (Command.SelectLayout session index layout)

-- | Request an absolute width, height, or both for this exact physical pane.
-- Build a 'Resize' from checked dimensions. The native layout can clamp sizes
-- or change neighboring panes, and resizing can unzoom its window. The result
-- confirms command processing; use 'capture' for actual geometry. Existing
-- snapshots stay detached. No active-pane lookup or implicit selection occurs.
resizePane :: Server -> PaneRef -> Resize -> IO ()
resizePane = resizePaneWith defaultMutationOptions

-- | 'resizePane' with an explicit 'timeout'. Every axis must be at most 10000
-- cells; the full request is checked before admission, including combined
-- dimensions. Invalid sizes raise 'InvalidMutationArgument' without unzooming
-- or partially resizing. Native errors, cancellation and uncertain completion
-- retain the ordinary 'MutationRecovery' and never cause automatic replay.
resizePaneWith :: MutationOptions -> Server -> PaneRef -> Resize -> IO ()
resizePaneWith options server (G.PaneRef generation ident) size =
  mutate options server generation (Command.ResizePane ident size)

-- | Request an absolute width, height, or both for one physical window across
-- all its links. This sets tmux's window-size option to manual. An omitted
-- axis retains its native extent; layout constraints determine actual cells.
-- 'capture' observes the result separately. No session or active-window lookup
-- chooses a different target.
resizeWindow :: Server -> WindowRef -> Resize -> IO ()
resizeWindow = resizeWindowWith defaultMutationOptions

-- | 'resizeWindow' with one deadline and generation checks before dispatch.
-- All supplied dimensions must fit 1 through 10000 cells. Validation precedes
-- any native effects or manual-size option changes. Missing targets raise
-- 'MutationRejected'; a following hook error can retain an applied resize.
-- Cancellation keeps its exception class and correlated 'MutationRecovery'.
resizeWindowWith :: MutationOptions -> Server -> WindowRef -> Resize -> IO ()
resizeWindowWith options server (G.WindowRef generation ident) size =
  mutate options server generation (Command.ResizeWindow ident size)

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

-- | Load up to 64 KiB of raw bytes into an exact named tmux buffer. NUL
-- and invalid UTF-8 are data. Empty input leaves the existing buffer alone.
loadBuffer :: Server -> ByteString -> ByteString -> IO ()
loadBuffer = loadBufferWith defaultMutationOptions

-- | 'loadBuffer' with an explicit deadline.
loadBufferWith :: MutationOptions -> Server -> ByteString -> ByteString -> IO ()
loadBufferWith options server@(Server runtime handle executable _ _) name bytes = operational $ do
  checkTarget server (serverGeneration server)
  when (Bytes.length bytes > Buffer.byteLimit) (throwIO (BufferTooLarge Buffer.byteLimit))
  duration <- mutationDuration options
  M.performRequests duration runtime handle $ \remaining await ->
    Buffer.withInput bytes $ \file -> do
      left <- remaining
      await (R.mutateWith P.defaultHooks left runtime handle executable (Command.LoadBuffer name file))
        >>= M.checkMutationReply

-- | Read up to 64 KiB of the exact named buffer, preserving trailing line
-- feeds and arbitrary bytes. An oversized buffer raises 'BufferTooLarge'.
-- A missing buffer raises 'MutationRejected'. Hooks do not supply buffer data.
readBuffer :: Server -> ByteString -> IO ByteString
readBuffer server@(Server runtime handle executable duration _) name = operational $ do
  checkTarget server (serverGeneration server)
  M.performRequests duration runtime handle $ \remaining await ->
    R.withReadBudget runtime (fromIntegral (2 * Buffer.byteLimit + 8192)) $ do
      result <- Buffer.readOutput $ \pipe -> do
        left <- remaining
        await (R.mutateWith P.defaultHooks left runtime handle executable (Command.SaveBuffer name pipe))
          >>= M.checkMutationReply
      maybe (throwIO (BufferTooLarge Buffer.byteLimit)) pure result

-- | Paste the current bytes of a named buffer into the exact pane. The
-- newline policy controls line feeds. Observe the pane separately for proof
-- of application input or output.
pasteBuffer :: Server -> PaneRef -> ByteString -> PasteNewlines -> IO ()
pasteBuffer = pasteBufferWith defaultMutationOptions

-- | 'pasteBuffer' with an explicit deadline. Availability of the native raw
-- byte flag comes from the pinned daemon's capabilities.
pasteBufferWith :: MutationOptions -> Server -> PaneRef -> ByteString -> PasteNewlines -> IO ()
pasteBufferWith options server (G.PaneRef generation pane) name newlines =
  let rawFlag = Capabilities.supports (serverCapabilities server) Capabilities.RawBufferPasteFlag
  in mutate options server generation (Command.PasteBuffer pane name newlines rawFlag)

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
-- 'PaneCaptureRejected'. A failed after-hook raises 'PaneCaptureHookFailed'.
-- Earlier captures stay readable.
capturePane :: Server -> PaneRef -> PaneCaptureOptions -> IO PaneText
capturePane server@(Server runtime handle executable duration _) pane@(G.PaneRef generation ident) options =
  operational $ do
    checkTarget server generation
    (_, _, reply) <- paneCaptureErrors options
      (C.capturePaneWith runtime handle executable duration ident options)
    PaneText pane options <$> decodePaneText options reply

paneCaptureErrors :: PaneCaptureOptions -> IO a -> IO a
paneCaptureErrors options action = catchNoPropagate action $ \original@(ExceptionWithContext context problem) ->
  case problem of
    R.InvalidCommandOperands (Command.InvalidOperand field reason) ->
      rethrowIO (ExceptionWithContext context (InvalidConfiguration (field <> ": " <> reason)))
    R.InvalidCommandReply Command.ReplyTooLarge ->
      rethrowIO (ExceptionWithContext context (PaneTextTooLarge options.byteLimit))
    _ -> rethrowIO original

decodePaneText :: PaneCaptureOptions -> Command.ControlDataReply -> IO Text.Text
decodePaneText options = \case
  Command.ControlDataExceedsLimit -> throwIO (PaneTextTooLarge options.byteLimit)
  Command.ControlDataHookFailed diagnostic -> throwIO (PaneCaptureHookFailed diagnostic)
  Command.ControlDataRejected diagnostic -> throwIO (PaneCaptureRejected diagnostic)
  Command.ControlData bytes ->
    either (const (throwIO (InvalidObservation "pane text is not valid UTF-8")))
      pure (Utf8.decodeUtf8' bytes)

-- | Read the captured Unicode text without contacting tmux.
paneText :: PaneText -> Text.Text
paneText (PaneText _ _ text) = text

-- | Presence can match the first capture. Freshness compares observed
-- non-overlapping occurrences against a capture taken before input. Use the
-- same exact pane, row range and rendering in both observations.
data PaneMatch = Presence | FreshSince !PaneText

-- | Configure a text wait on the selected range and rendering.
data PaneWaitOptions = PaneWaitOptions
  { waitTimeout :: !NominalDiffTime -- ^ Whole wait in seconds, positive and at most ten.
  , waitCapture :: !PaneCaptureOptions
  , waitMatch :: !PaneMatch
  }

-- | Wait up to one second for text in the visible, plain screen.
defaultPaneWait :: PaneWaitOptions
defaultPaneWait = PaneWaitOptions 1 defaultPaneCapture Presence

-- | The last complete capture is available on timeout and pane exit, if a
-- capture completed. A deadline inside a native read may retain its owner.
data PaneWaitResult
  = PaneTextMatched !PaneText
  | PaneTextTimedOut !(Maybe PaneText) !(Maybe CaptureRecovery)
  | PaneTextExited !(Maybe PaneText)

-- | Observe a nonempty, case-sensitive substring in an exact pane. The first
-- capture runs immediately. After a nonmatch, check liveness and wait up to
-- 100 ms before the next capture. One deadline covers every request.
--
-- A fresh match requires absence followed by presence or an additional
-- occurrence. Moving a match and repainting identical text provide no new
-- evidence. A match can include terminal echo. Cancellation preserves its
-- exception class and any in-flight 'CaptureRecovery'.
waitForText :: Server -> PaneRef -> PaneWaitOptions -> Text.Text -> IO PaneWaitResult
waitForText server@(Server runtime handle executable _ _) pane@(G.PaneRef generation ident) options needle =
  operational $ do
    checkTarget server generation
    when (Text.null needle) (throwIO (InvalidConfiguration "pane text wait requires nonempty text"))
    duration <- limitedDuration "pane text wait" options.waitTimeout
    let settings = options.waitCapture
        captured = PaneText pane settings
    baseline <- case options.waitMatch of
      Presence -> pure 0
      FreshSince (PaneText other previous contents)
        | other == pane && previous.rows == settings.rows && previous.rendering == settings.rendering ->
            pure (Text.count needle contents)
        | otherwise ->
            throwIO (InvalidConfiguration "baseline requires the same pane, rows and rendering")
    result <- paneCaptureErrors settings $
      C.waitForPaneText runtime handle executable duration ident settings (decodePaneText settings) needle baseline
    pure $ case result of
      C.TextMatched matched -> PaneTextMatched (captured matched)
      C.TextPaneEnded latest -> PaneTextExited (captured <$> latest)
      C.TextWaitExpired latest recovery -> PaneTextTimedOut (captured <$> latest) recovery

mutate :: MutationOptions -> Server -> Generation -> Command.Mutation -> IO ()
mutate options server generation = mutateTargets options server [generation]

mutateTargets :: MutationOptions -> Server -> [Generation] -> Command.Mutation -> IO ()
mutateTargets options server@(Server runtime handle executable _ _) generations command = operational $ do
  duration <- mutationDuration options
  mapM_ (checkTarget server) generations
  M.performMutation P.defaultHooks duration runtime handle executable command

checkTarget :: Server -> Generation -> IO ()
checkTarget server@(Server _ handle _ _ _) generation = do
  closed <- atomically (readTVar (R.serverPool handle).closing)
  when closed (throwIO ServerClosed)
  unless (generation == serverGeneration server)
    (throwIO (InvalidTarget "reference belongs to a different Server generation or an offline fixture"))

mutationDuration :: MutationOptions -> IO Int
mutationDuration options = limitedDuration "mutation" options.timeout

limitedDuration :: Text.Text -> NominalDiffTime -> IO Int
limitedDuration operation duration = do
  let seconds = toRational duration
  when (seconds <= 0 || seconds > 10)
    (throwIO (InvalidConfiguration (operation <> " timeout must be positive and at most ten seconds")))
  pure (fromInteger (ceiling (seconds * 1000000)))

-- | Catch library failures with their exception context. Retain this value
-- when handling an error so cleanup and operation owners stay reachable.
-- Application exceptions and asynchronous cancellation propagate.
tryTmux :: IO a -> IO (Either (ExceptionWithContext TmuxException) a)
tryTmux = tryWithContext

resolveExecutable :: PosixPath -> IO ByteString
resolveExecutable executable = case Platform.coercionToPlatformTypes of
  Left _ -> throwIO (InvalidConfiguration "this package requires Linux POSIX paths")
  Right (_, proof) -> do
    selected <- Directory.findExecutable (coerceWith (sym proof) executable)
    path <- maybe (throwIO (InvalidConfiguration "tmux executable was not found")) Directory.makeAbsolute selected
    pure (posixBytes (coerceWith proof path))

posixBytes :: PosixPath -> ByteString
posixBytes = Bytes.pack . map (fromIntegral . fromEnum . Os.toChar) . Os.unpack
