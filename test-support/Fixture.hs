module Fixture
  ( Fixture (..), StartupStage (..), Daemon (..), Retirement (..), retirement
  , withFixture, withFixtureAt, withDaemon, retireDaemon, awaitDaemon, pollDaemon, retainedDaemons, guardRetained
  , withAttachedClient, command, registerPane, withTrackedPane
  ) where

import Control.Concurrent.Async (race, waitBoth, withAsync)
import Control.Concurrent.MVar (MVar, modifyMVarMasked, modifyMVarMasked_, newMVar, withMVarMasked)
import Control.Exception
  ( SomeException, finally, mask, mask_, onException, rethrowIO, throwIO
  , tryWithContext, uninterruptibleMask_
  )
import Control.Monad (unless, when)
import Data.ByteString qualified as Strict
import Data.ByteString.Char8 qualified as Ascii
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as Lazy
import Data.ByteString.Lazy.Char8 qualified as Bytes
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import Foreign.C.Error (Errno (..), eSRCH, errnoToIOError, throwErrnoIfMinus1)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (allocaArray, withArray0)
import Foreign.Marshal.Utils (withMany)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peek, peekElemOff)
import GHC.Conc (closeFdWith, threadWaitRead)
import GHC.Foreign qualified as Foreign
import GHC.IO.Encoding (getFileSystemEncoding)
import System.Directory (removePathForcibly)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (hFlush, hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.IO (closeFd)
import System.Posix.Temp (mkdtemp)
import System.Posix.Types (Fd (..))
import System.Process.Typed
  ( createPipe, getStderr, getStdin, getStdout, nullStream, proc, setEnv, setStderr, setStdin, setStdout
  , waitExitCode, withProcessTerm
  )
import System.Timeout (timeout)

foreign import ccall unsafe "libtmux_fixture_watch"
  watchDirectory :: CString -> IO CInt

foreign import ccall unsafe "libtmux_fixture_socket_ready"
  socketReady :: CInt -> IO CInt

foreign import ccall unsafe "libtmux_fixture_pidfd"
  panePidfd :: CInt -> IO CInt

foreign import ccall unsafe "libtmux_fixture_spawn"
  spawnChild :: CString -> Ptr CString -> Ptr CString -> Ptr CInt -> IO CInt

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
-- Nothing else in the process may reap children without naming them.
data Daemon = Daemon
  { label :: !String
  , pidfd :: !Fd
  , phase :: !(MVar Phase)
  , how :: !Retirement
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

-- | Acquire a resource, run the body, then release it. Keep a failing body's exception
-- and annotations; raise a release failure only after a clean body.
scoped :: IO r -> (r -> IO ()) -> (r -> IO a) -> IO a
scoped acquire release body = mask $ \restore -> do
  resource <- acquire
  outcome <- tryWithContext @SomeException (restore (body resource))
  released <- tryWithContext @SomeException (release resource)
  case (outcome, released) of
    (Left problem, _) -> rethrowIO problem
    (Right _, Left problem) -> rethrowIO problem
    (Right result, Right ()) -> pure result

-- | Run a child for the body and retire it afterwards. A failure of the body is rethrown as
-- it is, whether or not the retirement then succeeds; a retirement that fails after a clean
-- body is raised.
withDaemon :: Retirement -> String -> FilePath -> [String] -> [(String, String)] -> (Daemon -> IO a) -> IO a
withDaemon how label executable arguments environment =
  scoped (startDaemon how label executable arguments environment) retireDaemon

startDaemon :: Retirement -> String -> FilePath -> [String] -> [(String, String)] -> IO Daemon
startDaemon how label executable arguments environment = do
  encoding <- getFileSystemEncoding
  let text = Foreign.withCString encoding
  fd <-
    withMany text (executable : arguments) $ \argv ->
      withMany text [key <> "=" <> value | (key, value) <- environment] $ \envp ->
        withArray0 nullPtr argv $ \argvArray ->
          withArray0 nullPtr envp $ \envArray ->
            text executable $ \file -> alloca $ \out -> do
              rc <- spawnChild file argvArray envArray out
              unless (rc == 0) (ioError (errnoToIOError "fixture daemon spawn" (Errno rc) Nothing (Just executable)))
              peek out
  phase <- newMVar Live
  pure Daemon {label, pidfd = Fd fd, phase, how}

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

-- | Daemons that could not be retired, still owned through their open pidfds.
retained :: IORef [Daemon]
retained = unsafePerformIO (newIORef [])
{-# NOINLINE retained #-}

retainedDaemons :: IO [Daemon]
retainedDaemons = readIORef retained

-- | Run a test runner and fail it, with exit status 3, if a daemon is still owned when it ends.
-- Retirement is silent, so every runner that uses these fixtures must end through this guard.
guardRetained :: IO a -> IO a
guardRetained run = run `finally` (retainedDaemons >>= report)
  where
    report [] = pure ()
    report owners = do
      hPutStrLn stderr ("fixture daemons still owned: " <> unwords (map (.label) owners))
      exitWith (ExitFailure 3)

-- | A retained daemon still needs its directory.
removeUnlessRetained :: FilePath -> IO ()
removeUnlessRetained directory = do
  kept <- any ((== directory) . (.label)) <$> readIORef retained
  unless kept (removePathForcibly directory)

command :: Fixture -> [String] -> IO (ExitCode, ByteString, ByteString)
command fixture args = withProcessTerm config $ \client -> do
  -- Join readers before handle cleanup; a live waiting child cannot supply EOF.
  withAsync (Strict.hGetContents (getStdout client)) $ \out ->
    withAsync (Strict.hGetContents (getStderr client)) $ \err -> do
      (output, errors) <- waitBoth out err
      code <- waitExitCode client
      pure (code, Lazy.fromStrict output, Lazy.fromStrict errors)
  where
    config = setEnv fixture.environment . setStdin nullStream . setStdout createPipe . setStderr createPipe $
      proc fixture.executable (["-N", "-S", fixture.socket] <> args)

-- | Own one control client through an acknowledged attachment and normal
-- detachment. These clients qualify listing context, not terminal/PTY behavior.
withAttachedClient :: Fixture -> String -> IO a -> IO a
withAttachedClient fixture session action = withProcessTerm config $ \client -> do
  let output = getStdout client
      acknowledge = do
        line <- Ascii.hGetLine output
        unless ("%end " `Strict.isPrefixOf` line) acknowledge
      drain = do
        chunk <- Strict.hGetSome output 4096
        unless (Strict.null chunk) drain
      detach = do
        Ascii.hPutStrLn (getStdin client) "detach-client"
        hFlush (getStdin client)
        exited <- timeout 1000000 (waitExitCode client)
        unless (exited == Just ExitSuccess) (throwIO (userError "owned control client did not exit"))
  ready <- timeout 1000000 acknowledge
  unless (ready == Just ()) (throwIO (userError "owned control client did not acknowledge attachment"))
  withAsync drain $ \out ->
    withAsync (Strict.hGetContents (getStderr client)) $ \err -> do
      result <- scoped (pure ()) (\() -> detach) (\() -> action)
      (_, errors) <- waitBoth out err
      unless (Strict.null errors) (throwIO (userError ("owned control client stderr: " <> show errors)))
      pure result
  where
    config = setEnv fixture.environment . setStdin createPipe . setStdout createPipe . setStderr createPipe $
      proc fixture.executable ["-u", "-N", "-S", fixture.socket, "-C", "attach-session", "-t", session]

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
