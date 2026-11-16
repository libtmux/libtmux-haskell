-- | Public lifecycle cases. Only installed library types are imported. A test-owned
-- pidfd, opened from the daemon PID the library itself reports while that daemon is
-- running, witnesses exit; socket absence, client completion or a reaped child never
-- stand in for it.
module PublicLifecycleTest (tests) where

import Control.Concurrent.Async (AsyncCancelled (..), cancel, waitCatch, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception
  ( ExceptionWithContext (..), MaskingState (..), finally, fromException, getMaskingState, mask_, try, tryWithContext )
import Control.Monad (forM_, void, when)
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Int (Int16)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (fromMaybe, isJust)
import Data.Text qualified as Text
import Fixture qualified
import Foreign.C.Error (throwErrno)
import Foreign.C.Types (CInt (..), CULong (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr)
import Foreign.Storable (pokeByteOff)
import GHC.Conc (threadWaitRead)
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import System.Directory (doesFileExist, doesPathExist, removeFile, removePathForcibly)
import System.Environment (getEnvironment, lookupEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (ioeGetErrorString)
import System.OsPath.Posix qualified as Path
import System.OsString.Posix qualified as Os
import System.Posix.Files (setFileMode)
import System.Posix.IO (closeFd)
import System.Posix.Temp (mkdtemp)
import System.Posix.Types (Fd (..))
import System.Process.Typed (nullStream, proc, readProcess, setEnv, setStdin, waitExitCode)
import System.Timeout (timeout)
import Test.Tasty (TestTree, localOption, mkTimeout, testGroup)
import Test.Tasty.HUnit

foreign import ccall unsafe "libtmux_fixture_pidfd" openPidfd :: CInt -> IO CInt
foreign import ccall unsafe "poll" cPoll :: Ptr () -> CULong -> CInt -> IO CInt

-- | The owned daemon, and the endpoint and directory it reported through the library.
data Witness = Witness {pid :: !Integer, socket :: !FilePath, daemon :: !CInt}

tests :: TestTree
tests = localOption (mkTimeout 60000000) $ testGroup "public lifecycle"
  [ testCase "an owned server creates and captures, then returns after retiring its daemon" $
      withOwned $ \executable config -> do
        seen <- newIORef Nothing
        (closed, created, snapshot, pane) <- Tmux.withOwnedServer config $ \server -> do
          getMaskingState >>= (@?= Unmasked)
          witness <- observe server
          writeIORef seen (Just witness)
          created <- Tmux.createSession server options
          created.serverPid @?= witness.pid
          snapshot <- Tmux.capture server
          pane <- paneProcess executable witness created.pane
          exited witness.daemon >>= assertBool "the daemon exited while its scope was open" . not
          pure (server, created, snapshot, pane)
        witness <- readIORef seen >>= maybe (assertFailure "callback did not run") pure
        (`finally` (closeFd (Fd pane) >> closeFd (Fd witness.daemon))) $ do
          assertRetired witness
          awaitExit pane
        _ <- either (assertFailure . show) pure (Tmux.lookupSession snapshot created.session)
        _ <- either (assertFailure . show) pure (Tmux.lookupPane snapshot created.pane)
        refuses "capture" (Tmux.capture closed)
        refuses "creation" (Tmux.createSession closed options)
        refuses "kill" (Tmux.killServer closed)

  , testCase "a callback IOException keeps its class under incoming masking and the daemon is still retired" $
      withOwned $ \_ config -> do
        seen <- newIORef Nothing
        outcome <- mask_ $ try @IOError $ Tmux.withOwnedServer config $ \server -> do
          getMaskingState >>= (@?= MaskedInterruptible)
          observe server >>= writeIORef seen . Just
          ioError (userError "callback failed")
        either (\problem -> ioeGetErrorString problem @?= "callback failed")
          (const (assertFailure "callback exception was swallowed")) outcome
        retired seen

  , testCase "cancelling the callback keeps AsyncCancelled and the daemon is still retired" $
      withOwned $ \_ config -> do
        seen <- newIORef Nothing
        entered <- newEmptyMVar
        never <- newEmptyMVar @()
        outcome <- withAsync
          (Tmux.withOwnedServer config $ \server -> do
            observe server >>= writeIORef seen . Just
            putMVar entered ()
            takeMVar never) $ \worker -> do
          takeMVar entered
          cancel worker
          waitCatch worker
        case outcome of
          Left problem -> fromException @AsyncCancelled problem @?= Just AsyncCancelled
          Right () -> assertFailure "cancelled callback returned"
        retired seen

  , testCase "unfinished owned cleanup is reachable and resumable through the public recovery API" $
      withOwned $ \_ config -> do
        seen <- newIORef Nothing
        outcome <- tryWithContext @IOError $ Tmux.withOwnedServer config $ \server -> do
          witness <- observe server
          writeIORef seen (Just witness)
          writeFile (takeDirectory witness.socket </> "retained-file") "owned test obstruction"
          ioError (userError "callback before cleanup failure")
        witness <- readIORef seen >>= maybe (assertFailure "callback did not run") pure
        let directory = takeDirectory witness.socket
        (`finally` (closeFd (Fd witness.daemon) >> removePathForcibly directory)) $ do
          exited witness.daemon >>= assertBool "cleanup did not retire the original daemon"
          context <- case outcome of
            Left (ExceptionWithContext context problem) -> do
              ioeGetErrorString problem @?= "callback before cleanup failure"
              pure context
            Right () -> assertFailure "callback exception was swallowed"
          recovery <- case Tmux.cleanupRecoveries context of
            [owner] -> pure owner
            owners -> assertFailure ("expected one public cleanup owner, got " <> show (length owners))
          before <- Tmux.inspectCleanup recovery
          assertBool "pending names were reported complete" (not before.complete)
          doesPathExist directory >>= assertBool "owned directory disappeared before cleanup"
          Tmux.tryTmux (Tmux.resumeCleanup recovery) >>= \case
            Left (ExceptionWithContext retryContext (Tmux.CleanupFailed status (Just _))) -> do
              assertBool "failed retry lost pending ownership" (not status.complete)
              assertBool "failed retry lost its public owner" (not (null (Tmux.cleanupRecoveries retryContext)))
            other -> assertFailure ("expected an owned cleanup failure: " <> either show (const "success") other)
          removeFile (directory </> "retained-file")
          after <- Tmux.awaitCleanup recovery
          assertBool "public wait did not complete cleanup" after.complete
          Tmux.resumeCleanup recovery >>= assertBool "completed cleanup was not idempotent" . (.complete)
          assertRetired witness

  , testCase "cleanup that fails after a successful callback is CleanupFailed with one reachable owner" $
      withOwned $ \_ config -> do
        seen <- newIORef Nothing
        outcome <- Tmux.tryTmux $ Tmux.withOwnedServer config $ \server -> do
          witness <- observe server
          writeIORef seen (Just witness)
          writeFile (takeDirectory witness.socket </> "retained-file") "owned test obstruction"
        witness <- readIORef seen >>= maybe (assertFailure "callback did not run") pure
        let directory = takeDirectory witness.socket
        (`finally` (closeFd (Fd witness.daemon) >> removePathForcibly directory)) $ do
          recovery <- case outcome of
            Left (ExceptionWithContext context (Tmux.CleanupFailed status (Just _))) -> do
              assertBool "pending names were reported complete" (not status.complete)
              case Tmux.cleanupRecoveries context of
                [owner] -> pure owner
                owners -> assertFailure ("expected one public cleanup owner, got " <> show (length owners))
            other -> assertFailure ("expected CleanupFailed after a successful callback: " <> either show (const "success") other)
          removeFile (directory </> "retained-file")
          Tmux.awaitCleanup recovery >>= assertBool "public wait did not complete cleanup" . (.complete)
          assertRetired witness

  , testCase "an explicit kill that fails inside the callback leaves the one owner it attached" $
      withOwned $ \_ config -> do
        seen <- newIORef Nothing
        outcome <- Tmux.tryTmux $ Tmux.withOwnedServer config $ \server -> do
          witness <- observe server
          writeIORef seen (Just witness)
          writeFile (takeDirectory witness.socket </> "retained-file") "owned test obstruction"
          Tmux.killServer server
        witness <- readIORef seen >>= maybe (assertFailure "callback did not run") pure
        let directory = takeDirectory witness.socket
        (`finally` (closeFd (Fd witness.daemon) >> removePathForcibly directory)) $ do
          recovery <- case outcome of
            Left (ExceptionWithContext context (Tmux.OperationFailed _)) -> case Tmux.cleanupRecoveries context of
              [owner] -> pure owner
              owners -> assertFailure ("expected one public cleanup owner, got " <> show (length owners))
            other -> assertFailure ("expected the kill's operational failure: " <> either show (const "success") other)
          removeFile (directory </> "retained-file")
          Tmux.resumeCleanup recovery >>= assertBool "public resume did not complete cleanup" . (.complete)
          assertRetired witness

  , testCase "explicit kill inside an owned scope closes admission and automatic cleanup stays idempotent" $
      withOwned $ \_ config -> do
        seen <- newIORef Nothing
        Tmux.withOwnedServer config (\server -> do
          witness <- observe server
          writeIORef seen (Just witness)
          void (Tmux.createSession server options)
          Tmux.killServer server
          exited witness.daemon >>= assertBool "explicit kill did not retire the original daemon"
          refuses "capture after explicit kill" (Tmux.capture server)
          refuses "creation after explicit kill" (Tmux.createSession server options)
          refuses "repeated kill" (Tmux.killServer server))
          `finally` (readIORef seen >>= mapM_ (closeFd . Fd . (.daemon)))
        witness <- readIORef seen >>= maybe (assertFailure "callback did not run") pure
        doesPathExist (takeDirectory witness.socket) >>= assertBool "automatic cleanup left its directory" . not

  , testCase "adoption leaves the daemon running and only killServer retires it" $
      Fixture.withFixture $ \fixture -> do
        let config = (Tmux.serverConfig (Os.fromBytestring (Bytes.pack fixture.socket)))
              {Tmux.executable = Os.fromBytestring (Bytes.pack fixture.executable)}
        witness <- Tmux.withServer config observe
        (`finally` closeFd (Fd witness.daemon)) $ do
          exited witness.daemon >>= assertBool "adoption retired a borrowed daemon" . not
          retained <- Tmux.withServer config pure
          refuses "kill through a retained adopted Server" (Tmux.killServer retained)
          exited witness.daemon >>= assertBool "a refused kill retired a borrowed daemon" . not
          (code, _, errors) <- Fixture.command fixture ["display-message", "-p", "#{pid}"]
          (code, errors) @?= (ExitSuccess, "")
          Tmux.withServer config $ \server -> do
            again <- observe server
            closeFd (Fd again.daemon)
            again.pid @?= witness.pid
            Tmux.killServer server
            exited witness.daemon >>= assertBool "killServer did not retire the original daemon"
            timeout 2000000 (waitExitCode fixture.daemon) >>= assertBool "the fixture's own child saw the exit" . isJust
            -- A capture against the dead daemon fails; its retained owner is detached as usual.
            Tmux.tryTmux (Tmux.capture server) >>= \case
              Left (ExceptionWithContext context _) -> mapM_ Tmux.detachCaptureRecovery (Tmux.captureRecoveries context)
              Right _ -> assertFailure "a killed daemon answered a capture"

  , testCase "adoption runs no configured command hook" $
      Fixture.withFixture $ \fixture -> do
        forM_ ["after-run-shell", "after-display-message", "command-error"] $ \hook -> do
          (code, output, errors) <- Fixture.command fixture
            ["set-hook", "-g", hook, "set-option -g @libtmux-probe-hit 1"]
          case code of
            ExitSuccess -> (output, errors) @?= ("", "")
            ExitFailure 1 -> assertBool "unexpected hook configuration failure"
              (("invalid option: " <> Bytes.pack hook) `Bytes.isInfixOf` Lazy.toStrict errors)
            other -> assertFailure (show other)
        Fixture.command fixture ["set-option", "-g", "@libtmux-probe-hit", "0"] >>= (@?= (ExitSuccess, "", ""))
        let config = (Tmux.serverConfig (Os.fromBytestring (Bytes.pack fixture.socket)))
              {Tmux.executable = Os.fromBytestring (Bytes.pack fixture.executable)}
        Tmux.withServer config (\_ -> pure ())
        Tmux.withRuntime $ \runtime -> Tmux.withServerIn runtime config (\_ -> pure ())
        Fixture.command fixture ["show-option", "-g", "-v", "@libtmux-probe-hit"] >>= (@?= (ExitSuccess, "0\n", ""))

  , testCase "invalid configuration is refused before any executable runs" $
      withRecorder $ \script marker -> do
        let config = Tmux.defaultOwnedServerConfig {Tmux.tmuxExecutable = Os.fromBytestring (Bytes.pack script)}
            refused configuration = do
              entered <- newIORef False
              Tmux.tryTmux (Tmux.withOwnedServer configuration (\_ -> writeIORef entered True)) >>= \case
                Left (ExceptionWithContext _ (Tmux.InvalidConfiguration _)) -> pure ()
                other -> assertFailure ("configuration was not refused: " <> either show (const "success") other)
              readIORef entered >>= assertBool "an invalid configuration entered its callback" . not
        forM_ [0, -1, 11] $ \seconds -> refused config {Tmux.operationTimeout = seconds}
        refused config {Tmux.tmuxExecutable = Os.fromBytestring "/nonexistent/libtmux-haskell-tmux"}
        doesFileExist marker >>= assertBool "an invalid configuration launched the executable" . not
        -- Control: the recorder sees a valid launch, which fails as an operational error.
        Tmux.tryTmux (Tmux.withOwnedServer config (\_ -> pure ())) >>= \case
          Left (ExceptionWithContext _ (Tmux.OperationFailed _)) -> pure ()
          other -> assertFailure ("a failed start was not operational: " <> either show (const "success") other)
        doesFileExist marker >>= assertBool "the recorder did not observe a valid launch"
  ]

options :: Tmux.SessionOptions
options = Creation.defaultSessionOptions
  {Creation.name = Just "public-lifecycle", Creation.process = Creation.DirectCommand (Os.fromBytestring "/bin/cat") (Os.fromBytestring "-" :| [])}

-- | A configuration for the explicit test binary, in an environment without tmux context.
withOwned :: (FilePath -> Tmux.OwnedServerConfig -> IO a) -> IO a
withOwned action = do
  executable <- fromMaybe "tmux" <$> lookupEnv "LIBTMUX_TEST_TMUX"
  names <- map fst <$> getEnvironment
  forM_ (filter (\name -> name `elem` ["TMUX", "TMUX_PANE"] || take 14 name == "LIBTMUX_SOCKET") names) unsetEnv
  action executable Tmux.defaultOwnedServerConfig {Tmux.tmuxExecutable = Os.fromBytestring (Bytes.pack executable)}

-- | Open a witness on the live daemon reported by the library's own capture.
observe :: Tmux.Server -> IO Witness
observe server = do
  info <- Tmux.serverInfo <$> Tmux.capture server
  socket <- Path.decodeFS info.socketPath
  daemon <- openPidfd (fromIntegral info.pid)
  when (daemon < 0) (throwErrno "witness pidfd_open")
  exited daemon >>= assertBool "the daemon exited before its witness opened" . not
  pure Witness {pid = info.pid, socket, daemon}

-- | The daemon's exit is a readable pidfd, and the private directory is gone.
assertRetired :: Witness -> Assertion
assertRetired witness = do
  exited witness.daemon >>= assertBool "the original daemon is still running"
  doesPathExist (takeDirectory witness.socket) >>= assertBool "the private socket directory remains" . not

retired :: IORef (Maybe Witness) -> Assertion
retired seen = do
  witness <- readIORef seen >>= maybe (assertFailure "callback did not run") pure
  assertRetired witness `finally` closeFd (Fd witness.daemon)

-- | Readiness of a pidfd without waiting: the process has exited.
exited :: CInt -> IO Bool
exited pidfd = allocaBytes 8 $ \entry -> do
  pokeByteOff entry 0 pidfd
  pokeByteOff entry 4 (1 :: Int16) -- events: POLLIN
  pokeByteOff entry 6 (0 :: Int16)
  ready <- cPoll entry 1 0
  when (ready < 0) (throwErrno "poll pidfd")
  pure (ready > 0)

-- | A pane exits after its daemon and pty are gone; wait for that event, bounded.
awaitExit :: CInt -> Assertion
awaitExit pidfd = timeout 1000000 (threadWaitRead (Fd pidfd)) >>=
  maybe (assertFailure "the pane process did not exit") pure

-- | A second tmux client reads the pane's process ID from the owned daemon.
paneProcess :: FilePath -> Witness -> Tmux.PaneRef -> IO CInt
paneProcess executable witness pane = do
  environment <- filter (\(name, _) -> name /= "TMUX" && name /= "TMUX_PANE") <$> getEnvironment
  let target = Text.unpack (Tmux.renderPaneId (Tmux.paneId pane))
  (code, output, errors) <- readProcess $ setEnv environment $ setStdin nullStream $
    proc executable ["-N", "-S", witness.socket, "display-message", "-p", "-t", target, "#{pane_pid}"]
  (code, errors) @?= (ExitSuccess, "")
  case reads (Lazy.unpack output) :: [(Integer, String)] of
    [(process, "\n")] -> do
      descriptor <- openPidfd (fromIntegral process)
      when (descriptor < 0) (throwErrno "pane pidfd_open")
      pure descriptor
    _ -> assertFailure "tmux returned an invalid pane PID"

refuses :: String -> IO a -> Assertion
refuses operation action = Tmux.tryTmux (void action) >>= \case
  Left (ExceptionWithContext _ Tmux.ServerClosed) -> pure ()
  Left problem -> assertFailure (operation <> " failed unexpectedly: " <> show problem)
  Right () -> assertFailure (operation <> " used a retained Server after its scope closed")

-- | An executable that records any launch by creating a marker, in an owned directory.
withRecorder :: (FilePath -> FilePath -> IO a) -> IO a
withRecorder action = do
  directory <- mkdtemp "/tmp/libtmux-haskell-"
  let script = directory </> "tmux"
      marker = directory </> "launched"
  (`finally` removePathForcibly directory) $ do
    writeFile script ("#!/bin/sh\n: > '" <> marker <> "'\n")
    setFileMode script 0o700
    action script marker
