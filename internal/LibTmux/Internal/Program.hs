-- | Application lifetime over the native Runtime. A separate pin and Runtime
-- keep incomplete cleanup usable after the borrowing Server scope has closed.
module LibTmux.Internal.Program
  ( Program, ProgramOptions (..), programOptions
  , ProgramExit (..), StartFailure (..), StartPhase (..)
  , ProgramScreen (..), ProgramResult (..), ProgramError (..)
  , ProgramRecovery, ProgramCleanupStatus (..), programRecoveries, programCleanupFailure
  , inspectProgramCleanup, resumeProgramCleanup
  , withOwnedProgram, runOwnedProgram
  , sendProgramInput, readProgramScreen, waitProgram, waitProgramFor, terminateProgram
  ) where

import Control.Concurrent (yield)
import Control.Concurrent.Async (race)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception hiding (handle)
import Control.Exception.Annotation (ExceptionAnnotation)
import Control.Exception.Context (ExceptionContext)
import Control.Exception.Context qualified as Context
import Control.Monad (forM_, unless, void, when)
import Data.Bits ((.&.), shiftR)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text.Encoding qualified as Utf8
import Data.Time.Clock (NominalDiffTime)
import Foreign.C.Error (eSRCH)
import Foreign.C.Types (CInt)
import GHC.Conc (threadWaitRead)
import LibTmux.Capabilities qualified as Cap
import LibTmux.Creation qualified as Creation
import LibTmux.Id qualified as Id
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.Command qualified as C
import LibTmux.Internal.Creation qualified as Create
import LibTmux.Internal.Entropy qualified as Entropy
import LibTmux.Internal.Graph qualified as G
import LibTmux.Internal.Mutation qualified as M
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Native qualified as N
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.Scope (TmuxException (..))
import LibTmux.Internal.SocketPin qualified as Pin
import LibTmux.Value qualified as Value
import System.Directory qualified as Directory
import System.FilePath ((</>), takeDirectory)
import System.IO (IOMode (ReadMode), hClose, hFileSize, openBinaryTempFile, withBinaryFile)
import System.IO.Error (isDoesNotExistError)
import System.OsPath.Posix (PosixPath)
import System.OsString.Posix (PosixString)
import System.OsString.Posix qualified as Os
import System.Posix.Directory.ByteString qualified as PosixDirectory
import System.Posix.Files.ByteString qualified as File
import System.Posix.IO.ByteString qualified as Posix
import System.Posix.Temp (mkdtemp)
import System.Posix.Types (Fd (..))
import System.Timeout (timeout)

-- | A literal executable and its arguments. The record has no Show instance:
-- command and environment values may contain credentials. The working
-- directory defaults to the caller's directory; environment values override
-- the daemon's inherited application environment. Start from 'programOptions'.
data ProgramOptions = ProgramOptions
  { executable :: !PosixString -- ^ Nonempty executable, resolved on the application's PATH when relative.
  , arguments :: ![PosixString] -- ^ Literal non-NUL bytes; an empty list is valid.
  , bootstrapShell :: !PosixPath -- ^ Bash with dynamic descriptors and timed reads; default @\/bin\/bash@. Checked before application creation.
  , workingDirectory :: !(Maybe PosixPath) -- ^ Strict cwd; Nothing selects the caller's current directory.
  , environment :: ![(PosixString, PosixString)] -- ^ Application overrides. Shell identifiers and reserved names are validated before launch.
  , columns :: !Int -- ^ 1 to 500 cells; default 80.
  , rows :: !Int -- ^ 1 to 200 cells; default 24.
  , historyLines :: !Int -- ^ 0 to 10000 lines, with at most one million cells; default 1000.
  , outputLimit :: !Int -- ^ Returned rendered bytes, 1 to 1 MiB; default 65536.
  , commandTimeout :: !NominalDiffTime -- ^ Each native command, positive and at most ten seconds; default one.
  , executionTimeout :: !(Maybe NominalDiffTime) -- ^ Owning setup/callback deadline, with a separate cleanup budget. Nothing imposes no overall deadline.
  }

-- | Default terminal, bounded history and output, with a literal argv tail.
-- An empty tail executes a zero-argument application without tmux shell mode.
programOptions :: PosixString -> [PosixString] -> ProgramOptions
programOptions file args = ProgramOptions file args (Os.fromBytestring "/bin/bash") Nothing [] 80 24 1000 65536 1 Nothing

-- | The pane's actual process outcome. A signal is never encoded as 128+signal.
-- Successful creation and bootstrap release do not establish successful exec.
data ProgramExit
  = ProgramExited !Int -- ^ The real leader exit code, from 0 through 255.
  | ProgramSignalled !Text -- ^ Native tmux signal name or decimal spelling.
  | ProgramStartFailed !StartFailure -- ^ Bootstrap or strict application setup failed before exec.
  deriving stock (Eq, Show)

-- | Setup failed before replacing the bootstrap with the requested executable.
data StartFailure = StartFailure !StartPhase !Int
  deriving stock (Eq, Show)

-- | Strict application setup, independent of tmux's cwd fallback.
data StartPhase = Bootstrap | WorkingDirectory | Environment | Executable
  deriving stock (Eq, Show)

-- | A rendered terminal snapshot, including retained history. This is not a
-- byte stream or a separation of stdout and stderr. Newlines and terminal
-- editing follow capture-pane. Byte omission is exact for this snapshot;
-- history omission is reported separately.
data ProgramScreen = ProgramScreen
  { screenBytes :: !ByteString -- ^ At most outputLimit bytes; clipping may split UTF-8.
  , omittedBytes :: !Integer -- ^ Exact bytes clipped from this captured snapshot.
  , historyTruncated :: !Bool -- ^ Earlier output may have exceeded retained history.
  }
  deriving stock (Eq, Show)

-- | Detached final output and process status, usable after all scopes close.
data ProgramResult = ProgramResult
  { programExit :: !ProgramExit
  , programOutput :: !ProgramScreen
  }
  deriving stock (Eq, Show)

-- | Program-specific failures. Existing native command failures also retain
-- their ordinary correlated recovery. Async exceptions keep their class.
data ProgramError
  = InvalidProgramOptions !Text -- ^ Invalid argv, environment, host-shell selection or bounds; no application was created.
  | ProgramClosed -- ^ The interactive owning scope has begun cleanup.
  | ProgramObservationLost !Text -- ^ Daemon, pane generation or required exit evidence was lost.
  | ProgramCleanupIncomplete -- ^ Cleanup has not proved all owned obligations retired.
  | ProgramHostUnsupported !Int -- ^ Host pidfd process-group support probe failed, with its errno.
  | ProgramBootstrapUnavailable -- ^ The selected Bash path cannot provide dynamic descriptors, timed reads and descriptor closure.
  | ProgramTimedOut -- ^ The owning execution deadline elapsed; cleanup was initiated.
  deriving stock (Eq, Show)
instance Exception ProgramError

data Observer = Observer
  { ticket :: !P.Ticket, clientName :: !ByteString, lease :: !B.ByteLease }

data PendingObserver = PendingObserver !P.Ticket !B.ByteLease

-- | An interactive owner, valid only inside its withProgram callback. The
-- borrowed Server may close independently; incomplete cleanup retains its own
-- pin and Runtime through t'ProgramRecovery'.
data Program = Program
  { runtime :: !R.Runtime
  , backend :: !(IORef (Maybe R.ServerHandle))
  , clientExecutable :: !ByteString
  , available :: !Cap.Capabilities
  , settings :: !ProgramOptions
  , duration :: !Int
  , token :: !ByteString
  , directory :: !(IORef (Maybe FilePath))
  , errorFile :: !(IORef (Maybe FilePath))
  , acceptedFile :: !(IORef (Maybe FilePath))
  , fifo :: !(IORef (Maybe FilePath))
  , writer :: !(IORef (Maybe Fd))
  , watch :: !(IORef (Maybe CInt))
  , daemon :: !(IORef (Maybe CInt))
  , candidate :: !(IORef (Maybe (CInt, Integer)))
  , successor :: !(IORef (Maybe Observer))
  , generation :: !(TVar (Maybe Observer))
  , handoff :: !(TVar Bool)
  , observers :: !(TVar [PendingObserver])
  , released :: !(IORef Bool)
  , files :: !(IORef [(FilePath, Integer, Integer)])
  , created :: !(IORef (Maybe G.CreatedSession))
  , group :: !(IORef (Maybe CInt))
  , processId :: !(IORef (Maybe Integer))
  , eventWaiter :: !(TVar (Maybe P.Ticket))
  , exitResult :: !(TMVar ProgramExit)
  , buffers :: !(IORef [ByteString])
  , creations :: !(IORef [Create.CreationRecovery])
  , mutations :: !(IORef [M.MutationRecovery])
  , gate :: !(MVar ())
  , closed :: !(TVar Bool)
  , retired :: !(IORef Bool)
  }

-- | Reachable cleanup ownership, including a live pin, native Runtime and
-- identity-bound application group. Resume does not run the application again.
data ProgramRecovery = ProgramRecovery !Program !(Maybe SomeException)
instance Show ProgramRecovery where show _ = "ProgramRecovery"
instance ExceptionAnnotation ProgramRecovery

-- | Nonblocking cleanup metadata, without application arguments or output.
data ProgramCleanupStatus = ProgramCleanupStatus
  { resourcesRetired :: !Bool -- ^ Application group, remote resources and private files have retired.
  , nativeRetired :: !Bool -- ^ No native command, cleanup worker or unresolved operation remains.
  , groupDescriptorOwned :: !Bool -- ^ A retained application-group pidfd still needs retirement.
  }
  deriving stock (Eq, Show)

-- | Retrieve owners from an exception caught with its exception context.
programRecoveries :: ExceptionContext -> [ProgramRecovery]
programRecoveries = Context.getExceptionAnnotations

-- | The failure from the cleanup attempt that attached this owner. The
-- original callback exception remains the thrown exception.
programCleanupFailure :: ProgramRecovery -> Maybe SomeException
programCleanupFailure (ProgramRecovery _ problem) = problem

-- | Inspect local ownership without contacting tmux or waiting.
inspectProgramCleanup :: ProgramRecovery -> IO ProgramCleanupStatus
inspectProgramCleanup (ProgramRecovery program _) = do
  resourcesRetired <- readIORef program.retired
  report <- atomically (R.inspect program.runtime)
  groupDescriptorOwned <- maybe False (const True) <$> readIORef program.group
  pure ProgramCleanupStatus {resourcesRetired, nativeRetired = nativeComplete report, groupDescriptorOwned}

-- | Retry cleanup through its retained pin, including after the borrowing
-- Server scope ends. Application launch and input are never repeated.
resumeProgramCleanup :: ProgramRecovery -> IO ()
resumeProgramCleanup recovery@(ProgramRecovery program _) =
  retaining recovery (cleanup program)

withOwnedProgram
  :: R.ServerHandle -> ByteString -> Cap.Capabilities -> ProgramOptions
  -> (Program -> IO a) -> IO a
withOwnedProgram source executable available options action = mask $ \restore -> do
  duration <- either (throwIO . InvalidProgramOptions) pure (validateOptions options)
  either throwIO pure (Cap.requireCapability available Cap.ManagedPrograms)
  atomically (readTVar (R.serverPool source).closing) >>= flip when (throwIO ProgramClosed)
  support <- N.groupSignalSupport
  when (support /= 0) (throwIO (ProgramHostUnsupported (fromIntegral support)))
  runtime <- R.newRuntime P.normalFork
  token <- hexToken <$> Entropy.freshToken32
  backend <- newIORef Nothing
  directory <- newIORef Nothing
  errorFile <- newIORef Nothing
  acceptedFile <- newIORef Nothing
  fifo <- newIORef Nothing
  writer <- newIORef Nothing
  watch <- newIORef Nothing
  daemon <- newIORef Nothing
  candidate <- newIORef Nothing
  successor <- newIORef Nothing
  generation <- newTVarIO Nothing
  handoff <- newTVarIO False
  observers <- newTVarIO []
  released <- newIORef False
  files <- newIORef []
  created <- newIORef Nothing
  group <- newIORef Nothing
  processId <- newIORef Nothing
  eventWaiter <- newTVarIO Nothing
  exitResult <- newEmptyTMVarIO
  buffers <- newIORef []
  creations <- newIORef []
  mutations <- newIORef []
  gate <- newMVar ()
  closed <- newTVarIO False
  retired <- newIORef False
  let program = Program {runtime, backend, clientExecutable = executable, available,
        settings = options, duration, token, directory, errorFile, acceptedFile,
        fifo, writer, watch, daemon, candidate, successor, generation, handoff, observers,
        released, files, created, group, processId, eventWaiter, exitResult, buffers,
        creations, mutations, gate, closed, retired}
      acquire = do
        let socket = Pin.pinPath (R.serverPin source)
            parent = Ascii.pack (takeDirectory (takeDirectory (Ascii.unpack socket)))
        mask_ $ R.adopt runtime socket parent >>= writeIORef backend . Just
        selected <- requireBackend program
        pid <- tracked program $ M.performRequest duration runtime selected
          (\remaining -> remaining >>= \left -> R.readServerPidWith P.defaultHooks left runtime selected executable R.ScalarRead) pure
        mask_ $ N.daemonWatch (Pin.pinPath (R.serverPin selected)) pid >>= writeIORef daemon . Just
        mask_ $ mkdtemp "/tmp/libtmux-haskell-program-" >>= writeIORef directory . Just
        setup program
        action program
  body <- tryWithContext @SomeException $ restore $ case options.executionTimeout of
    Nothing -> acquire
    Just seconds -> timeout (timerMicros seconds) acquire >>= maybe (throwIO ProgramTimedOut) pure
  release <- tryWithContext @SomeException (cleanup program)
  case release of
    Right () -> either rethrowIO pure body
    Left problem@(ExceptionWithContext _ cause) -> case body of
      Left primary -> rethrowIO (annotate (ProgramRecovery program (Just cause)) primary)
      Right _ -> rethrowIO (annotate (ProgramRecovery program (Just cause)) problem)

runOwnedProgram :: R.ServerHandle -> ByteString -> Cap.Capabilities -> ProgramOptions -> IO ProgramResult
runOwnedProgram source executable available options =
  withOwnedProgram source executable available options $ \program -> do
    programExit <- waitProgram program
    programOutput <- readProgramScreen program
    pure ProgramResult {programExit, programOutput}

validateOptions :: ProgramOptions -> Either Text Int
validateOptions options = do
  let raw = osBytes options.executable : map osBytes (take 4097 options.arguments)
        <> concatMap (\(key, value) -> [osBytes key, osBytes value]) (take 4097 options.environment)
        <> maybe [] (pure . osBytes) options.workingDirectory
  when (Os.null options.executable) (Left "executable is empty")
  let shell = osBytes options.bootstrapShell
  when (not ("/" `Bytes.isPrefixOf` shell) || Bytes.elem 0 shell || Bytes.length shell > 4096)
    (Left "bootstrapShell must be an absolute non-NUL path of at most 4096 bytes")
  when (length (take 4097 options.arguments) > 4096 || length (take 4097 options.environment) > 4096)
    (Left "argv or environment exceeds 4096 entries")
  when (any (Bytes.elem 0) raw) (Left "argv, environment or cwd contains NUL")
  when (sum (map ((+ 1) . toInteger . Bytes.length) raw) > 8192)
    (Left "argv, environment and cwd exceed 8192 bytes")
  forM_ options.environment $ \(key, _) -> when (Os.null key || Bytes.elem 61 (osBytes key))
    (Left "environment variable name is empty or contains equals")
  forM_ options.environment $ \(key, _) -> do
    let name = osBytes key
        letter byte = byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122 || byte == 95
    unless (maybe False (letter . fst) (Bytes.uncons name)
      && Bytes.all (\byte -> letter byte || byte >= 48 && byte <= 57) name)
      (Left "environment names must be ASCII shell identifiers")
    when ("__libtmux_" `Bytes.isPrefixOf` name || name `elem`
      ["LIBTMUX_PROGRAM_TOKEN", "_", "SHLVL", "POSIXLY_CORRECT", "BASH_COMPAT"])
      (Left "environment name is reserved by the bootstrap")
  when (options.columns < 1 || options.columns > 500 || options.rows < 1 || options.rows > 200)
    (Left "terminal geometry exceeds 500 by 200 cells or is empty")
  when (options.historyLines < 0 || options.historyLines > 10000
      || toInteger options.columns * toInteger (options.rows + options.historyLines) > 1000000)
    (Left "terminal history exceeds one million cells or 10000 lines")
  when (options.outputLimit < 1 || options.outputLimit > 1048576)
    (Left "outputLimit must be between one byte and one MiB")
  let seconds = toRational options.commandTimeout
  when (seconds <= 0 || seconds > 10) (Left "commandTimeout must be positive and at most ten seconds")
  forM_ options.executionTimeout $ \value ->
    when (toRational value * 1000000 < 1 || toRational value * 1000000 > fromIntegral (maxBound @Int))
      (Left "executionTimeout is outside the positive timer range")
  pure (fromInteger (ceiling (seconds * 1000000)))

setup :: Program -> IO ()
setup program = do
  handle <- requireBackend program
  root <- requireDirectory program
  startupPath <- newPrivateFile program "start-error"
  acceptedPath <- newPrivateFile program "accepted"
  writeIORef program.errorFile (Just startupPath)
  writeIORef program.acceptedFile (Just acceptedPath)
  let fifo = root </> "gate"
  mask_ $ do
    File.createNamedPipe (Ascii.pack fifo) 0o600
    rememberFile program fifo
    writeIORef program.fifo (Just fifo)
    Posix.openFd (Ascii.pack fifo) Posix.ReadWrite
      Posix.defaultFileFlags {Posix.nonBlock = True, Posix.cloexec = True}
      >>= writeIORef program.writer . Just
    N.watchDirectory (Ascii.pack root) >>= writeIORef program.watch . Just
  checkBootstrap program fifo
  initial <- observe program "pane-created" "#{created_respawn}"
  atomically (writeTVar program.generation (Just initial))
  callerDirectory <- PosixDirectory.getWorkingDirectory
  let requested = maybe callerDirectory osBytes program.settings.workingDirectory
      cwd = if Bytes.isPrefixOf "/" requested then requested else callerDirectory <> "/" <> requested
      socket = Pin.pinPath (R.serverPin handle)
      assignments = map (\(key, value) -> osBytes key <> "=" <> osBytes value) program.settings.environment
      argv = [bootstrap, "libtmux-program", Ascii.pack startupPath, Ascii.pack acceptedPath,
        Ascii.pack fifo, program.clientExecutable, socket, cwd, gateDuration program, Ascii.pack (show (length assignments))]
        <> assignments <> [osBytes program.settings.executable] <> map osBytes program.settings.arguments
  width <- either (fail . show) pure (Value.mkDimension (toInteger program.settings.columns))
  height <- either (fail . show) pure (Value.mkDimension (toInteger program.settings.rows))
  let options = Creation.defaultSessionOptions
        { Creation.name = Just (Utf8.decodeUtf8 ("libtmux-haskell-program-" <> Bytes.take 24 program.token))
        , Creation.width = Just width, Creation.height = Just height
        , Creation.workingDirectory = Just (Os.fromBytestring "/")
        , Creation.updateEnvironment = False
        , Creation.environment = [(Os.fromBytestring "LIBTMUX_PROGRAM_TOKEN", Os.fromBytestring program.token)]
        , Creation.process = Creation.DirectCommand program.settings.bootstrapShell
            (Os.fromBytestring "--noprofile" :| map Os.fromBytestring (["--norc", "-p", "-c"] <> argv))
        }
      retainCreation failure@(ExceptionWithContext context (_ :: SomeException)) = do
        let recoveries = Context.getExceptionAnnotations @Create.CreationRecovery context
        modifyIORef' program.creations (recoveries <>)
        forM_ recoveries $ \recovery -> atomically (Create.observedReceipt recovery) >>= \case
          Just receipt -> writeIORef program.created (Just receipt)
          Nothing -> pure ()
        rethrowIO failure
  mask $ \restore -> do
    created <- catchNoPropagate
      (restore (Create.performCreation P.defaultHooks program.duration program.runtime handle program.clientExecutable options))
      retainCreation
    writeIORef program.created (Just created)
  (session, pane) <- identities program
  mutation program (C.ProgramHistory session program.settings.historyLines)
  mutation program (C.ProgramRemain pane)
  mutation program (C.ProgramRemainFormat pane)
  created <- readIORef program.created >>= maybe (throwIO ProgramCleanupIncomplete) pure
  let G.WindowRef _ window = created.window
  mutation program (C.ProgramGeometry window program.settings.columns program.settings.rows)
  ensureGeneration program
  state <- readState program
  pid <- maybe (throwIO (ProgramObservationLost "bootstrap exited before ownership acquisition")) pure state.pid
  writeIORef program.processId (Just pid)
  mask $ \restore -> bracketOnError (N.openGroup (fromInteger pid)) N.close $ \fd -> do
    marker <- restore (readBoundedFile ("/proc/" <> show pid <> "/environ") 65536)
    unless (("LIBTMUX_PROGRAM_TOKEN=" <> program.token) `elem` Bytes.split 0 marker)
      (throwIO (ProgramObservationLost "pane process is outside the local owned bootstrap"))
    live <- N.cSignal fd 0
    unless (live == 0) (throwIO (ProgramObservationLost "bootstrap identity expired during acquisition"))
    writeIORef program.candidate (Just (fd, pid))
  next <- observe program "pane-created" (panePredicate pane)
  writeIORef program.successor (Just next)
  exited <- observe program "pane-died" (panePredicate pane)
  atomically (writeTVar program.eventWaiter (Just exited.ticket))
  mask_ $ do
    writer <- readIORef program.writer >>= maybe (throwIO ProgramCleanupIncomplete) pure
    writeIORef program.released True
    let bytes = Bytes.intercalate " " [initial.clientName, Utf8.encodeUtf8 (Id.renderSessionId session),
          Utf8.encodeUtf8 (Id.renderWindowId window), Utf8.encodeUtf8 (Id.renderPaneId pane), Ascii.pack (show pid)] <> "\n"
    count <- Posix.fdWrite writer bytes
    unless (toInteger count == toInteger (Bytes.length bytes))
      (throwIO (ProgramObservationLost "partial bootstrap claim submission"))
  claimed <- bounded program (acceptCandidate program)
  unless claimed (throwIO (ProgramObservationLost "bootstrap ownership claim was refused"))
  closeObserver program initial
  ensureGeneration program

-- All caller bytes are positional parameters. Successful exec discards the
-- EXIT trap; a failed exec or cd leaves a separate bounded startup diagnostic.
bootstrap :: ByteString
bootstrap = "for __libtmux_entry in \"${!__libtmux_@}\"; do unset -v \"$__libtmux_entry\"; done; "
  <> "__libtmux_error=$1; __libtmux_accepted=$2; __libtmux_gate=$3; __libtmux_tmux=$4; __libtmux_socket=$5; __libtmux_cwd=$6; __libtmux_budget=$7; __libtmux_count=$8; "
  <> "__libtmux_environment=(\"${@:9:__libtmux_count}\"); shift \"$((8 + __libtmux_count))\"; shopt -s execfail || exit 125; "
  <> "__libtmux_phase=gate; trap 'status=$?; printf \"%s:%s\\n\" \"$__libtmux_phase\" \"$status\" > \"$__libtmux_error\"' EXIT; "
  <> "exec {__libtmux_gatefd}<> \"$__libtmux_gate\" || exit 125; "
  <> "IFS=' ' read -r -t \"$__libtmux_budget\" -u \"$__libtmux_gatefd\" __libtmux_claim __libtmux_session __libtmux_window __libtmux_pane __libtmux_pid; __libtmux_read_status=$?; "
  <> "exec {__libtmux_gatefd}<&- || exit 125; [ \"$__libtmux_read_status\" -eq 0 ] || exit 125; __libtmux_phase=claim; "
  <> "[ \"$TMUX_PANE\" = \"$__libtmux_pane\" ] && [ \"$$\" = \"$__libtmux_pid\" ] || exit 125; "
  <> "__libtmux_condition=\"#{&&:#{==:#{session_id},$__libtmux_session},#{&&:#{==:#{window_id},$__libtmux_window},#{&&:#{==:#{pane_id},$__libtmux_pane},#{&&:#{==:#{pane_pid},$__libtmux_pid},#{&&:#{==:#{session_windows},1},#{==:#{window_panes},1}}}}}}\"; "
  <> "__libtmux_receipt=$(\"$__libtmux_tmux\" -N -S \"$__libtmux_socket\" wait-for -E -w \"$__libtmux_claim\" pane-created ';' if-shell -F -t \"$__libtmux_session:\" \"$__libtmux_condition\" \"display-message -p '$LIBTMUX_PROGRAM_TOKEN:$$'\" \"has-session -t =libtmux-refused-$LIBTMUX_PROGRAM_TOKEN\") || exit 125; "
  <> "[ \"$__libtmux_receipt\" = \"$LIBTMUX_PROGRAM_TOKEN:$$\" ] || exit 125; printf '%s:%s\\n' \"$LIBTMUX_PROGRAM_TOKEN\" \"$$\" > \"$__libtmux_accepted\"; "
  <> "__libtmux_phase=cwd; CDPATH= cd -- \"$__libtmux_cwd\" || exit $?; __libtmux_phase=environment; "
  <> "for __libtmux_entry in \"${__libtmux_environment[@]}\"; do __libtmux_name=${__libtmux_entry%%=*}; unset -v \"$__libtmux_name\" && export \"$__libtmux_entry\" || exit 125; done; "
  <> "__libtmux_phase=exec; exec -- \"$@\"; exit \"$?\""
-- Probe the exact builtins before any application is created. Opening a FIFO
-- read/write cannot wait for a partner; the timed read also covers a self-held
-- writer when cancellation closes the controller's writer first.
checkBootstrap :: Program -> FilePath -> IO ()
checkBootstrap program path = do
  let script = "shopt -s execfail || exit 96; exec {__libtmux_probe}<> \"$1\" || exit 97; shift; IFS= read -r -t 0.001 -u \"$__libtmux_probe\" __libtmux_value; __libtmux_code=$?; exec {__libtmux_probe}<&- || exit 98; [[ $__libtmux_code -gt 128 && ! -e /proc/$$/fd/$__libtmux_probe ]] || exit 99; for __libtmux_entry in \"$@\"; do __libtmux_name=${__libtmux_entry%%=*}; unset -v \"$__libtmux_name\" && export \"$__libtmux_entry\" || { printf '%s' \"$__libtmux_name\"; exit 95; }; done; printf LIBTMUX_BASH_READY"
      shell = osBytes program.settings.bootstrapShell
      assignments = map (\(key, value) -> osBytes key <> "=" <> osBytes value) program.settings.environment
      spec = N.spec shell ([shell, "--noprofile", "--norc", "-p", "-c", script, "probe", Ascii.pack path] <> assignments)
  result <- try @N.Failure (inspectProcess program spec)
  case result of
    Right completed | completed.exit == Just (N.Exited 0)
      && completed.output == "LIBTMUX_BASH_READY" && Bytes.null completed.errors -> pure ()
    Right completed | completed.exit == Just (N.Exited 95) ->
      throwIO (InvalidProgramOptions ("bootstrap cannot preserve environment name: " <> Utf8.decodeUtf8 completed.output))
    _ -> throwIO ProgramBootstrapUnavailable
gateDuration :: Program -> ByteString
gateDuration program = Ascii.pack (show seconds <> "." <> replicate (6 - length fraction) '0' <> fraction)
  where
    (seconds, micros) = min 1000000 program.duration `divMod` 1000000
    fraction = show micros

observe :: Program -> ByteString -> ByteString -> IO Observer
observe program event predicate = mask $ \restore -> do
  handle <- requireBackend program
  let args = ["wait-for", "-E", "-F", predicate, event]
      spec = nativeSpec program handle args
  lease <- atomically (B.acquireBytes (R.serverPool handle).budget B.Ordinary P.retainedBytes)
  registered <- newTVarIO False
  let register ticket = do
        current <- readTVar program.observers
        when (length current >= 4) (throwSTM P.ResourceLimit)
        writeTVar program.observers (PendingObserver ticket lease : current)
        writeTVar registered True
      undo = atomically $ readTVar registered >>= \present -> unless present (B.releaseBytes lease)
  ticket <- P.submitRegistered register B.Ordinary P.defaultHooks (R.serverPool handle) spec "" `onException` undo
  pid <- restore (bounded program (P.clientProcessId ticket))
  let clientName = "client-" <> Ascii.pack (show pid)
  acknowledged <- restore $ timeout program.duration $ do
    let checkRegistration = do
          atomically (tryReadTMVar ticket.result) >>= \case
            Just _ -> throwIO (ProgramObservationLost "event client exited before registration")
            Nothing -> pure ()
          completed <- inspectNative program ["wait-for", "-E", "-l", event]
          if clientName `elem` Ascii.lines completed.output then pure () else checkRegistration
    checkRegistration
  when (acknowledged /= Just ()) (throwIO (ProgramObservationLost "event waiter registration timed out"))
  pure Observer {ticket, clientName, lease}

panePredicate :: Id.PaneId -> ByteString
panePredicate pane = "#{==:#{pane}," <> Utf8.encodeUtf8 (Id.renderPaneId pane) <> "}"

acceptCandidate :: Program -> IO Bool
acceptCandidate program = readIORef program.candidate >>= \case
  Nothing -> maybe False (const True) <$> readIORef program.group
  Just (fd, pid) -> do
    file <- readIORef program.acceptedFile >>= maybe (throwIO ProgramCleanupIncomplete) pure
    value <- readBoundedFile file 128
    if value == program.token <> ":" <> Ascii.pack (show pid) <> "\n" then mask_ $ do
      next <- readIORef program.successor >>= maybe (throwIO ProgramCleanupIncomplete) pure
      writeIORef program.group (Just fd)
      writeIORef program.candidate Nothing
      atomically (writeTVar program.generation (Just next))
      pure True
    else do
      errorFile <- readIORef program.errorFile >>= maybe (throwIO ProgramCleanupIncomplete) pure
      failure <- readBoundedFile errorFile 64
      exited <- N.pidReady fd
      if not (Bytes.null failure) || exited then pure False else do
        watch <- readIORef program.watch >>= maybe (throwIO ProgramCleanupIncomplete) pure
        race (threadWaitRead (Fd watch)) (threadWaitRead (Fd fd)) >>= \case
          Left () -> N.watchRead watch >>= \ready -> when (ready < 0) (N.raise (-ready))
          Right () -> pure ()
        acceptCandidate program

currentGeneration :: Program -> IO Observer
currentGeneration program = atomically (readTVar program.generation) >>= maybe
  (throwIO (ProgramObservationLost "application generation is unavailable")) pure

ensureGeneration :: Program -> IO ()
ensureGeneration program = do
  current <- currentGeneration program
  registered <- inspectNative program ["wait-for", "-E", "-l", "pane-created"]
  unless (current.clientName `elem` Ascii.lines registered.output)
    (throwIO (ProgramObservationLost "pane process generation changed"))

guardIdentity :: Program -> IO C.ProgramIdentity
guardIdentity program = do
  created <- readIORef program.created >>= maybe (throwIO ProgramCleanupIncomplete) pure
  pid <- readIORef program.processId >>= \case
    Just value -> pure value
    Nothing -> maybe 0 id . (.pid) <$> readState program
  let G.SessionRef _ session = created.session
      G.WindowRef _ window = created.window
      G.PaneRef _ pane = created.pane
  pure (C.ProgramIdentity session window pane pid)

transfer :: Program -> Bool -> C.ProgramCommand -> IO ()
transfer program live action = mask $ \restore -> do
  ensureGeneration program
  previous <- currentGeneration program
  (_, pane) <- identities program
  next <- restore (observe program "pane-created" (panePredicate pane))
  identity <- guardIdentity program
  atomically (writeTVar program.handoff True)
  let promote = atomically (writeTVar program.generation (Just next))
      run = do
        result <- tryWithContext @SomeException (restore (mutation program (C.ProgramGuarded identity previous.clientName live action)))
        case result of
          Right () -> promote >> restore (closeObserver program previous) >> ensureGeneration program
          Left failure@(ExceptionWithContext _ problem) -> do
            case fromException problem of
              Just (MutationAppliedWithErrors _) -> promote
              _ -> pure ()
            rethrowIO failure
  run `finally` atomically (writeTVar program.handoff False)

closeObserver :: Program -> Observer -> IO ()
closeObserver program observer = closePending program (PendingObserver observer.ticket observer.lease)

closePending :: Program -> PendingObserver -> IO ()
closePending program (PendingObserver ticket lease) = mask $ \restore -> do
  handle <- requireBackend program
  let pool = R.serverPool handle
  P.abort ticket
  P.resumeCleanup pool ticket
  restore $ bounded program $ atomically $ do
    void (readTMVar ticket.result)
    P.ticketOwned pool ticket >>= check . not
  atomically $ do
    B.releaseBytes lease
    modifyTVar' program.observers (filter (\(PendingObserver selected _) -> selected.key /= ticket.key))

-- | Send literal bytes to the real application PTY. A call admits at most
-- 1024 bytes, including NUL; terminal line discipline still applies. Sending
-- bytes is not evidence that the application consumed them.
sendProgramInput :: Program -> ByteString -> IO ()
sendProgramInput program bytes = withMVar program.gate $ \_ -> do
  checkOpen program Cap.ProgramInput
  when (Bytes.length bytes > 1024) (throwIO (InvalidProgramOptions "input exceeds 1024 bytes"))
  unless (Bytes.null bytes) $ do
    (_, pane) <- identities program
    transfer program True (C.ProgramInputBytes pane bytes)

-- | Capture the current rendered terminal. Limits are configured before launch;
-- the result reports clipped bytes and possible history loss explicitly. An
-- external resize refuses capture before allocation; cleanup remains available.
readProgramScreen :: Program -> IO ProgramScreen
readProgramScreen program = withMVar program.gate $ \_ -> do
  checkOpen program Cap.RenderedScreen
  (_, pane) <- identities program
  buffer <- ("libtmux-haskell-" <>) . hexToken <$> Entropy.freshToken32
  bracket (mask_ $ do
    modifyIORef' program.buffers (buffer :)
    newPrivateFile program "screen")
    (removePrivateFile program) $ \path -> do
      transfer program False (C.ProgramCapture pane buffer program.settings.historyLines
        program.settings.columns program.settings.rows)
      mutation program (C.ProgramSave buffer (Ascii.pack path))
      size <- withBinaryFile path ReadMode hFileSize
      screenBytes <- readBoundedFile path program.settings.outputLimit
      state <- readState program
      deleteBuffer program buffer
      ensureGeneration program
      pure ProgramScreen {screenBytes, omittedBytes = max 0 (size - toInteger (Bytes.length screenBytes)),
        historyTruncated = state.history >= toInteger program.settings.historyLines}

-- | Observe the real process exit and tmux's final PTY drain. Cancelling this
-- observation leaves the owning scope and application running. A destroyed
-- pane or lost daemon raises an observation error instead of inventing an exit.
waitProgram :: Program -> IO ProgramExit
waitProgram program = do
  checkOpen program Cap.ProgramExitEvents
  waitExitReady program
  withMVar program.gate $ \_ -> checkOpen program Cap.ProgramExitEvents >> awaitExit program

-- | Bound only this observation. Nothing means the deadline elapsed; it does
-- not terminate the application. Async cancellation also leaves it running.
waitProgramFor :: NominalDiffTime -> Program -> IO (Maybe ProgramExit)
waitProgramFor seconds program = do
  let micros = ceiling (toRational seconds * 1000000)
  when (micros < 1 || micros > toInteger (maxBound @Int))
    (throwIO (InvalidProgramOptions "wait duration is outside the positive timer range"))
  timeout (fromInteger micros) (waitProgram program)

-- | Request TERM, allow 100ms for the exit event, then send KILL to the retained
-- process-group identity. Descendants that move to another group/session are
-- outside this ownership contract. The returned outcome belongs to the leader.
terminateProgram :: Program -> IO ProgramExit
terminateProgram program = withMVar program.gate $ \_ -> do
  checkOpen program Cap.ManagedPrograms
  stopGroup program
  bounded program (awaitExit program)

awaitExit :: Program -> IO ProgramExit
awaitExit program = atomically (tryReadTMVar program.exitResult) >>= \case
  Just result -> pure result
  Nothing -> do
    ticket <- atomically (readTVar program.eventWaiter) >>= maybe
      (throwIO (ProgramObservationLost "no exit observation was registered")) pure
    completed <- P.await ticket
    unless (completed.exit == Just (N.Exited 0) && Bytes.null completed.errors)
      (throwIO (ProgramObservationLost "exit observation failed"))
    ensureGeneration program
    state <- readState program
    unless state.dead
      (throwIO (ProgramObservationLost "retained pane no longer identifies the application"))
    ensureGeneration program
    startup <- readIORef program.errorFile >>= maybe (pure "") (flip readBoundedFile 64)
    result <- if Bytes.null startup then case (state.status, state.signal) of
      (Just code, "") -> pure (ProgramExited code)
      (Nothing, signal) | not (Bytes.null signal) -> pure (ProgramSignalled (Utf8.decodeUtf8 signal))
      _ -> throwIO (ProgramObservationLost "exit has neither exact status nor signal")
      else case Ascii.split ':' (stripLF startup) of
        [phase, code] | Just value <- number code, value <= 255 -> case phase of
          "cwd" -> pure (ProgramStartFailed (StartFailure WorkingDirectory (fromInteger value)))
          "exec" -> pure (ProgramStartFailed (StartFailure Executable (fromInteger value)))
          "environment" -> pure (ProgramStartFailed (StartFailure Environment (fromInteger value)))
          "gate" -> pure (ProgramStartFailed (StartFailure Bootstrap (fromInteger value)))
          "claim" -> pure (ProgramStartFailed (StartFailure Bootstrap (fromInteger value)))
          _ -> throwIO (ProgramObservationLost "unrecognized startup phase")
        _ -> throwIO (ProgramObservationLost "invalid startup evidence")
    atomically (void (tryPutTMVar program.exitResult result))
    pure result

waitExitReady :: Program -> IO ()
waitExitReady program = atomically $ do
  selected <- readTVar program.eventWaiter >>= maybe (throwSTM (ProgramObservationLost "exit observer unavailable")) pure
  let exited = void (readTMVar selected.result)
      replaced = do
        busy <- readTVar program.handoff
        check (not busy)
        current <- readTVar program.generation >>= maybe (throwSTM ProgramClosed) pure
        void (readTMVar current.ticket.result)
        throwSTM (ProgramObservationLost "pane process generation changed")
  exited `orElse` replaced

data PaneState = PaneState {pid :: !(Maybe Integer), dead :: !Bool, status :: !(Maybe Int), signal :: !ByteString, history :: !Integer}

readState :: Program -> IO PaneState
readState program = do
  handle <- requireBackend program
  (_, pane) <- identities program
  bytes <- tracked program $ M.performRequest program.duration program.runtime handle
    (\remaining -> remaining >>= \left -> R.readEntityFieldWith (R.ProgramState pane) P.defaultHooks left program.runtime handle
      program.clientExecutable R.ScalarRead) pure
  case Ascii.split ':' bytes of
    [pid, dead, status, signal, history]
      | Bytes.null pid && dead == "1" || maybe False (\value -> value > 0 && value <= toInteger (maxBound @CInt)) (number pid)
      , Just historySize <- number history
      , dead == "0" || dead == "1"
      , Bytes.null status || maybe False (<= 255) (number status)
      , Bytes.all (\byte -> byte >= 65 && byte <= 90 || byte >= 48 && byte <= 57) signal ->
          pure (PaneState (number pid) (dead == "1") (fromInteger <$> number status) signal historySize)
    _ -> throwIO (ProgramObservationLost "invalid pane state")

stopGroup :: Program -> IO ()
stopGroup program = readIORef program.group >>= \case
  Nothing -> pure ()
  Just fd -> do
    signal fd 15
    graceful <- timeout 100000 (threadWaitRead (Fd fd))
    when (graceful == Nothing) (signal fd 9)
    -- A leader may exit before another group member; always settle the group.
    signal fd 9
    bounded program (threadWaitRead (Fd fd))
    bounded program (groupEmpty fd)
  where
    signal fd value = N.signalGroup fd value >>= \result ->
      unless (result == 0 || result == N.errno eSRCH) (N.raise result)
    -- Linux exposes no group-empty readiness descriptor. ESRCH through this
    -- retained pidfd is conclusive; a zombie or uninterruptible member keeps
    -- cleanup incomplete. Yield between bounded signal-zero observations.
    groupEmpty fd = N.signalGroup fd 0 >>= \result ->
      if result == N.errno eSRCH then pure () else
        if result == 0 then yield >> groupEmpty fd else N.raise result

cleanup :: Program -> IO ()
cleanup program = withMVar program.gate $ \_ -> mask $ \restore -> do
  atomically (writeTVar program.closed True)
  retired <- readIORef program.retired
  unless retired $ restore $ do
    closeGate program
    readIORef program.candidate >>= mapM_ (\(fd, _) -> do
      released <- readIORef program.released
      accepted <- if released then bounded program (acceptCandidate program) else pure False
      unless accepted $ do
        bounded program (threadWaitRead (Fd fd))
        mask_ $ N.close fd >> writeIORef program.candidate Nothing)
    stopGroup program
    let remoteCleanup = do
          readIORef program.creations >>= mapM_ (\recovery ->
            atomically (Create.observedReceipt recovery) >>= \case
              Just receipt -> writeIORef program.created (Just receipt)
              Nothing -> throwIO ProgramCleanupIncomplete)
          readIORef program.created >>= \case
            Nothing -> pure ()
            Just _ -> do
              (session, _) <- identities program
              present <- sessionPresent program session
              when present $ do
                identity <- guardIdentity program
                previous <- currentGeneration program
                catchNoPropagate
                  (mutation program (C.ProgramGuarded identity previous.clientName False (C.ProgramKillSession session)))
                  (\failure -> sessionPresent program session >>= \remaining -> when remaining (rethrowIO (failure :: ExceptionWithContext SomeException)))
          readIORef program.buffers >>= mapM_ (deleteBuffer program)
    gone <- daemonExited program
    unless gone $ catchNoPropagate remoteCleanup $ \failure -> do
      ended <- daemonExited program
      unless ended (rethrowIO (failure :: ExceptionWithContext SomeException))
    atomically (readTVar program.observers) >>= mapM_ (closePending program)
    readIORef program.mutations >>= mapM_ (\recovery -> do
      void (bounded program (M.awaitRecovery recovery))
      void (atomically (M.detachRecovery recovery)))
    readIORef program.creations >>= mapM_ (\recovery -> do
      void (bounded program (Create.awaitRecovery recovery))
      void (atomically (Create.detachRecovery recovery)))
    report <- atomically (R.inspect program.runtime)
    atomically $ forM_ report.unresolved $ \(operation, _) -> void (R.detachOperation program.runtime operation)
    readIORef program.watch >>= mapM_ N.close
    writeIORef program.watch Nothing
    readIORef program.files >>= mapM_ (\(path, _, _) -> removePrivateFile program path)
    readIORef program.directory >>= mapM_ Directory.removeDirectory
    writeIORef program.retired True
  report <- restore (R.shutdown program.runtime)
  unless (nativeComplete report) (throwIO ProgramCleanupIncomplete)
  readIORef program.group >>= mapM_ N.close
  writeIORef program.group Nothing
  readIORef program.daemon >>= mapM_ N.close
  writeIORef program.daemon Nothing

nativeComplete :: R.Report -> Bool
nativeComplete report = null report.pending && null report.closeFailures
  && null report.unresolved && null report.readWorkers

mutation :: Program -> C.ProgramCommand -> IO ()
mutation program command = do
  handle <- requireBackend program
  tracked program $ M.performRequest program.duration program.runtime handle
    (\remaining -> remaining >>= \left -> R.programMutationWith P.defaultHooks left program.runtime handle program.clientExecutable command) $ \case
      C.Applied -> pure ()
      C.Rejected diagnostic -> throwIO (MutationRejected diagnostic)
      C.AppliedWithErrors diagnostic -> throwIO (MutationAppliedWithErrors diagnostic)

tracked :: Program -> IO a -> IO a
tracked program action = catchNoPropagate action $ \failure@(ExceptionWithContext context (_ :: SomeException)) -> do
  modifyIORef' program.mutations (Context.getExceptionAnnotations @M.MutationRecovery context <>)
  rethrowIO failure

daemonExited :: Program -> IO Bool
daemonExited program = readIORef program.daemon >>= maybe (pure False) N.pidReady

sessionPresent :: Program -> Id.SessionId -> IO Bool
sessionPresent program session = do
  completed <- inspectNativeAny program ["has-session", "-t", Utf8.encodeUtf8 (Id.renderSessionId session)]
  case completed.exit of
    Just (N.Exited 0) | Bytes.null completed.errors -> pure True
    Just (N.Exited 1) | Bytes.null completed.output
      && (Bytes.null completed.errors || completed.errors == "can't find session: " <> Utf8.encodeUtf8 (Id.renderSessionId session) <> "\n") -> pure False
    _ -> throwIO (ProgramObservationLost "owned session presence is uncertain")

allowMissing :: ByteString -> IO () -> IO ()
allowMissing expected action = catchNoPropagate action $ \failure@(ExceptionWithContext _ (problem :: SomeException)) ->
  case fromException problem of
    Just (MutationRejected diagnostic) | diagnostic == expected -> pure ()
    _ -> rethrowIO failure

deleteBuffer :: Program -> ByteString -> IO ()
deleteBuffer program name = do
  allowMissing ("unknown buffer: " <> name <> "\n") (mutation program (C.ProgramDeleteBuffer name))
  modifyIORef' program.buffers (filter (/= name))

inspectNative :: Program -> [ByteString] -> IO P.Completion
inspectNative program args = do
  completed <- inspectNativeAny program args
  unless (completed.exit == Just (N.Exited 0) && Bytes.null completed.errors)
    (throwIO (ProgramObservationLost "event registration inspection failed"))
  pure completed

inspectNativeAny :: Program -> [ByteString] -> IO P.Completion
inspectNativeAny program args = do
  handle <- requireBackend program
  inspectProcess program (nativeSpec program handle args)

inspectProcess :: Program -> N.Spec -> IO P.Completion
inspectProcess program spec = do
  handle <- requireBackend program
  let pool = R.serverPool handle
  bracket (atomically (B.acquireBytes pool.budget B.Inspection P.retainedBytes))
    (atomically . B.releaseBytes) $ \_ -> mask $ \restore -> do
      ticket <- P.submit B.Inspection P.defaultHooks pool spec ""
      completed <- restore (bounded program (P.await ticket)) `onException` P.abort ticket
      pure completed

nativeSpec :: Program -> R.ServerHandle -> [ByteString] -> N.Spec
nativeSpec program handle args = N.spec program.clientExecutable
  ([program.clientExecutable, "-u", "-N", "-S", Pin.pinPath (R.serverPin handle)] <> args)

checkOpen :: Program -> Cap.Capability -> IO ()
checkOpen program capability = do
  either throwIO pure (Cap.requireCapability program.available capability)
  atomically (readTVar program.closed) >>= flip when (throwIO ProgramClosed)

identities :: Program -> IO (Id.SessionId, Id.PaneId)
identities program = readIORef program.created >>= \case
  Just created -> let G.SessionRef _ session = created.session; G.PaneRef _ pane = created.pane in pure (session, pane)
  Nothing -> throwIO (ProgramObservationLost "creation has no owned identities")

requireBackend :: Program -> IO R.ServerHandle
requireBackend program = readIORef program.backend >>= maybe (throwIO ProgramCleanupIncomplete) pure

requireDirectory :: Program -> IO FilePath
requireDirectory program = readIORef program.directory >>= maybe (throwIO ProgramCleanupIncomplete) pure

bounded :: Program -> IO a -> IO a
bounded program action = timeout program.duration action >>= maybe (throwIO ProgramCleanupIncomplete) pure

readBoundedFile :: FilePath -> Int -> IO ByteString
readBoundedFile file limit = withBinaryFile file ReadMode (\handle -> Bytes.hGet handle limit)

newPrivateFile :: Program -> String -> IO FilePath
newPrivateFile program prefix = mask_ $ do
  root <- requireDirectory program
  (path, file) <- openBinaryTempFile root prefix
  rememberFile program path `finally` hClose file
  pure path

rememberFile :: Program -> FilePath -> IO ()
rememberFile program path = do
  status <- File.getSymbolicLinkStatus (Ascii.pack path)
  modifyIORef' program.files ((path, toInteger (File.deviceID status), toInteger (File.fileID status)) :)

removePrivateFile :: Program -> FilePath -> IO ()
removePrivateFile program path = do
  owned <- readIORef program.files
  case [(device, inode) | (name, device, inode) <- owned, name == path] of
    [(device, inode)] -> do
      result <- try @IOException (File.getSymbolicLinkStatus (Ascii.pack path))
      case result of
        Left problem | isDoesNotExistError problem -> pure ()
        Left problem -> throwIO problem
        Right status -> do
          unless (toInteger (File.deviceID status) == device && toInteger (File.fileID status) == inode)
            (throwIO (ProgramObservationLost "owned file identity changed"))
          Directory.removeFile path
      modifyIORef' program.files (filter (\(name, _, _) -> name /= path))
    [] -> pure ()
    _ -> throwIO ProgramCleanupIncomplete

closeGate :: Program -> IO ()
closeGate program = mask_ $ do
  readIORef program.fifo >>= mapM_ (removePrivateFile program)
  readIORef program.writer >>= mapM_ Posix.closeFd
  writeIORef program.writer Nothing
  writeIORef program.fifo Nothing

timerMicros :: NominalDiffTime -> Int
timerMicros = fromInteger . ceiling . (* 1000000) . toRational

osBytes :: PosixString -> ByteString
osBytes = Bytes.pack . map (fromIntegral . fromEnum . Os.toChar) . Os.unpack

hexToken :: ByteString -> ByteString
hexToken = Bytes.concatMap $ \byte -> let alphabet = "0123456789abcdef" in
  Bytes.pack [Bytes.index alphabet (fromIntegral (shiftR byte 4)), Bytes.index alphabet (fromIntegral (byte .&. 15))]

number :: ByteString -> Maybe Integer
number bytes
  | Bytes.null bytes || not (Bytes.all (\byte -> byte >= 48 && byte <= 57) bytes) = Nothing
  | otherwise = case Ascii.readInteger bytes of Just (value, "") -> Just value; _ -> Nothing

stripLF :: ByteString -> ByteString
stripLF bytes = maybe bytes id (Bytes.stripSuffix "\n" bytes)

annotate :: ProgramRecovery -> ExceptionWithContext SomeException -> ExceptionWithContext SomeException
annotate recovery (ExceptionWithContext context problem) =
  ExceptionWithContext (Context.addExceptionAnnotation recovery context) problem

retaining :: ProgramRecovery -> IO a -> IO a
retaining (ProgramRecovery program _) action = catchNoPropagate action $ \failure@(ExceptionWithContext _ cause) ->
  rethrowIO (annotate (ProgramRecovery program (Just cause)) failure)
