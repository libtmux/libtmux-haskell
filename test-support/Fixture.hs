module Fixture
  ( Fixture (..), StartupStage (..), Daemon (..), Retirement (..), retirement
  , withFixture, withFixtureAt, withDaemon, retireDaemon, awaitDaemon, pollDaemon, retainedDaemons, guardRetained
  , Client (..), Stdio (..), withClient, readSome
  , withAttachedClient, command, registerPane, withTrackedPane
  ) where

import Control.Concurrent.Async (race, waitBoth, withAsync)
import Control.Concurrent.MVar (MVar, modifyMVarMasked, modifyMVarMasked_, newMVar, withMVarMasked)
import Control.Exception (SomeException, finally, mask, mask_, onException, throwIO, try, uninterruptibleMask_)
import Control.Monad (unless, when)
import Data.ByteString qualified as Strict
import Data.ByteString.Char8 qualified as Ascii
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as Lazy
import Data.ByteString.Lazy.Char8 qualified as Bytes
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import Data.Word (Word8)
import Foreign.C.Error (Errno (..), eAGAIN, eSRCH, errnoToIOError, throwErrnoIfMinus1)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (allocaArray, withArray, withArray0)
import Foreign.Marshal.Utils (withMany)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peekElemOff)
import GHC.Conc (closeFdWith, threadWaitRead, threadWaitWrite)
import GHC.Foreign qualified as Foreign
import GHC.IO.Encoding (getFileSystemEncoding)
import System.Directory (removePathForcibly)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.IO (closeFd)
import System.Posix.Temp (mkdtemp)
import System.Posix.Types (Fd (..))
import System.Timeout (timeout)

foreign import ccall unsafe "libtmux_fixture_watch"
  watchDirectory :: CString -> IO CInt

foreign import ccall unsafe "libtmux_fixture_socket_ready"
  socketReady :: CInt -> IO CInt

foreign import ccall unsafe "libtmux_fixture_pidfd"
  panePidfd :: CInt -> IO CInt

foreign import ccall unsafe "libtmux_fixture_spawn"
  spawnChild :: CString -> Ptr CString -> Ptr CString -> Ptr CInt -> Ptr CInt -> IO CInt

foreign import ccall unsafe "libtmux_fixture_read"
  readPipe :: CInt -> Ptr Word8 -> CSize -> IO CInt

foreign import ccall unsafe "libtmux_fixture_write"
  writePipe :: CInt -> Ptr Word8 -> CSize -> IO CInt

foreign import ccall unsafe "libtmux_fixture_pidfd_signal"
  signalPidfd :: CInt -> CInt -> IO CInt

foreign import ccall unsafe "libtmux_fixture_reap"
  reapPidfd :: CInt -> Ptr CInt -> IO CInt

foreign import ccall unsafe "libtmux_fixture_dup"
  duplicatePidfd :: CInt -> IO CInt

-- Safe: it blocks this OS thread for at most the bound, and no exception interrupts it.
foreign import ccall safe "libtmux_fixture_pidfd_wait"
  waitPidfd :: CInt -> CInt -> IO CInt

data Fixture = Fixture
  { directory :: !FilePath
  , socket :: !FilePath
  , executable :: !FilePath
  , environment :: ![(String, String)]
  , daemon :: !Daemon
  , paneExitObserved :: !(IORef Bool)
  }

data StartupStage = SocketReady | PaneCreated !ByteString

withFixture :: (Fixture -> IO a) -> IO a
withFixture = withFixtureAt (\_ _ -> pure ())

-- Checkpoints run after daemon ownership but before the pane tracking journal.
withFixtureAt :: (StartupStage -> Fixture -> IO ()) -> (Fixture -> IO a) -> IO a
withFixtureAt checkpoint action = do
  paneExitObserved <- newIORef False
  executable <- fromMaybe "tmux" <$> lookupEnv "LIBTMUX_TEST_TMUX"
  environment <- filter (\(key, _) -> key /= "TMUX" && key /= "TMUX_PANE") <$> getEnvironment
  scoped (mkdtemp "/tmp/libtmux-haskell-") removeUnlessRetained $ \directory ->
    scoped (openWatch directory) closeFd $ \watch ->
      scoped (newIORef Nothing) (finishPane paneExitObserved) $ \pane -> do
        let socket = directory </> "socket"
        withDaemon retirement directory executable ["-D", "-S", socket, "-f", "/dev/null"] environment $ \daemon -> do
          readiness <- race (awaitDaemon daemon) (waitReady watch)
          case readiness of
            Right () -> pure ()
            Left code -> throwIO (userError ("fixture daemon exited at startup: " <> show code))
          let fixture = Fixture {directory, socket, executable, environment, daemon, paneExitObserved}
          checkpoint SocketReady fixture
          (code, output, errors) <- command fixture
            ["new-session", "-d", "-s", "fixture", "-P", "-F", "#{pane_pid}", "/bin/cat", "-"]
          unless (code == ExitSuccess) $
            throwIO (userError ("fixture session creation failed: " <> show errors))
          checkpoint (PaneCreated output) fixture
          registerPane pane output
          action fixture

-- | A child owned through a pidfd the kernel creates with it, so the pidfd cannot name any
-- other process. Every signal and every status read goes through it and never through a PID.
-- Nothing else in the process may reap children without naming them. The fixture's server and
-- every tmux client it starts are owned this way; a retained owner keeps its 'home' directory.
data Daemon = Daemon
  { label :: !String
  , home :: !FilePath
  , pidfd :: !Fd
  , phase :: !(MVar Phase)
  , how :: !Retirement
  }

-- | How a child's standard stream is connected: to @/dev/null@, to the test's own descriptor, or
-- to a pipe whose other end the test keeps. The constructors' order is the C enumeration's.
data Stdio = Null | Inherit | Pipe deriving (Enum)

-- | A child and the parent's ends of the pipes its streams were given. An end of a stream that
-- is not a 'Pipe' is @Fd (-1)@ and is never closed.
data Client = Client
  { process :: !Daemon
  , input :: !Fd
  , output :: !Fd
  , errors :: !Fd
  }

-- | The pidfd is signaled, read for status and closed only under the 'phase' lock, in this order.
-- A wait never uses it directly: it waits on a private duplicate ('withCopy').
data Phase = Live | Reaped !ExitCode | Closed !ExitCode

-- | How long each retirement step waits, and how a signal is delivered. The kernel offers no
-- child that survives SIGKILL, so a test replaces 'deliver' to reach the retention path.
data Retirement = Retirement
  { step :: !Int
  , deliver :: !(Fd -> CInt -> IO CInt)
  }

retirement :: Retirement
retirement = Retirement {step = 2000000, deliver = \(Fd fd) signal -> signalPidfd fd signal}

-- | Acquire a resource, run the body, then release it. Unlike 'bracket', a release that fails never
-- replaces a failing body's exception, so the caller sees the primary failure and its class. A
-- release that fails after a clean body is raised. Every fixture scope concludes this way.
scoped :: IO r -> (r -> IO ()) -> (r -> IO a) -> IO a
scoped acquire release body = mask $ \restore -> do
  resource <- acquire
  outcome <- try @SomeException (restore (body resource))
  released <- try @SomeException (release resource)
  case (outcome, released) of
    (Left problem, _) -> throwIO problem
    (Right _, Left problem) -> throwIO problem
    (Right result, Right ()) -> pure result

-- | Run a child for the body and retire it afterwards. A failure of the body is rethrown as
-- it is, whether or not the retirement then succeeds; a retirement that fails after a clean
-- body is raised.
withDaemon :: Retirement -> String -> FilePath -> [String] -> [(String, String)] -> (Daemon -> IO a) -> IO a
withDaemon how label executable arguments environment body =
  scoped (startChild how label label executable arguments environment (Null, Null, Inherit)) (retireDaemon . (.process)) (body . (.process))

-- | Start a child with the standard streams connected as given. Call it masked: the pidfd and the
-- pipe ends the kernel hands back are owned by nothing until the caller's release closes them.
-- A refused start leaves no child and no descriptor.
startChild
  :: Retirement -> String -> FilePath -> FilePath -> [String] -> [(String, String)] -> (Stdio, Stdio, Stdio) -> IO Client
startChild how label home executable arguments environment (standardIn, standardOut, standardError) = do
  encoding <- getFileSystemEncoding
  let text = Foreign.withCString encoding
  withMany text (executable : arguments) $ \argv ->
    withMany text [key <> "=" <> value | (key, value) <- environment] $ \envp ->
      withArray0 nullPtr argv $ \argvArray ->
        withArray0 nullPtr envp $ \envArray ->
          withArray (map (fromIntegral . fromEnum) [standardIn, standardOut, standardError]) $ \modes ->
            text executable $ \file -> allocaArray 4 $ \out -> do
              rc <- spawnChild file argvArray envArray modes out
              unless (rc == 0) (ioError (errnoToIOError "fixture spawn" (Errno rc) Nothing (Just executable)))
              let descriptor = fmap Fd . peekElemOff out
              pidfd <- descriptor 0
              input <- descriptor 1
              output <- descriptor 2
              errors <- descriptor 3
              phase <- newMVar Live
              pure Client {process = Daemon {label, home, pidfd, phase, how}, input, output, errors}

-- | End the child through its pidfd and collect its status. Each wait is bounded; the
-- escalation is SIGTERM, then SIGKILL. A child that cannot be retired stays owned: its pidfd is
-- kept open and listed by 'retainedDaemons', and the failure is raised. Nothing here writes a
-- diagnostic, because a blocked stream inside this uninterruptible region would void the bounds.
retireDaemon :: Daemon -> IO ()
retireDaemon daemon = uninterruptibleMask_ $ do
  (end >> closeDaemon daemon) `onException` keep
  atomicModifyIORef' retained (\kept -> (filter ((/= daemon.phase) . (.phase)) kept, ()))
  where
    end = pollDaemon daemon >>= \case
      Just _ -> pure ()
      Nothing -> do
        signalDaemon daemon 15
        endedWithin >>= \case
          True -> pure ()
          False -> do
            signalDaemon daemon 9
            ended <- endedWithin
            unless ended (ioError (userError ("fixture daemon did not exit: " <> daemon.label)))
    endedWithin = do
      withCopy daemon $ \(Fd copy) -> do
        rc <- waitPidfd copy (fromIntegral (daemon.how.step `div` 1000))
        when (rc < 0) (ioError (errnoToIOError "fixture daemon wait" (Errno (negate rc)) Nothing (Just daemon.label)))
      (/= Nothing) <$> pollDaemon daemon
    keep = atomicModifyIORef' retained (\kept -> (daemon : filter ((/= daemon.phase) . (.phase)) kept, ()))

-- | The status if the child has exited, collecting it on first sight. Never blocks.
pollDaemon :: Daemon -> IO (Maybe ExitCode)
pollDaemon daemon = modifyMVarMasked daemon.phase $ \case
  Live -> allocaArray 2 $ \out -> do
    let Fd raw = daemon.pidfd
    rc <- reapPidfd raw out
    case rc of
      0 -> pure (Live, Nothing)
      1 -> do
        kind <- peekElemOff out 0
        value <- peekElemOff out 1
        let code
              | kind == 1 && value == 0 = ExitSuccess
              | kind == 1 = ExitFailure (fromIntegral value)
              | otherwise = ExitFailure (negate (fromIntegral value))
        pure (Reaped code, Just code)
      _ -> ioError (errnoToIOError "fixture daemon status" (Errno (negate rc)) Nothing (Just daemon.label))
  state@(Reaped code) -> pure (state, Just code)
  state@(Closed code) -> pure (state, Just code)

-- | Wait for the child to exit and return its status. Cancelling the wait changes nothing.
awaitDaemon :: Daemon -> IO ExitCode
awaitDaemon daemon = pollDaemon daemon >>= \case
  Just code -> pure code
  Nothing -> do
    withCopy daemon threadWaitRead
    pollDaemon daemon >>= \case
      Just code -> pure code
      Nothing -> ioError (userError ("fixture daemon pidfd readable without a status: " <> daemon.label))

-- | A failed delivery is an error: waiting out the bound would hide its cause. ESRCH is not one,
-- because the status read that follows reports a child something else collected.
signalDaemon :: Daemon -> CInt -> IO ()
signalDaemon daemon number = withMVarMasked daemon.phase $ \case
  Live -> do
    rc <- daemon.how.deliver daemon.pidfd number
    unless (rc == 0 || Errno rc == eSRCH) $
      ioError (errnoToIOError "fixture daemon signal" (Errno rc) Nothing (Just daemon.label))
  _ -> pure ()

-- | Run a wait on a private close-on-exec duplicate of the pidfd. The duplicate is made under the
-- lock, while the state proves the original open, so a concurrent retirement that closes the
-- original cannot hand the wait a recycled descriptor number. A cached status needs no wait.
withCopy :: Daemon -> (Fd -> IO ()) -> IO ()
withCopy daemon wait = scoped copy discard (maybe (pure ()) wait)
  where
    copy = withMVarMasked daemon.phase $ \case
      Live -> do
        let Fd raw = daemon.pidfd
        Just . Fd <$> throwErrnoIfMinus1 "fixture daemon pidfd duplicate" (duplicatePidfd raw)
      _ -> pure Nothing
    discard = maybe (pure ()) (closeFdWith closeFd)

closeDaemon :: Daemon -> IO ()
closeDaemon daemon = modifyMVarMasked_ daemon.phase $ \case
  Reaped code -> closeFdWith closeFd daemon.pidfd >> pure (Closed code)
  state -> pure state

-- | Owners that could not be retired, still held through their open pidfds.
retained :: IORef [Daemon]
retained = unsafePerformIO (newIORef [])
{-# NOINLINE retained #-}

retainedDaemons :: IO [Daemon]
retainedDaemons = readIORef retained

-- | Run a test runner and fail it, with exit status 3, if a fixture process is still owned when it ends.
-- Retirement is silent, so every runner that uses these fixtures must end through this guard.
guardRetained :: IO a -> IO a
guardRetained run = run `finally` (retainedDaemons >>= report)
  where
    report [] = pure ()
    report owners = do
      hPutStrLn stderr ("fixture processes still owned: " <> unwords (map (.label) owners))
      exitWith (ExitFailure 3)

-- | A retained owner still needs its directory.
removeUnlessRetained :: FilePath -> IO ()
removeUnlessRetained directory = do
  kept <- any ((== directory) . (.home)) <$> readIORef retained
  unless kept (removePathForcibly directory)

-- | Run a tmux client against the fixture's server for the body. The client is owned like the
-- server: started with a pidfd, retired with bounded SIGTERM and SIGKILL, collected once. Its pipe
-- ends close after the retirement, so a body that reads them must have joined its readers.
withClient :: Fixture -> (Stdio, Stdio, Stdio) -> [String] -> (Client -> IO a) -> IO a
withClient fixture streams arguments = scoped start releaseClient
  where
    start = startChild fixture.daemon.how ("client of " <> fixture.directory) fixture.directory fixture.executable
      arguments fixture.environment streams

-- | End the client, then close the pipe ends whether or not it ended. The first failure is raised.
releaseClient :: Client -> IO ()
releaseClient client = uninterruptibleMask_ $ do
  attempts <- traverse (try @SomeException) (retireDaemon client.process : map closeEnd [client.input, client.output, client.errors])
  either throwIO pure (sequence_ attempts)
  where
    closeEnd end@(Fd raw) = when (raw >= 0) (closeFdWith closeFd end)

command :: Fixture -> [String] -> IO (ExitCode, ByteString, ByteString)
command fixture args = withClient fixture (Null, Pipe, Pipe) (["-N", "-S", fixture.socket] <> args) $ \client ->
  -- Join readers before the release closes their descriptors; a live child cannot supply EOF.
  withAsync (slurp client.output) $ \out ->
    withAsync (slurp client.errors) $ \err -> do
      (written, complained) <- waitBoth out err
      code <- awaitDaemon client.process
      pure (code, Lazy.fromStrict written, Lazy.fromStrict complained)

-- | Own one control client through an acknowledged attachment and normal
-- detachment. These clients qualify listing context, not terminal/PTY behavior.
withAttachedClient :: Fixture -> String -> IO a -> IO a
withAttachedClient fixture session action = withClient fixture (Pipe, Pipe, Pipe) arguments $ \client -> do
  let detach = do
        writeAll client.input "detach-client\n"
        exited <- timeout 1000000 (awaitDaemon client.process)
        unless (exited == Just ExitSuccess) (throwIO (userError "owned control client did not exit"))
  ready <- timeout 1000000 (acknowledged client.output)
  unless (ready == Just True) (throwIO (userError "owned control client did not acknowledge attachment"))
  withAsync (drain client.output) $ \out ->
    withAsync (slurp client.errors) $ \err -> do
      result <- scoped (pure ()) (\() -> detach) (\() -> action)
      (_, complained) <- waitBoth out err
      unless (Strict.null complained) (throwIO (userError ("owned control client stderr: " <> show complained)))
      pure result
  where
    arguments = ["-u", "-N", "-S", fixture.socket, "-C", "attach-session", "-t", session]

-- | The next bytes of a pipe's parent end, or Nothing at end of stream. The descriptor is
-- non-blocking and the wait is the IO manager's, so cancelling a reader needs no signal.
readSome :: Fd -> IO (Maybe Strict.ByteString)
readSome end@(Fd raw) = allocaBytes size $ \buffer -> loop buffer
  where
    size = 32768
    loop buffer = do
      count <- readPipe raw buffer (fromIntegral size)
      case compare count 0 of
        GT -> Just <$> Strict.packCStringLen (castPtr buffer, fromIntegral count)
        EQ -> pure Nothing
        LT | Errno (negate count) == eAGAIN -> threadWaitRead end >> loop buffer
           | otherwise -> ioError (errnoToIOError "fixture pipe read" (Errno (negate count)) Nothing Nothing)

slurp :: Fd -> IO Strict.ByteString
slurp end = Strict.concat . reverse <$> go []
  where
    go chunks = readSome end >>= maybe (pure chunks) (\chunk -> go (chunk : chunks))

drain :: Fd -> IO ()
drain end = readSome end >>= maybe (pure ()) (const (drain end))

-- | Read until a complete line starts with @%end @, the reply that ends the attachment's first
-- command. False when the stream ends first.
acknowledged :: Fd -> IO Bool
acknowledged end = go Strict.empty
  where
    go pending = readSome end >>= \case
      Nothing -> pure False
      Just chunk ->
        let (lines', partial) = Strict.breakEnd (== 10) (pending <> chunk)
        in if any ("%end " `Strict.isPrefixOf`) (Ascii.lines lines') then pure True else go partial

writeAll :: Fd -> Strict.ByteString -> IO ()
writeAll end@(Fd raw) bytes = unless (Strict.null bytes) $ do
  count <- Strict.useAsCStringLen bytes $ \(buffer, size) -> writePipe raw (castPtr buffer) (fromIntegral size)
  if count >= 0
    then writeAll end (Strict.drop (fromIntegral count) bytes)
    else
      if Errno (negate count) == eAGAIN
        then threadWaitWrite end >> writeAll end bytes
        else ioError (errnoToIOError "fixture pipe write" (Errno (negate count)) Nothing Nothing)

openWatch :: FilePath -> IO Fd
openWatch directory = withCString directory $ \path ->
  Fd <$> throwErrnoIfMinus1 "fixture inotify watch" (watchDirectory path)

registerPane :: IORef (Maybe Fd) -> ByteString -> IO ()
registerPane tracked output = case reads (Bytes.unpack output) :: [(Integer, String)] of
  [(pid, "\n")] | pid > 0 && pid <= fromIntegral (maxBound @CInt) -> mask_ $ do
    fd <- Fd <$> throwErrnoIfMinus1 "fixture pane pidfd" (panePidfd (fromIntegral pid))
    writeIORef tracked (Just fd)
  _ -> throwIO (userError "fixture returned an invalid pane PID")

-- | Watch an additional owned pane and end it before observing exit.
-- The release action owns window/daemon teardown, even if the body never runs.
withTrackedPane :: ByteString -> IO () -> IO a -> IO a
withTrackedPane receipt teardown action = do
  observed <- newIORef False
  -- The pane wait always runs, but a failed teardown is the cause and the wait would only echo it.
  let release tracked = scoped (pure ()) (\() -> finishPane observed tracked) (\() -> teardown)
  scoped (newIORef Nothing) release $ \tracked -> do
    registerPane tracked receipt
    action

finishPane :: IORef Bool -> IORef (Maybe Fd) -> IO ()
finishPane observed tracked = readIORef tracked >>= \case
  Nothing -> pure ()
  Just fd -> finally (observeExit fd) (closeFd fd)
  where
    observeExit fd = do
      -- Window or daemon teardown precedes this wait. Never signal through a PID.
      timeout 1000000 (threadWaitRead fd) >>= \case
        Just () -> writeIORef observed True
        Nothing -> throwIO (userError "fixture tracked pane did not exit within one second")

waitReady :: Fd -> IO ()
waitReady fd@(Fd raw) = do
  -- tmux chmods the socket after listen, before accepting its first client.
  threadWaitRead fd
  ready <- throwErrnoIfMinus1 "fixture socket readiness" (socketReady raw)
  unless (ready == 1) (waitReady fd)
