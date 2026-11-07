module Fixture (Fixture (..), StartupStage (..), withFixture, withFixtureAt, command, registerPane) where

import Control.Concurrent.Async (race, waitBoth, withAsync)
import Control.Exception (bracket, finally, mask_, throwIO)
import Control.Monad (unless)
import Data.ByteString qualified as Strict
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as Lazy
import Data.ByteString.Lazy.Char8 qualified as Bytes
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import Foreign.C.Error (throwErrnoIfMinus1)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import GHC.Conc (threadWaitRead)
import System.Directory (removePathForcibly)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.IO (closeFd)
import System.Posix.Temp (mkdtemp)
import System.Posix.Types (Fd (..))
import System.Process.Typed
  ( Process, createPipe, getStderr, getStdout, nullStream, proc, setEnv, setStderr, setStdin, setStdout
  , waitExitCode, withProcessTerm
  )
import System.Timeout (timeout)

foreign import ccall unsafe "libtmux_fixture_watch"
  watchDirectory :: CString -> IO CInt

foreign import ccall unsafe "libtmux_fixture_socket_ready"
  socketReady :: CInt -> IO CInt

foreign import ccall unsafe "libtmux_fixture_pidfd"
  panePidfd :: CInt -> IO CInt

data Fixture = Fixture
  { directory :: !FilePath
  , socket :: !FilePath
  , executable :: !FilePath
  , environment :: ![(String, String)]
  , daemon :: !(Process () () ())
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
  bracket (mkdtemp "/tmp/libtmux-haskell-") removePathForcibly $ \directory ->
    bracket (openWatch directory) closeFd $ \watch ->
      bracket (newIORef Nothing) (finishPane paneExitObserved) $ \pane -> do
        let socket = directory </> "socket"
            config = setEnv environment . setStdin nullStream . setStdout nullStream $
              proc executable ["-D", "-S", socket, "-f", "/dev/null"]
        withProcessTerm config $ \daemon -> do
          readiness <- timeout 1000000 (race (waitExitCode daemon) (waitReady watch))
          case readiness of
            Just (Right ()) -> pure ()
            Just (Left code) -> throwIO (userError ("fixture daemon exited at startup: " <> show code))
            Nothing -> throwIO (userError "fixture socket did not become ready within one second")
          let fixture = Fixture {directory, socket, executable, environment, daemon, paneExitObserved}
          checkpoint SocketReady fixture
          (code, output, errors) <- command fixture
            ["new-session", "-d", "-s", "fixture", "-P", "-F", "#{pane_pid}", "/bin/cat", "-"]
          unless (code == ExitSuccess) $
            throwIO (userError ("fixture session creation failed: " <> show errors))
          checkpoint (PaneCreated output) fixture
          registerPane pane output
          action fixture

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

openWatch :: FilePath -> IO Fd
openWatch directory = withCString directory $ \path ->
  Fd <$> throwErrnoIfMinus1 "fixture inotify watch" (watchDirectory path)

registerPane :: IORef (Maybe Fd) -> ByteString -> IO ()
registerPane tracked output = case reads (Bytes.unpack output) :: [(Integer, String)] of
  [(pid, "\n")] | pid > 0 && pid <= fromIntegral (maxBound @CInt) -> mask_ $ do
    fd <- Fd <$> throwErrnoIfMinus1 "fixture pane pidfd" (panePidfd (fromIntegral pid))
    writeIORef tracked (Just fd)
  _ -> throwIO (userError "fixture returned an invalid pane PID")

finishPane :: IORef Bool -> IORef (Maybe Fd) -> IO ()
finishPane observed tracked = readIORef tracked >>= \case
  Nothing -> pure ()
  Just fd -> finally (observeExit fd) (closeFd fd)
  where
    observeExit fd = do
      -- The daemon scope has already ended. This descriptor is never used to signal.
      timeout 1000000 (threadWaitRead fd) >>= \case
        Just () -> writeIORef observed True
        Nothing -> throwIO (userError "fixture initial pane did not exit within one second")

waitReady :: Fd -> IO ()
waitReady fd@(Fd raw) = do
  -- tmux chmods the socket after listen, before accepting its first client.
  threadWaitRead fd
  ready <- throwErrnoIfMinus1 "fixture socket readiness" (socketReady raw)
  unless (ready == 1) (waitReady fd)
