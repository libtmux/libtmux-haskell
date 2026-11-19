-- | Own daemonizing tmux processes and private endpoint names.
--
-- Startup sends @start-server ; set-option -g exit-empty off@ through a
-- pool-owned client. The socket lock and listener establish a pidfd before
-- admission; the daemon's reported process identity must match that descriptor.
-- Only pidfd readability proves exit. A missing listener after a client ran
-- retains the owner and its names; only a refused atomic launch proves no birth.
--
-- One gate serializes the joint daemon, pool, operation and name cleanup.
-- Cancellation stops the observer, not its cleanup worker. Callback failures
-- remain primary, and recovery retries the journaled release or kill intent.
-- Historical uncertain operations are detached only after proven daemon exit.
--
-- Owned startup and adopted kill require Linux socket pidfds and fdinfo.
-- Killing the Haskell process can abandon a daemon before cleanup finishes.
module LibTmux.Internal.OwnedServer where

import Control.Concurrent (forkIO, myThreadId)
import Control.Concurrent.Async (race)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM
import Control.Exception
import Control.Exception.Annotation (ExceptionAnnotation)
import Control.Exception.Context (ExceptionContext)
import Control.Exception.Context qualified as Context
import Control.Monad (foldM, forM, forM_, join, unless, void, when)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.Char (isSpace)
import Data.IORef
import Data.IntMap.Strict qualified as IntMap
import Data.IntSet qualified as IntSet
import Data.Maybe (isJust, isNothing, listToMaybe)
import Foreign.C.Error (eAGAIN, eBADF, eCONNREFUSED, eNOENT, eSRCH)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..))
import GHC.Conc (labelThread, threadWaitRead)
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.Capture qualified as C
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Native qualified as N
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.Scheduler qualified as S
import LibTmux.Internal.Scope (CleanupStatus (..), TmuxException (ServerClosed, UnsupportedTmuxVersion))
import LibTmux.Internal.Scope qualified as Scope
import LibTmux.Internal.SocketPin (PinCheckpoint, pinPath)
import LibTmux.Version qualified as Version
import System.IO.Error (isDoesNotExistError)
import System.Posix.Directory.ByteString (removeDirectory)
import System.Posix.Files.ByteString qualified as Files
import System.Posix.Signals (sigKILL, sigTERM)
import System.Posix.Temp.ByteString (mkdtemp)
import System.Posix.Types (DeviceID, FileID, Fd (..))
import System.Timeout (timeout)

-- No call here blocks: the connect is nonblocking, the lock probe is a try-lock, poll
-- only classifies with a zero timeout, and every wait is an event registration under
-- a Haskell deadline, which works in the non-threaded RTS too.
foreign import ccall safe "libtmux_process_peer_pidfd" cPeerPidfd :: CString -> IO CInt
foreign import ccall safe "libtmux_process_anchor" cAnchor :: CString -> IO CInt
foreign import ccall unsafe "libtmux_process_daemon_features" cDaemonFeatures :: IO CInt
foreign import ccall unsafe "libtmux_process_watch_start" cWatchStart :: CString -> IO CInt
foreign import ccall unsafe "libtmux_process_watch_removals" cWatchRemovals :: CString -> IO CInt
foreign import ccall unsafe "libtmux_process_watch_drain" cWatchDrain :: CInt -> IO CInt
foreign import ccall unsafe "libtmux_process_lock_held" cLockHeld :: CString -> IO CInt
foreign import ccall unsafe "libtmux_process_poll" cPoll :: CInt -> CInt -> IO CInt
foreign import ccall unsafe "libtmux_process_dup" cDup :: CInt -> IO CInt

-- | The private directory and the socket inside it, both created for this run.
data Names = Names {directory :: !ByteString, socket :: !ByteString}
  deriving stock (Eq, Show)

-- | Deterministic failure and cancellation boundaries; normal runs observe none.
data Stage = ClientLaunched | ClientExited | DaemonOwned | Verified | Admitted
  deriving stock (Eq, Show)

-- | Cleanup phases, in order. The worker reports each before it runs, so a test
-- can hold or fail one boundary deterministically.
data Phase = PhaseClient | PhaseDaemon | PhasePool | PhaseOperations | PhaseNames
  deriving stock (Eq, Show)

-- | What an owner's attempts do to the daemon: drop the descriptors only (an adopted
-- capability that was never used to kill), or end it. 'Terminate' outranks 'Release'.
data Fate = Release | Terminate
  deriving stock (Eq, Ord, Show)

-- | How the original daemon left, always observed through its pidfd.
data Retirement = AlreadyGone | Terminated | Killed
  deriving stock (Eq, Show)

-- | A host operation the daemon path needs and the host lacks.
data Missing = Spawn !N.Feature | PeerPidfd | PidfdSignal | ProcFdinfo
  deriving stock (Eq, Show)

-- | Test seams. 'signal' defaults to pidfd_send_signal, so a replacement can model
-- a refused signal without touching a real process; 'closeFd' counts closures;
-- 'spawn' models a refused worker.
data Probe = Probe
  { hooks :: !P.Hooks
  , spawn :: !(IO () -> IO ())
    -- ^ Starts one cleanup worker. A refusal must throw before any work ran.
  , root :: !ByteString
    -- ^ Parent of the private directory.
  , features :: !(IO CInt)
    -- ^ Available 'cDaemonFeatures' bits; a test can model an unsupported host.
  , stage :: !(Stage -> Names -> IO ())
  , pinStage :: !(PinCheckpoint -> ByteString -> IO ())
  , phase :: !(Phase -> IO ())
    -- ^ Runs in the cleanup worker before each phase; a throw fails the attempt.
  , signal :: !(CInt -> CInt -> IO CInt)
  , closeFd :: !(CInt -> IO ())
  , retired :: !(Retirement -> IO ())
  , lockBusy :: !(IO ())
    -- ^ Called once, with the removal watch already armed, when convergence finds a
    -- starting daemon's lock held and is about to wait for its release.
  , lockWait :: !(Bool -> IO ())
    -- ^ Called by convergence with whether it had to wait for a starting daemon's lock.
  , startMs :: !Int
  , graceMs :: !Int
  , killMs :: !Int
  , lockMs :: !Int
  , clientMs :: !Int
  , versionMicros :: !Int
    -- ^ Deadline for each read that admits the daemon: its identity, then its release.
  , occupied :: !(Maybe ByteString)
    -- ^ An existing socket path injected by a test to model a borrowed
    -- server. Nothing in it is created, signaled or removed.
  }

defaultProbe :: Probe
defaultProbe = Probe
  { hooks = P.defaultHooks, spawn = defaultSpawn, root = "/tmp", features = cDaemonFeatures
  , stage = \_ _ -> pure (), pinStage = \_ _ -> pure (), phase = \_ -> pure ()
  , signal = N.cSignal, closeFd = N.close, retired = \_ -> pure (), lockBusy = pure (), lockWait = \_ -> pure ()
  , startMs = 5000, graceMs = 250, killMs = 2000, lockMs = 2000, clientMs = 2000, versionMicros = 2000000, occupied = Nothing }

-- | A worker nobody throws to. It inherits the caller's masked state.
defaultSpawn :: IO () -> IO ()
defaultSpawn work = void (forkIO work)

data OwnedError
  = AlreadyPresent !ByteString
    -- ^ The socket path was occupied: a borrowed server could answer start-server.
  | HostUnsupported ![Missing]
    -- ^ Refused before any directory, Runtime or process existed.
  | StartRefused !N.Failure
  | StartFailed !(Maybe N.Exit) !ByteString
  | StartTimedOut
  | LockWaitExpired
  | ListenerBusy
    -- ^ The listener's backlog is full: it exists, but no pidfd could be taken now.
  | NoDaemon
    -- ^ No listener was found. This does not prove that no daemon exists: the owner is retained.
  | DaemonMismatch !Integer !(Maybe Integer)
  | StaleGeneration
    -- ^ The adopted inode has no live listener while its daemon runs (rebound).
  | NotRetired !Owner !String
    -- ^ Uncertainty: the owner still holds its journal; retry with 'settle'.
  | CleanupPending !String
    -- ^ The pool, its pin or an operation worker has not finished, or a private name no
    -- longer denotes what this run created and was left in place.
  | OperationsUnresolved !Int
    -- ^ Operations without a published outcome remain after the daemon exited.
  deriving stock (Show)
instance Exception OwnedError

-- | Everything one run acquired and has not yet released, as a single value.
data Held = Held
  { created :: !(Maybe Names) -- ^ Private directory made here, until removed.
  , directoryId :: !(Maybe Identity)
    -- ^ The directory's inode when it was made; without it nothing under 'created' is removed.
  , directoryAnchor :: !(Maybe CInt) -- ^ Keeps the directory identity alive across rename or deletion.
  , client :: !(Maybe P.Ticket) -- ^ Start client, until its pool job is gone.
  , launched :: !Bool
    -- ^ A start client ran and neither a pidfd nor a launch refusal accounts for what it may have started.
  , pidfd :: !(Maybe CInt) -- ^ The listener's pidfd, until exit is proven or released.
  , anchor :: !(Maybe CInt) -- ^ O_PATH descriptor on the adopted inode.
  , socketAnchor :: !(Maybe CInt)
    -- ^ O_PATH descriptor on the socket inode the listener pidfd was taken through. It names the
    -- one socket this run may unlink, and keeps that inode number from being reused until then.
  , exit :: !(Maybe Retirement) -- ^ Exit proven through the pidfd.
  , fate :: !Fate -- ^ The disposition requested for the daemon, read by every attempt.
  }

-- | Device and inode: what a name must still denote for this run to remove it.
type Identity = (DeviceID, FileID)

identity :: Files.FileStatus -> Identity
identity status = (Files.deviceID status, Files.fileID status)

emptyHeld :: Fate -> Held
emptyHeld = Held Nothing Nothing Nothing Nothing False Nothing Nothing Nothing Nothing

-- | The journal plus the gate that serializes every attempt on it.
data Owner = Owner
  { probe :: !Probe, executable :: !ByteString
  , scope :: !(Maybe (R.Runtime, R.ServerOwner))
  , gate :: !(MVar ()), held :: !(IORef Held)
  }
instance Show Owner where
  show _ = "Owner"

-- | Reachable cleanup ownership attached to the exception of an unsettled run,
-- with the failure that stopped the attempt, when there was one.
data OwnedRecovery = OwnedRecovery !Owner !(Maybe SomeException)
instance Show OwnedRecovery where
  show _ = "OwnedRecovery"
instance ExceptionAnnotation OwnedRecovery

ownedRecoveries :: ExceptionContext -> [OwnedRecovery]
ownedRecoveries = Context.getExceptionAnnotations

recoveryOwner :: OwnedRecovery -> Owner
recoveryOwner (OwnedRecovery owner _) = owner

-- | The cleanup failure that stopped the attempt: a name-removal, pool or physical
-- failure is kept here when the callback's own exception stays primary.
recoveryFailure :: OwnedRecovery -> Maybe SomeException
recoveryFailure (OwnedRecovery _ failure) = failure

-- | A pinned, version-qualified handle onto the owned daemon.
data Owned = Owned
  { runtime :: !R.Runtime, handle :: !R.ServerHandle, executable :: !ByteString
  , names :: !Names, daemonPid :: !Integer
  , owner :: !Owner
    -- ^ The joint cleanup owner. 'killOwner' retires the daemon through it; 'settle' stays the full cleanup.
  }

newOwner :: Probe -> ByteString -> IO Owner
newOwner probe executable = mask_ $ do
  runtime <- R.newRuntime P.normalFork
  serverOwner <- R.newServerOwner runtime
  newCell probe executable (Just (runtime, serverOwner)) Terminate

newCell :: Probe -> ByteString -> Maybe (R.Runtime, R.ServerOwner) -> Fate -> IO Owner
newCell probe executable scope fate = Owner probe executable scope <$> newMVar () <*> newIORef (emptyHeld fate)

journal :: Owner -> (Held -> Held) -> IO ()
journal owner change = atomicModifyIORef' owner.held (\held -> (change held, ()))

-- | Journal a requested disposition before any effect. 'Terminate' is never lowered here.
requestFate :: Owner -> Fate -> IO ()
requestFate owner wanted = journal owner (\held -> held {fate = max held.fate wanted})

-- | Refuse an unsupported host before anything is created. 'spawning' adds the
-- launch operations the owned path needs and a kill capability does not.
requireHost :: Probe -> Bool -> IO ()
requireHost probe spawning = do
  bits <- probe.features
  spawnMissing <- if spawning then N.missingFeatures else pure []
  let missing = map Spawn spawnMissing
        <> [feature | (bit, feature) <- [(1, PeerPidfd), (2, PidfdSignal), (4, ProcFdinfo)], bits .&. bit == 0]
  unless (null missing) (throwIO (HostUnsupported missing))

withOwnedServer :: ByteString -> (Owned -> IO a) -> IO a
withOwnedServer = withOwnedServerWith defaultProbe

-- | Create a private directory, start and admit a daemon, run the callback, then
-- retire that daemon's process and remove the names created here. The callback's
-- exception or cancellation keeps its class; cleanup uncertainty adds an
-- 'OwnedRecovery' to its context. A second asynchronous exception during the wait
-- is attached there too (the first exception stays primary); the cleanup worker still
-- finishes.
withOwnedServerWith :: Probe -> ByteString -> (Owned -> IO a) -> IO a
withOwnedServerWith probe executable action = mask $ \restore -> do
  requireHost probe True
  owner <- newOwner probe executable
  primary <- tryWithContext @SomeException (restore (run owner action))
  closing <- tryWithContext @SomeException (settle owner)
  conclude owner primary closing

-- | Keep the callback's failure primary, whatever interrupts the cleanup wait; keep the
-- cleanup failure reachable. Without a callback failure, a cleanup failure is the result.
conclude
  :: Owner -> Either (ExceptionWithContext SomeException) a
  -> Either (ExceptionWithContext SomeException) () -> IO a
conclude owner primary closing = case (primary, closing) of
  (Right value, Right ()) -> pure value
  (Left failure, Right ()) -> rethrowIO failure
  (Left failure, Left (ExceptionWithContext _ cause)) -> rethrowIO (annotatedBy owner cause failure)
  (Right _, Left problem) -> rethrowIO (annotated owner problem)

annotated :: Owner -> ExceptionWithContext SomeException -> ExceptionWithContext SomeException
annotated owner problem@(ExceptionWithContext _ cause) = annotatedBy owner cause problem

-- | Attach the owner once: an exception that already carries it keeps its first annotation.
annotatedBy :: Owner -> SomeException -> ExceptionWithContext SomeException -> ExceptionWithContext SomeException
annotatedBy owner cause (ExceptionWithContext context problem)
  | any (\(OwnedRecovery other _) -> other.gate == owner.gate) (ownedRecoveries context) =
      ExceptionWithContext context problem
  | otherwise = ExceptionWithContext (Context.addExceptionAnnotation (OwnedRecovery owner (Just cause)) context) problem

-- | Run one cleanup attempt in its own worker and wait for it interruptibly.
-- Attempts for one owner queue behind its gate, so two settlers never signal or
-- close the same descriptor, and a failed attempt leaves its journal for the next.
serialized :: Owner -> IO a -> IO a
serialized owner work = mask_ $ do
  done <- newEmptyTMVarIO
  owner.probe.spawn $ do
    myThreadId >>= \self -> labelThread self "libtmux-owned-cleanup"
    outcome <- try @SomeException (withMVar owner.gate (const work))
    atomically (putTMVar done outcome)
  atomically (readTMVar done) >>= either throwIO pure

-- | Retry cleanup for a retained 'Owner': retire the daemon as its journaled 'Fate'
-- requires, shut the pool and pin down, retire logical debt, and only then remove the
-- names created here.
settle :: Owner -> IO ()
settle owner = serialized owner (cleanup owner)

cleanup :: Owner -> IO ()
cleanup owner = do
  daemonPhases owner
  forM_ owner.scope $ \(runtime, serverOwner) -> do
    step owner PhasePool (endPool runtime serverOwner)
    step owner PhaseOperations (endOperations runtime serverOwner)
  step owner PhaseNames (endNames owner)

-- | The phases that end the physical daemon: its start client, then the daemon itself.
daemonPhases :: Owner -> IO ()
daemonPhases owner = do
  step owner PhaseDaemon (endDaemon owner)
  forM_ owner.scope $ \(_, serverOwner) -> step owner PhaseClient (endClient owner serverOwner)

step :: Owner -> Phase -> IO () -> IO ()
step owner point work = owner.probe.phase point >> work

run :: Owner -> (Owned -> IO a) -> IO a
run owner action = case owner.scope of
  Nothing -> throwIO (userError "owner has no registered server owner")
  Just (runtime, serverOwner) -> do
    let probe = owner.probe
        executable = owner.executable
    names <- placement owner
    present <- statusIfPresent names.socket
    forM_ present (\_ -> throwIO (AlreadyPresent names.socket))
    pidfd <- startForeground owner names serverOwner
    probe.stage ClientExited names
    probe.stage DaemonOwned names
    server <- R.adoptServerOwnerWith probe.pinStage runtime serverOwner names.socket names.directory
    reported <- verifyPinned probe runtime server executable pidfd
    probe.stage Verified names
    qualify probe runtime server executable
    probe.stage Admitted names
    action Owned {runtime, handle = server, executable, names, daemonPid = reported, owner}

placement :: Owner -> IO Names
placement owner = case owner.probe.occupied of
  Just socket -> pure (Names (parentOf socket) socket)
  Nothing -> mask_ $ do
    directory <- mkdtemp (owner.probe.root <> "/libtmux-haskell-")
    let names = Names directory (directory <> "/s")
    journal owner (\held -> held {created = Just names})
    status <- Files.getSymbolicLinkStatus directory
    journal owner (\held -> held {directoryId = Just (identity status)})
    fd <- openAnchor directory >>= either N.raise pure
    journal owner (\held -> held {directoryAnchor = Just fd})
    pure names
  where
    parentOf path = let prefix = fst (Bytes.breakEnd (== 47) path) in
      if Bytes.length prefix > 1 then Bytes.init prefix else prefix

startSpec :: ByteString -> ByteString -> N.Spec
startSpec executable socket = N.spec executable
  [executable, "-D", "-u", "-S", socket, "-f", "/dev/null"]

-- SPIKE: the existing pool owns the native birth, bounded streams and collection.
-- The joint owner takes a separate pidfd for retirement and verifies that the
-- listener is that direct process; native tmux -D does not daemonize.
startForeground :: Owner -> Names -> R.ServerOwner -> IO CInt
startForeground owner names serverOwner = bracket arm N.close $ \watch -> do
  ready <- timeout (owner.probe.startMs * 1000) $ do
    ticket <- mask_ $ do
      started <- P.submit B.Ordinary owner.probe.hooks (R.serverOwnerPool serverOwner)
        (startSpec owner.executable names.socket) ""
      journal owner (\held -> held {client = Just started})
      pure started
    owner.probe.stage ClientLaunched names
    atomically (readTMVar ticket.launchEvidence) >>= \case
      P.LaunchRefused failure -> throwIO (StartRefused failure)
      P.NativeStarted -> pure ()
    descriptor <- mask_ $ withMVar ticket.signalLock $ \_ -> do
      child <- readIORef ticket.child
      descriptors <- readIORef ticket.descriptors
      case child of
        Just native | IntSet.member (fromIntegral native.pidfd) descriptors -> do
          copy <- cDup native.pidfd
          when (copy < 0) (N.raise (negate copy))
          journal owner (\held -> held {pidfd = Just copy})
          pure (Just copy)
        _ -> pure Nothing
    case descriptor of
      Nothing -> P.await ticket >>= \done -> throwIO (StartFailed done.exit done.errors)
      Just fd -> race (P.await ticket) (listener watch fd) >>= \case
        Left done -> throwIO (StartFailed done.exit done.errors)
        Right () -> pure fd
  maybe (throwIO StartTimedOut) pure ready
  where
    arm = Bytes.useAsCString names.directory $ \directory -> cWatchStart directory >>= \fd ->
      if fd < 0 then N.raise (negate fd) else pure fd
    listener watch direct = mask_ $ anchoredPeer names.socket >>= \case
      Right (anchor, peer) -> do
        (expected, observed) <- finally ((,) <$> pidfdPid direct <*> pidfdPid peer) (N.close peer)
        if isJust expected && expected == observed
          then journal owner (\held -> held {socketAnchor = Just anchor})
          else do
            N.close anchor
            journal owner (\held -> held {launched = True})
            throwIO (DaemonMismatch (maybe 0 id observed) expected)
      Left problem
        | problem == N.errno eNOENT || problem == N.errno eCONNREFUSED -> do
            threadWaitRead (Fd watch)
            rc <- cWatchDrain watch
            when (rc < 0) (N.raise (negate rc))
            listener watch direct
        | problem == N.errno eAGAIN -> throwIO ListenerBusy
        | otherwise -> N.raise problem


-- | Converge on the listener's pidfd. The start client must already be dead, so
-- no new daemon can appear: a daemon still before listen() holds the lock, and
-- its release means it is listening or gone. Nothing listening is 'Nothing': it
-- records nothing and never proves that a daemon is gone or was never born.
converge :: Owner -> Names -> IO (Maybe CInt)
converge owner names = do
  waited <- timeout (owner.probe.lockMs * 1000) (awaitLock names.directory (names.socket <> ".lock") owner.probe.lockBusy)
    >>= maybe (throwIO LockWaitExpired) pure
  owner.probe.lockWait waited
  mask_ $ anchoredPeer names.socket >>= \case
    Right (anchor, fd) -> Just fd <$ journal owner (\held -> held {pidfd = Just fd, socketAnchor = Just anchor})
    Left problem
      | problem == N.errno eNOENT || problem == N.errno eCONNREFUSED -> pure Nothing
      | problem == N.errno eAGAIN -> throwIO ListenerBusy
      | otherwise -> N.raise problem

-- | Wait until no starting daemon holds the lock; true when a holder had to be
-- waited for. The daemon unlinks the lock right after listen, which the armed
-- directory watch reports; a daemon that dies releases the lock without an
-- event, which the probe sees at once. The caller bounds the wait.
awaitLock :: ByteString -> ByteString -> IO () -> IO Bool
awaitLock directory lock busy = bracket arm N.close (\watch -> loop watch False)
  where
    arm = Bytes.useAsCString directory $ \c -> cWatchRemovals c >>= checked
    held = Bytes.useAsCString lock $ \c -> (== 1) <$> (cLockHeld c >>= checked)
    checked rc = if rc < 0 then N.raise (negate rc) else pure rc
    loop watch waited = held >>= \case
      False -> pure waited
      True -> do
        unless waited busy
        threadWaitRead (Fd watch)
        void (cWatchDrain watch >>= checked)
        loop watch True

-- | A pidfd for the listener of a socket path, or the errno. Never blocks.
peerPidfd :: ByteString -> IO (Either CInt CInt)
peerPidfd path = Bytes.useAsCString path $ \c -> do
  rc <- cPeerPidfd c
  pure (if rc >= 0 then Right rc else Left (negate rc))

-- | An anchor on the socket inode a path names, and the listener pidfd taken through that same
-- anchor, so the identity the anchor reports is the process capability's own inode.
anchoredPeer :: ByteString -> IO (Either CInt (CInt, CInt))
anchoredPeer path = openAnchor path >>= \case
  Left problem -> pure (Left problem)
  Right anchor -> peerVia anchor >>= \case
    Left problem -> Left problem <$ N.close anchor
    Right pidfd -> pure (Right (anchor, pidfd))

-- | The same, through a held anchor descriptor rather than a directory entry.
peerVia :: CInt -> IO (Either CInt CInt)
peerVia anchor = peerPidfd ("/proc/self/fd/" <> Ascii.pack (show anchor))

openAnchor :: ByteString -> IO (Either CInt CInt)
openAnchor path = Bytes.useAsCString path $ \c -> do
  rc <- cAnchor c
  pure (if rc >= 0 then Right rc else Left (negate rc))

-- | True once the pidfd is readable or hung up, which for a process means it has
-- exited. False on timeout. An invalid descriptor raises: it is never an exit.
-- The wait is an event registration under a Haskell deadline, so no OS thread
-- blocks and an interrupted system call cannot restart the timeout; the native
-- poll then classifies the event bits.
awaitExit :: CInt -> Int -> IO Bool
awaitExit pidfd milliseconds = do
  when (pidfd < 0) (N.raise (N.errno eBADF))
  readable <- if milliseconds <= 0 then pure True
    else isJust <$> timeout (milliseconds * 1000) (threadWaitRead (Fd pidfd))
  if not readable then pure False else cPoll pidfd 0 >>= \rc ->
    if rc < 0 then N.raise (negate rc) else pure (rc > 0)

-- | The process a pidfd names, from its fdinfo; Nothing once it has exited.
pidfdPid :: CInt -> IO (Maybe Integer)
pidfdPid pidfd = do
  info <- Bytes.readFile ("/proc/self/fdinfo/" <> show pidfd)
  pure $ listToMaybe
    [ pid | line <- Ascii.lines info, Just rest <- [Bytes.stripPrefix "Pid:" line]
          , Just (pid, _) <- [Ascii.readInteger (Ascii.dropWhile isSpace rest)], pid > 0 ]

-- | The pinned daemon's own report must name the process this pidfd holds. The
-- pidfd is live now and was opened before this answer, so PID reuse cannot
-- make a different process agree.
-- The read runs no command hook, so a configured daemon is identified like any other.
verifyPinned :: Probe -> R.Runtime -> R.ServerHandle -> ByteString -> CInt -> IO Integer
verifyPinned probe runtime server executable pidfd = do
  (_, _, reported) <- C.captureIdentityWith probe.hooks runtime server executable probe.versionMicros
  owned <- pidfdPid pidfd
  gone <- awaitExit pidfd 0
  when (gone || owned /= Just reported) (throwIO (DaemonMismatch reported owned))
  pure reported

qualify :: Probe -> R.Runtime -> R.ServerHandle -> ByteString -> IO ()
qualify probe runtime server executable = do
  (_, _, version) <- C.captureVersionWith probe.hooks runtime server executable probe.versionMicros
  either (throwIO . UnsupportedTmuxVersion) (const (pure ())) (Version.requireSupported version)

uncertain :: Owner -> String -> IO a
uncertain owner = throwIO . NotRetired owner

-- | Phase: the start client must be gone from its pool before the daemon search,
-- so no new daemon can appear. A client whose job is still registered, including
-- one with failed cleanup, keeps the attempt open.
endClient :: Owner -> R.ServerOwner -> IO ()
endClient owner serverOwner = readIORef owner.held >>= \held -> forM_ held.client $ \ticket -> do
  let pool = R.serverOwnerPool serverOwner
  P.abort ticket
  P.resumeCleanup pool ticket
  gone <- timeout (owner.probe.clientMs * 1000) $ atomically $
    readTVar pool.jobs >>= \jobs -> check (not (IntMap.member ticket.key jobs))
  when (isNothing gone) (uncertain owner "the start client did not exit")
  -- A refused launch ran no child, so no daemon can exist. Any other evidence, or none, does not say.
  evidence <- atomically (tryReadTMVar ticket.launchEvidence)
  let refused = case evidence of Just (P.LaunchRefused _) -> True; _ -> False
  journal owner (\current -> current {client = Nothing, launched = current.launched && not refused})

-- | Phase: find the listener while a launched client's daemon is unaccounted for, then
-- act on it as the journaled 'Fate' says. Descriptors are journaled away before they are
-- closed, so a failed close can leak but never close a recycled descriptor twice.
endDaemon :: Owner -> IO ()
endDaemon owner = do
  held <- readIORef owner.held
  unless (isJust held.exit) $ do
    found <- case held.pidfd of
      Just fd -> pure (Just fd)
      Nothing | held.launched -> Just <$> findListener owner held.created
              | otherwise -> pure Nothing
    forM_ found (retire owner)
  releaseAnchor owner
  latest <- readIORef owner.held
  when latest.launched $
    uncertain owner "the foreground launcher changed identity; startup descendants remain unaccounted for"

-- | The listener's pidfd, or the uncertainty that keeps the owner: no listener found is not
-- proof that the launched client's daemon is gone.
findListener :: Owner -> Maybe Names -> IO CInt
findListener owner names = do
  found <- forM names $ \known -> converge owner known `catch` \(problem :: OwnedError) -> case problem of
    LockWaitExpired -> uncertain owner "a starting daemon still holds its lock"
    ListenerBusy -> uncertain owner "the listener's backlog is full, so no pidfd could be taken"
    _ -> throwIO problem
  case join found of
    Just pidfd -> pure pidfd
    Nothing -> uncertain owner "no listener was found, but the start client ran: an absent or refusing socket and a finished client do not prove that its daemon is gone"

retire :: Owner -> CInt -> IO ()
retire owner pidfd = do
  held <- readIORef owner.held
  case held.fate of
    Release -> forget Nothing
    Terminate -> do
      -- A rebound generation can never be killed through this capability: withdraw the request.
      forM_ held.anchor $ \anchor -> checkGeneration anchor pidfd `catch` \(problem :: OwnedError) -> case problem of
        StaleGeneration -> journal owner (\current -> current {fate = Release}) >> throwIO problem
        _ -> throwIO problem
      (how, refused) <- terminate owner.probe pidfd
      case how of
        Nothing -> uncertain owner ("daemon pidfd did not become readable"
          <> (if null refused then "" else "; signals refused: " <> show refused))
        Just outcome -> forget (Just outcome) >> owner.probe.retired outcome
  where
    forget outcome = mask_ $ do
      journal owner (\held -> held {pidfd = Nothing, exit = outcome})
      owner.probe.closeFd pidfd

-- | An adopted capability terminates only the generation it was admitted for. A
-- daemon that already exited is accounted for by its pidfd. Otherwise the pinned
-- inode must still have a live listener belonging to the same process: a refused
-- connect means the socket was rebound, and a full backlog is a wedged but live
-- listener on that inode.
checkGeneration :: CInt -> CInt -> IO ()
checkGeneration anchor pidfd = awaitExit pidfd 0 >>= \case
  True -> pure ()
  False -> peerVia anchor >>= \case
    Right other -> do
      same <- ((==) <$> pidfdPid other <*> pidfdPid pidfd) `finally` N.close other
      unless same (throwIO StaleGeneration)
    Left problem
      | problem == N.errno eAGAIN -> pure ()
      | problem == N.errno eCONNREFUSED -> throwIO StaleGeneration
      | otherwise -> N.raise problem

-- | Terminate through the pidfd, then kill it, observing exit by readability.
-- Nothing means no exit was observed and ownership must be retained; the errnos
-- are signals the kernel refused.
terminate :: Probe -> CInt -> IO (Maybe Retirement, [CInt])
terminate probe pidfd = awaitExit pidfd 0 >>= \case
  True -> pure (Just AlreadyGone, [])
  False -> do
    first <- send sigTERM
    awaitExit pidfd probe.graceMs >>= \case
      True -> pure (Just Terminated, first)
      False -> do
        second <- send sigKILL
        awaitExit pidfd probe.killMs >>= \case
          True -> pure (Just Killed, first <> second)
          False -> pure (Nothing, first <> second)
  where
    send signalNumber = probe.signal pidfd signalNumber >>= \rc ->
      pure [rc | rc /= 0 && rc /= N.errno eSRCH]

releaseAnchor :: Owner -> IO ()
releaseAnchor owner = readIORef owner.held >>= \held -> forM_ held.anchor $ \fd -> mask_ $ do
  journal owner (\current -> current {anchor = Nothing})
  owner.probe.closeFd fd

-- | Phase: close the pool and its pin, retrying a failed earlier attempt, and
-- keep every incomplete owner reachable instead of reporting success.
endPool :: R.Runtime -> R.ServerOwner -> IO ()
endPool runtime serverOwner = do
  report <- R.shutdownServerOwner runtime serverOwner
  unless (null report.pending && null report.readWorkers && null report.closeFailures)
    (throwIO (CleanupPending (show report)))

-- | Phase: detach what the exited daemon can no longer resolve. See the module
-- header; an operation without an outcome stays retained and fails the attempt.
endOperations :: R.Runtime -> R.ServerOwner -> IO ()
endOperations runtime serverOwner = do
  remaining <- atomically $ do
    before <- R.inspectServerOwner runtime serverOwner
    forM_ before.unresolved $ \(operation, _) -> R.detachServerOwnerOperation runtime serverOwner operation
    (.unresolved) <$> R.inspectServerOwner runtime serverOwner
  unless (null remaining) (throwIO (OperationsUnresolved (length remaining)))

-- | Phase: remove only names this run created and can still identify, after the daemon is
-- proven gone and the pin is closed. The directory must still be the inode made here and the
-- socket the inode the listener pidfd came from; a replacement, and everything inside a
-- replaced directory, is left alone and reported. The startup lock is never unlinked: tmux
-- removes it once it listens, so a lock name now is not ours. A nonempty directory is
-- reported, not forced, and stays journaled.
endNames :: Owner -> IO ()
endNames owner = readIORef owner.held >>= \held -> mask_ $ do
  forM_ held.created $ \names -> do
    fd <- case held.directoryAnchor of
      Just owned -> pure owned
      Nothing -> do
        current <- statusIfPresent names.directory
        unless (maybe False (\entry -> Files.isDirectory entry && Just (identity entry) == held.directoryId) current) $
          replaced "private directory" names.directory
        acquired <- openAnchor names.directory >>= either N.raise pure
        journal owner (\state -> state {directoryAnchor = Just acquired})
        pure acquired
    original <- Files.getFdStatus (Fd fd)
    unless (Files.isDirectory original && Just (identity original) == held.directoryId) $ do
      journal owner (\state -> state {directoryAnchor = Nothing})
      N.close fd
      replaced "private directory" names.directory
    -- A vanished path can be a rename; only an unlinked held directory proves removal.
    unless (Files.linkCount original == 0) $ do
      current <- statusIfPresent names.directory
      unless (maybe False (\entry -> Files.isDirectory entry && identity entry == identity original) current) $
        replaced "private directory" names.directory
      anchored <- forM held.socketAnchor (Files.getFdStatus . Fd)
      statusIfPresent names.socket >>= mapM_ (\socket ->
        if Files.isSocket socket && any (\inode -> Files.isSocket inode && identity inode == identity socket) anchored
          then ignoreMissing (Files.removeLink names.socket)
          else replaced "socket" names.socket)
      ignoreMissing (removeDirectory names.directory)
  journal owner (\current -> current {created = Nothing, directoryId = Nothing})
  forM_ held.socketAnchor $ \fd -> do
    journal owner (\current -> current {socketAnchor = Nothing})
    N.close fd
  latest <- readIORef owner.held
  forM_ latest.directoryAnchor $ \fd -> do
    journal owner (\current -> current {directoryAnchor = Nothing})
    N.close fd
  where
    replaced what path = throwIO (CleanupPending
      (what <> " " <> show path <> " no longer names what this run created; it was left in place"))

-- | A private capability to end an adopted daemon generation. It holds the
-- daemon's pidfd and an O_PATH anchor on the pinned inode, both taken and verified
-- at admission, so using it needs no tmux command, no Runtime lane and no open
-- pin or pool.
newtype Kill = Kill Owner

-- | Run the callback with the capability for a pinned server, or with the failure that prevented
-- it, so that plain adoption and capture stay possible where no kill can be verified (an
-- unsupported host, a listener that is not the daemon, an identity read that failed). The
-- listener is reached through the pin by kernel identity and must be the daemon that answers
-- @#{pid}@ now. A non-asynchronous admission failure whose partial capability was released
-- reaches the callback; a failed release, an asynchronous exception, or a failure of the callback
-- itself never does: each keeps its owner.
--
-- When the callback leaves, this server's admission closes before any descriptor is released, so
-- a kill that has not passed its check refuses. The descriptors are then released unless an
-- explicit kill was requested and has not finished: that request stays journaled, so the release
-- repeats the kill and a failure keeps the descriptors for a resume.
withKillCapability :: Probe -> ByteString -> R.Runtime -> R.ServerHandle -> (Either SomeException Kill -> IO a) -> IO a
withKillCapability probe executable runtime server action = mask $ \restore -> do
  owner <- newCell probe executable Nothing Release
  admission <- tryWithContext @SomeException (restore (requireHost probe False >> admit owner))
  case admission of
    Right () -> scoped owner restore (Right (Kill owner))
    Left failure@(ExceptionWithContext context cause)
      | isJust (fromException @SomeAsyncException cause) -> do
          closing <- tryWithContext @SomeException (settle owner)
          conclude owner (Left failure) closing
      | otherwise -> do
          -- The failure is stored, not rethrown, so nobody else can release what its read still retains.
          forM_ (Context.getExceptionAnnotations context) (releaseRead probe)
          closing <- tryWithContext @SomeException (settle owner)
          either (conclude owner (Left failure) . Left) (const (scoped owner restore (Left cause))) closing
  where
    scoped owner restore capability = do
      primary <- tryWithContext @SomeException (restore (action capability))
      atomically (R.closeServerHandleAdmission runtime server)
      closing <- tryWithContext @SomeException (settle owner)
      conclude owner primary closing
    admit owner = do
      anchor <- mask_ $ openAnchor (pinPath (R.serverPin server)) >>= \case
        Left problem -> N.raise problem
        Right fd -> fd <$ journal owner (\held -> held {anchor = Just fd})
      pidfd <- mask_ $ peerVia anchor >>= \case
        Left problem | problem == N.errno eAGAIN -> throwIO ListenerBusy
                     | otherwise -> N.raise problem
        Right fd -> fd <$ journal owner (\held -> held {pidfd = Just fd})
      void (verifyPinned probe runtime server executable pidfd)

-- | A failed admission read changed nothing in the daemon. Once its worker has published an
-- outcome its logical debt is dropped; its native owner stays with the pool. A worker that
-- publishes nothing within the client bound keeps the debt, which then fails the scope's own
-- cleanup with a recovery instead of disappearing.
releaseRead :: Probe -> C.CaptureRecovery -> IO ()
releaseRead probe recovery = void $ timeout (probe.clientMs * 1000) $ atomically $ do
  state <- C.inspectRecovery recovery
  check (isJust state.logical.outcome)
  void (C.detachRecovery recovery)

-- | End the adopted daemon through its held pidfd. 'StaleGeneration' refuses a
-- rebound socket and leaves the daemon untouched; that refusal withdraws the kill, so the
-- scope's release only drops the descriptors.
killAdopted :: Kill -> IO Retirement
killAdopted (Kill owner) = killOwner owner

-- | Whether this handle still admits operations. Rechecked inside the owner gate.
admissionOpen :: R.ServerHandle -> IO Bool
admissionOpen server = not <$> atomically (readTVar (R.serverPool server).closing)

-- | 'killAdopted' that refuses with 'ServerClosed' unless @admitted@ holds once this request
-- owns the gate. The public Server passes its pool's admission, so a kill racing the callback's
-- exit cannot turn the scope's release into a termination.
killAdoptedIf :: IO Bool -> Kill -> IO Retirement
killAdoptedIf admitted (Kill owner) = killOwnerIf admitted owner

-- | Request the daemon's termination, retire it through the owner's pidfd and report how it
-- left. Only the physical daemon is ended: the pool, its operations and the names stay for
-- the scope's own release ('settle'). The request is journaled first, and a failure or
-- cancellation carries the owner from the moment it is raised, so a callback that catches it
-- can still recover.
killOwner :: Owner -> IO Retirement
killOwner = killOwnerIf (pure True)

-- | 'killOwner' for a caller that may refuse. The check and the 'Terminate' request happen inside
-- the owner's gate, so a refusal ('ServerClosed') leaves the journal as it was and a request that
-- passed the check keeps its authority over any release attempt that follows it.
killOwnerIf :: IO Bool -> Owner -> IO Retirement
killOwnerIf admitted owner = do
  attempt <- tryWithContext @SomeException $ serialized owner $ admitted >>= \case
    False -> pure False
    True -> True <$ (requestFate owner Terminate >> daemonPhases owner)
  case attempt of
    Left failure -> rethrowIO (annotated owner failure)
    Right False -> throwIO ServerClosed
    Right True -> readIORef owner.held >>= maybe (throwIO NoDaemon) pure . (.exit)

statusIfPresent :: ByteString -> IO (Maybe Files.FileStatus)
statusIfPresent path = (Just <$> Files.getSymbolicLinkStatus path) `catch` \(problem :: IOException) ->
  if isDoesNotExistError problem then pure Nothing else throwIO problem

ignoreMissing :: IO () -> IO ()
ignoreMissing action = action `catch` \(problem :: IOException) ->
  if isDoesNotExistError problem then pure () else throwIO problem

-- Public recovery bridge ---------------------------------------------------------------------

-- | Marks an owner whose public recovery already rides on an exception, so that catching and
-- rethrowing it again attaches nothing new.
newtype Promoted = Promoted (MVar ())
instance Show Promoted where
  show _ = "Promoted"
instance ExceptionAnnotation Promoted

-- | Give every owner on this exception the public recovery API of "LibTmux.Internal.Scope",
-- once per owner, so inspection, retry and waiting work through the same functions as for a
-- Runtime scope.
promoteRecoveries :: ExceptionWithContext SomeException -> IO (ExceptionWithContext SomeException)
promoteRecoveries (ExceptionWithContext context problem) = do
  promoted <- foldM promote context (ownedRecoveries context)
  pure (ExceptionWithContext promoted problem)
  where
    promote current (OwnedRecovery owner failure)
      | any (\(Promoted gate) -> gate == owner.gate) (Context.getExceptionAnnotations current) = pure current
      | otherwise = do
          status <- observeOwned owner
          pure (Context.addExceptionAnnotation (Promoted owner.gate)
            (Context.addExceptionAnnotation (Scope.customCleanupRecovery (cleanupActions owner) status failure) current))

cleanupActions :: Owner -> Scope.CleanupActions
cleanupActions owner = Scope.CleanupActions
  { Scope.observeCleanup = observeOwned owner
  , Scope.requestCleanup = settle owner >> observeOwned owner
  , Scope.waitCleanup = awaitOwned owner >> observeOwned owner
  , Scope.detachCleanup = \operation -> case owner.scope of
      Nothing -> pure False
      Just (runtime, serverOwner) -> atomically (R.detachServerOwnerOperation runtime serverOwner operation)
  }

-- | The pool's report, with every descriptor, directory, client and unaccounted launch the journal
-- still holds counted as one pending handle, so a retained owner is never reported complete.
observeOwned :: Owner -> IO CleanupStatus
observeOwned owner = do
  held <- readIORef owner.held
  status <- case owner.scope of
    Nothing -> pure (CleanupStatus True 0 0 [] [])
    Just (runtime, serverOwner) -> Scope.observed <$> atomically (R.inspectServerOwner runtime serverOwner)
  let pending = isJust held.created || isJust held.client || isJust held.pidfd || isJust held.anchor
        || isJust held.directoryAnchor || isJust held.socketAnchor
        || (held.launched && isNothing held.exit)
  pure status
    { complete = status.complete && not pending
    , pendingHandles = status.pendingHandles + if pending then 1 else 0 }

-- | Settle, and when the daemon was not yet seen to exit, wait for the event that can change that
-- before settling once more. A held daemon descriptor is awaited through a duplicate taken under
-- the gate, so no attempt can recycle it. Without one, the wait is for the start client's pool job
-- to leave. A launch that found no listener and a starting daemon that holds its lock have no
-- event to wait for: the second attempt is one more bounded search, and its failure keeps the
-- owner. Nothing here polls, and completion is only ever what 'settle' returns.
awaitOwned :: Owner -> IO ()
awaitOwned owner = catchNoPropagate (settle owner) $ \problem@(ExceptionWithContext _ cause) ->
  case fromException @OwnedError cause of
    Just (NotRetired _ _) -> do
      bracket (withMVar owner.gate (const (readIORef owner.held >>= traverse duplicate . (.pidfd)))) (mapM_ N.close) $ \case
        Just descriptor -> threadWaitRead (Fd descriptor)
        Nothing -> maybe (rethrowIO problem) (uncurry R.awaitServerOwnerCleanup) owner.scope
      settle owner
    Just (CleanupPending _) -> do
      maybe (rethrowIO problem) (uncurry R.awaitServerOwnerCleanup) owner.scope
      settle owner
    _ -> rethrowIO problem
  where
    duplicate descriptor = cDup descriptor >>= \rc -> if rc < 0 then N.raise (negate rc) else pure rc
