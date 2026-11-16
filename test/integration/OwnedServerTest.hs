{-# LANGUAGE InterruptibleFFI #-}
-- | Lifecycle cases for "LibTmux.Internal.OwnedServer". Every case
-- opens its own pidfd on the daemon and panes, independent of the library's, and
-- checks the private directory and a /proc audit after the bracket. Synchronization
-- uses owned process events, FIFO opens, pidfd readiness, inotify and socket reset
-- events, never a fixed sleep for readiness. The only timers are deadlines under test.
module OwnedServerTest (tests) where

import Control.Concurrent (ThreadId, yield)
import Control.Concurrent.Async (Async, AsyncCancelled (..), async, asyncThreadId, cancel, race, wait, waitCatch, withAsync)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (atomically, check, readTMVar, readTVar)
import Control.Exception
import Control.Monad (filterM, forM, forM_, replicateM_, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.ByteString.Lazy qualified as Lazy
import Data.Char (isDigit)
import Data.Either (isLeft, isRight)
import Data.IORef
import Data.List (isPrefixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Fixture qualified
import Foreign.C.Error (eAGAIN, eCONNREFUSED, throwErrno)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Array (allocaArray, peekArray)
import Foreign.Ptr (Ptr)
import GHC.Conc
  (BlockReason (BlockedOnMVar), ThreadStatus (..), listThreads, threadStatus, threadWaitRead)
import GHC.Conc.Sync (threadLabel)
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import LibTmux.Id qualified as Id
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.Capture qualified as C
import LibTmux.Internal.Creation qualified as Create
import LibTmux.Internal.Graph qualified as G
import LibTmux.Internal.OwnedServer qualified as OS
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Native qualified as N
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.Scheduler qualified as S
import LibTmux.Internal.Scope qualified as Scope
import LibTmux.Internal.SocketPin qualified as Pin
import System.Directory (createDirectory, doesPathExist, listDirectory, removeDirectory, removePathForcibly)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.IO.Error (ioeGetErrorString)
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)
import System.OsString.Posix qualified as Os
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as Posix
import System.Posix.Process (getProcessID)
import System.Posix.Signals (sigCONT, sigKILL, sigSTOP, sigTERM, sigUSR1)
import System.Posix.Temp (mkdtemp)
import System.Posix.Types (DeviceID, FileID, Fd (..))
import System.Process.Typed
  (nullStream, proc, readProcess, setEnv, setStderr, setStdin, setStdout, waitExitCode, withProcessTerm)
import System.Timeout (timeout)
import Test.Tasty (TestTree, localOption, mkTimeout, testGroup)
import Test.Tasty.HUnit
import Text.Read (readMaybe)

foreign import ccall unsafe "libtmux_fixture_pidfd" openPidfd :: CInt -> IO CInt
foreign import ccall unsafe "libtmux_fixture_lock" holdLock :: CString -> IO CInt
foreign import ccall unsafe "libtmux_fixture_listen" listenAt :: CString -> CInt -> IO CInt
foreign import ccall unsafe "libtmux_fixture_saturate" saturate :: CString -> Ptr CInt -> CInt -> IO CInt
foreign import ccall unsafe "libtmux_fixture_hung" hungUp :: CInt -> IO CInt
foreign import ccall unsafe "libtmux_fixture_watch_create" watchCreate :: CString -> IO CInt
foreign import ccall unsafe "libtmux_fixture_created" createdName :: CInt -> CString -> IO CInt
foreign import ccall interruptible "open" cOpen :: CString -> CInt -> IO CInt

-- | O_WRONLY | O_CLOEXEC on a FIFO: blocks until a reader opens it. A blocking
-- unsafe call would freeze the single capability before the reader can exist.
openWriter :: FilePath -> IO Fd
openWriter path = withCString path $ \name -> cOpen name 0x80001 >>= \rc ->
  if rc < 0 then throwErrno "open fifo" else pure (Fd rc)

data Boom = Boom
  deriving stock (Show)
instance Exception Boom

-- | Test-owned observations of one run, independent of the library's pidfds.
data Watch = Watch
  { names :: IORef (Maybe OS.Names), daemonFd :: IORef (Maybe CInt), paneFds :: IORef [CInt] }

newWatch :: IO Watch
newWatch = Watch <$> newIORef Nothing <*> newIORef Nothing <*> newIORef []

tests :: TestTree
tests = localOption (mkTimeout 60000000) $ testGroup "owned daemon lifecycle"
  [ testGroup "native contract"
    [ testCase "an invalid descriptor fails instead of reporting a physical exit" invalidDescriptor
    , testCase "the host probe reports every operation the daemon path needs" $
        OS.cDaemonFeatures >>= (@?= 7)
    , testCase "a full backlog is EAGAIN, not a hang and not an exit" saturatedListener
    , testCase "a descriptor duplicated for a wait is close-on-exec, unlike a plain dup" $ do
        (readEnd, writeEnd) <- Posix.createPipe
        copy <- OS.cDup (fromIntegral readEnd)
        plain <- Posix.dup readEnd
        (do assertBool "the wait duplicate would be inherited by an application child" =<< Posix.queryFdOption (Fd copy) Posix.CloseOnExec
            Posix.queryFdOption plain Posix.CloseOnExec >>= assertBool "control: a plain dup is inheritable" . not)
          `finally` (mapM_ Posix.closeFd [readEnd, writeEnd, plain, Fd copy])
    ]
  , testGroup "lifecycle"
    [ testCase "normal return: session and capture, daemon retired, names removed, no descriptor kept" $
        Fixture.inIsolatedProcess "normal return: session and capture, daemon retired, names removed, no descriptor kept" $
        withTmux $ \exe -> do
          normalLifecycle exe
          before <- fdCount
          normalLifecycle exe
          fdCount >>= (@?= before)

    , testCase "callback exception keeps its class and still retires the daemon" $
        withTmux $ \exe -> do
          watch <- newWatch
          outcome <- try @Boom $ OS.withOwnedServerWith (watching watch (Just OS.Admitted) OS.defaultProbe) exe $ \owned -> do
            void (createOne owned "owned-boom")
            throwIO Boom
          assertBool "callback exception class preserved" (isLeft outcome)
          assertRetired watch

    , testCase "cancellation in the callback keeps AsyncCancelled and retires the daemon" $
        withTmux $ \exe -> do
          watch <- newWatch
          entered <- newEmptyMVar
          never <- newEmptyMVar @()
          outcome <- withAsync
            (OS.withOwnedServerWith (watching watch (Just OS.Admitted) OS.defaultProbe) exe $ \owned -> do
              void (createOne owned "owned-cancel")
              putMVar entered ()
              takeMVar never) $ \worker -> do
            awaitEvent worker entered
            cancel worker
            waitCatch worker
          assertCancelled outcome
          assertRetired watch

    , testCase "failure before pin publication retires the already-owned daemon" $
        withTmux $ \exe -> do
          watch <- newWatch
          let probe = (watching watch (Just OS.DaemonOwned) OS.defaultProbe)
                {OS.pinStage = \point _ -> when (point == Pin.BeforePublish) (throwIO Boom)}
          outcome <- try @Boom (OS.withOwnedServerWith probe exe (\_ -> pure ()))
          assertBool "pin checkpoint failure class preserved" (isLeft outcome)
          assertRetired watch

    , testCase "cancellation before pin publication keeps AsyncCancelled and retires the daemon" $
        withTmux $ \exe -> do
          watch <- newWatch
          reached <- newEmptyMVar
          never <- newEmptyMVar @()
          let probe = (watching watch (Just OS.DaemonOwned) OS.defaultProbe)
                {OS.pinStage = \point _ -> when (point == Pin.BeforeLink) (putMVar reached () >> takeMVar never)}
          outcome <- withAsync (OS.withOwnedServerWith probe exe (\_ -> pure ())) $ \worker -> do
            awaitEvent worker reached
            cancel worker
            waitCatch worker
          assertCancelled outcome
          assertRetired watch

    , testCase "failure after the start client exits but before the daemon pidfd is held" $
        withTmux $ \exe -> do
          watch <- newWatch
          let probe = (watching watch (Just OS.ClientExited) OS.defaultProbe)
                {OS.stage = \point names -> do
                   writeIORef watch.names (Just names)
                   when (point == OS.ClientExited) (openDaemon watch names >> throwIO Boom)}
          outcome <- try @Boom (OS.withOwnedServerWith probe exe (\_ -> pure ()))
          assertBool "stage failure class preserved" (isLeft outcome)
          assertRetired watch

    , testCase "failure or cancellation while the start client is in flight leaves no daemon, and keeps the owner when none was found (25 + 25)" $
        withTmux $ \exe -> do
          replicateM_ 25 $ do
            watch <- newWatch
            let probe = OS.defaultProbe {OS.stage = \point names -> do
                  writeIORef watch.names (Just names)
                  when (point == OS.ClientLaunched) (throwIO Boom)}
            outcome <- try @SomeException (OS.withOwnedServerWith probe exe (\_ -> pure ()))
            assertBool "stage failure class preserved" (isLeft outcome)
            void (assertSettledOrRetained watch (\Boom -> True) outcome)
          replicateM_ 25 $ do
            watch <- newWatch
            reached <- newEmptyMVar
            never <- newEmptyMVar @()
            let probe = OS.defaultProbe {OS.stage = \point names -> do
                  writeIORef watch.names (Just names)
                  when (point == OS.ClientLaunched) (putMVar reached () >> takeMVar never)}
            outcome <- withAsync (OS.withOwnedServerWith probe exe (\_ -> pure ())) $ \worker -> do
              awaitEvent worker reached
              cancel worker
              waitCatch worker
            assertCancelled outcome
            void (assertSettledOrRetained watch (\AsyncCancelled -> True) outcome)

    , testCase "aborting the start client between its lock and the daemon's listen leaves no daemon, and keeps the owner when none was found (30 + 30)" $
        withTmux $ \exe -> do
          found <- newIORef []
          waits <- newIORef (0 :: Int)
          kept <- newIORef (0 :: Int)
          let counting watch = OS.defaultProbe
                { OS.retired = \how -> modifyIORef' found (how :)
                , OS.lockWait = \blocked -> when blocked (modifyIORef' waits (+ 1))
                , OS.stage = \point names -> do
                    writeIORef watch.names (Just names)
                    when (point == OS.ClientLaunched) (awaitCreated names "s.lock") }
              settled :: Exception e => Watch -> (e -> Bool) -> Either SomeException a -> IO ()
              settled watch matches outcome = assertSettledOrRetained watch matches outcome
                >>= \retained -> when retained (modifyIORef' kept (+ 1))
          replicateM_ 30 $ do
            watch <- newWatch
            let probe = (counting watch) {OS.stage = \point names -> do
                  writeIORef watch.names (Just names)
                  when (point == OS.ClientLaunched) (awaitCreated names "s.lock" >> throwIO Boom)}
            outcome <- try @SomeException (OS.withOwnedServerWith probe exe (\_ -> pure ()))
            assertBool "stage failure class preserved" (isLeft outcome)
            settled watch (\Boom -> True) outcome
          replicateM_ 30 $ do
            watch <- newWatch
            reached <- newEmptyMVar
            never <- newEmptyMVar @()
            let probe = (counting watch) {OS.stage = \point names -> do
                  writeIORef watch.names (Just names)
                  when (point == OS.ClientLaunched) (awaitCreated names "s.lock" >> putMVar reached () >> takeMVar never)}
            outcome <- withAsync (OS.withOwnedServerWith probe exe (\_ -> pure ())) $ \worker -> do
              awaitEvent worker reached
              cancel worker
              waitCatch worker
            assertCancelled outcome
            settled watch (\AsyncCancelled -> True) outcome
          daemons <- readIORef found
          blocked <- readIORef waits
          unproved <- readIORef kept
          let count how = length (filter (== how) daemons)
          putStrLn ("      window tally over 60 aborts: pidfd found already gone " <> show (count OS.AlreadyGone)
            <> ", retired by SIGTERM " <> show (count OS.Terminated) <> ", by SIGKILL " <> show (count OS.Killed)
            <> "; convergence blocked on a starting daemon's lock " <> show blocked
            <> "; no listener found, owner kept " <> show unproved)

    , testCase "an injected native launch refusal retires nothing and removes the directory" $
        withTmux $ \exe -> do
          watch <- newWatch
          let refuse _ = pure (N.Refused (N.LaunchRefused N.Execute 11))
              probe = (watching watch Nothing OS.defaultProbe) {OS.hooks = P.defaultHooks {P.launchNative = refuse}}
          outcome <- try @OS.OwnedError (OS.withOwnedServerWith probe exe (\_ -> pure ()))
          case outcome of
            Left (OS.StartRefused (N.LaunchRefused N.Execute 11)) -> pure ()
            other -> assertFailure ("unexpected refusal result: " <> either show (const "success") other)
          assertRetired watch

    , testCase "a real exec refusal (missing executable) retires nothing and removes the directory" $
        withTmux $ \_ -> do
          watch <- newWatch
          outcome <- try @OS.OwnedError $
            OS.withOwnedServerWith (watching watch Nothing OS.defaultProbe) "/nonexistent/libtmux-haskell-tmux" (\_ -> pure ())
          case outcome of
            Left (OS.StartRefused (N.LaunchRefused _ _)) -> pure ()
            other -> assertFailure ("unexpected refusal result: " <> either show (const "success") other)
          assertRetired watch

    , testCase "an unsupported host is refused before any directory, Runtime or process exists" $
        withTmux $ \exe -> withScratch $ \scratch -> do
          let probe = OS.defaultProbe {OS.root = Ascii.pack scratch, OS.features = pure 0}
          outcome <- try @OS.OwnedError (OS.withOwnedServerWith probe exe (\_ -> pure ()))
          case outcome of
            Left (OS.HostUnsupported missing) -> missing @?= [OS.PeerPidfd, OS.PidfdSignal, OS.ProcFdinfo]
            other -> assertFailure ("unexpected host result: " <> either show (const "success") other)
          listDirectory scratch >>= (@?= [])
          mentioning (Ascii.pack scratch) >>= (@?= [])

    , testCase "a borrowed server survives an occupied-path refusal, an owned lifecycle and adoption" $
        withTmux $ \exe -> Fixture.withFixture $ \fixture -> do
          outcome <- try @OS.OwnedError $
            OS.withOwnedServerWith OS.defaultProbe {OS.occupied = Just (Ascii.pack fixture.socket)} exe (\_ -> pure ())
          case outcome of
            Left (OS.AlreadyPresent _) -> pure ()
            other -> assertFailure ("occupied socket was not refused: " <> either show (const "success") other)
          borrowedAlive fixture
          watch <- newWatch
          OS.withOwnedServerWith (watching watch (Just OS.Admitted) OS.defaultProbe) exe $ \owned ->
            void (createOne owned "owned-beside-borrowed")
          assertRetired watch
          borrowedAlive fixture
          Tmux.withServer (adoptConfig fixture) (\_ -> pure ())
          borrowedAlive fixture

    , testCase "a blocked mutation lane does not delay retirement; its operation keeps its history and is detached" $
        withTmux $ \exe -> do
          watch <- newWatch
          how <- newIORef Nothing
          inFlight <- newIORef []
          let probe = (watching watch (Just OS.Admitted) OS.defaultProbe) {OS.retired = writeIORef how . Just}
          outcome <- try @Boom $ OS.withOwnedServerWith probe exe $ \owned -> do
            configure owned ["set-hook", "-g", "after-new-session", "wait-for -S hook-entered ; wait-for hook-release"]
            withAsync (tmux owned ["wait-for", "hook-entered"]) $ \entered ->
              withAsync (createOne owned "blocked-lane") $ \_blocked -> do
                void (bounded (wait entered))
                report <- atomically (R.inspectServerHandle owned.runtime owned.handle)
                writeIORef inFlight (map fst report.unresolved)
                throwIO Boom
          assertBool "callback exception class preserved" (isLeft outcome)
          assertRetired watch
          retirement <- readIORef how
          assertBool "retired through its pidfd" (retirement `elem` [Just OS.Terminated, Just OS.Killed])
          -- Policy: after proven exit the operation is detached, and its recorded outcome stays.
          operations <- readIORef inFlight
          assertBool "an operation was in flight when the callback left" (not (null operations))
          forM_ operations $ \operation -> do
            status <- atomically (S.status operation)
            status.retained @?= False
            assertBool ("outcome kept as history: " <> show status.outcome)
              (status.outcome `elem` [Just S.OutcomeUnknown, Just S.ConnectionRetired])

    , testCase "a hook job that outlives SIGTERM is killed through the pidfd while the mutation lane is blocked" $
        withTmux $ \exe -> withScratch $ \scratch -> do
          let fifo = scratch </> "fifo"
              jobPid = scratch </> "jobpid"
          Files.createNamedPipe fifo 0o600
          watch <- newWatch
          how <- newIORef Nothing
          let probe = (watching watch (Just OS.Admitted) OS.defaultProbe) {OS.retired = writeIORef how . Just}
          -- The open blocks until the hook's foreground job opens the FIFO: the job is running,
          -- and the creation that triggered the hook is stuck behind it in the mutation lane.
          (writer, jobFd) <- withAsync (openWriter fifo) $ \opener ->
            OS.withOwnedServerWith probe exe $ \owned -> do
              configure owned ["set-hook", "-g", "after-new-session",
                "run-shell 'echo $$ > " <> jobPid <> "; read x < " <> fifo <> "'"]
              withAsync (createOne owned "stalled-job") $ \_stuck -> do
                writer <- bounded (wait opener)
                watchPanes watch owned
                job <- readFile jobPid >>= maybe (assertFailure "job PID") pure . readMaybe
                jobFd <- openPidfd job
                assertBool "job pidfd" (jobFd >= 0)
                pure (writer, jobFd)
          assertRetired watch
          readIORef how >>= (@?= Just OS.Killed)
          OS.awaitExit jobFd 0 >>= assertBool "the orphaned job outlived the daemon" . not
          Posix.closeFd writer
          OS.awaitExit jobFd 1000 >>= assertBool "the released job exited"
          N.close jobFd
          mentioning (Ascii.pack scratch) >>= (@?= [])

    , testCase "retirement is independent of a closed command pool and Runtime admission" $
        withTmux $ \exe -> do
          watch <- newWatch
          outcome <- try @Boom $ OS.withOwnedServerWith (watching watch (Just OS.Admitted) OS.defaultProbe) exe $ \owned -> do
            void (createOne owned "owned-closed")
            void (R.requestClose owned.runtime)
            throwIO Boom
          assertBool "callback exception class preserved" (isLeft outcome)
          assertRetired watch

    , testCase "the admission version read takes its deadline from the probe, and a refused deadline still retires the daemon" $
        withTmux $ \exe -> do
          watch <- newWatch
          let probe = (watching watch (Just OS.DaemonOwned) OS.defaultProbe) {OS.versionMicros = 10000001}
          outcome <- try @C.CaptureError (OS.withOwnedServerWith probe exe (\_ -> pure ()))
          case outcome of
            Left (C.InvalidCaptureDeadline 10000001) -> pure ()
            other -> assertFailure ("the probe's deadline was not forwarded: " <> either show (const "success") other)
          assertRetired watch

    , testCase "a kill through the joint owner retires the daemon once; the pool and names stay for the scope's release" $
        withTmux $ \exe -> do
          watch <- newWatch
          retirements <- newIORef []
          let probe = (watching watch (Just OS.Admitted) OS.defaultProbe) {OS.retired = \how -> modifyIORef' retirements (how :)}
          OS.withOwnedServerWith probe exe $ \owned -> do
            void (createOne owned "owned-kill")
            how <- OS.killOwner owned.owner
            assertBool "ended through the pidfd" (how `elem` [OS.Terminated, OS.Killed])
            assertProcessesGone watch
            doesPathExist (Ascii.unpack owned.names.directory) >>= assertBool "the directory outlives the kill"
            OS.killOwner owned.owner >>= (@?= how)
          readIORef retirements >>= (@?= 1) . length
          assertNamesGone watch
    ]
  , testGroup "startup shapes"
    [ testCase "failure and cancellation at every stage after the start client leaves keep their class and retire the daemon" $
        withTmux $ \exe -> forM_ [OS.ClientExited, OS.DaemonOwned, OS.Verified, OS.Admitted] (stageBoundary exe)

    , testCase "a start client that fails, leaves no daemon, or never returns is not proof of no daemon: ownership is retained" startShapes

    , testCase "a stopped daemon whose socket vanished after its client exited keeps ownership until a restored endpoint is found and retired" unlistedDaemon
    , testCase "awaiting a start that left no listener fails with its owner instead of waiting or reporting completion" $
        withScratch $ \scratch -> do
          outcome <- try @SomeException $
            OS.withOwnedServerWith OS.defaultProbe {OS.root = Ascii.pack scratch} "/bin/true" (\_ -> pure ())
          recovery <- OS.recoveryOwner <$> recoveryOf "a start that left no listener" (\case OS.NoDaemon -> True; _ -> False) outcome
          let actions = OS.cleanupActions recovery
          actions.observeCleanup >>= assertBool "an unproved start was reported complete" . not . (.complete)
          try @SomeException (bounded actions.waitCleanup) >>= \case
            Left problem | Just (OS.NotRetired _ _) <- fromException problem -> pure ()
            other -> assertFailure ("await did not keep the unproved start: " <> either show (const "completed") other)
          actions.observeCleanup >>= assertBool "await reported an unproved start complete" . not . (.complete)
    ]
  , testGroup "start-server contract"
    [ testCase "start-server against a live socket is a no-op: the same daemon answers" $
        withTmux $ \exe -> Fixture.withFixture $ \fixture -> do
          before <- daemonWitness fixture
          (code, _, errors) <- readProcess $ setEnv fixture.environment $ setStdin nullStream $
            proc (Ascii.unpack exe) ["-S", fixture.socket, "start-server"]
          (code, errors) @?= (ExitSuccess, "")
          OS.awaitExit before 0 >>= assertBool "the daemon was replaced" . not
          N.close before
          borrowedAlive fixture

    , testCase "a lone start-server daemon leaves with its client; the chained option keeps it" loneStartServer
    ]
  , testGroup "uncertainty and recovery"
    [ testCase "a failed start-client cleanup resumes before the daemon phase" retryStartClient

    , testCase "refused signals retain ownership and the operation; a recovery retires the daemon, then detaches" $
        withTmux $ \exe -> do
          watch <- newWatch
          inFlight <- newIORef []
          let refuse _ _ = pure 1
              probe = (watching watch (Just OS.Admitted) OS.defaultProbe)
                {OS.signal = refuse, OS.graceMs = 20, OS.killMs = 20}
          outcome <- tryWithContext @SomeException $ OS.withOwnedServerWith probe exe $ \owned -> do
            configure owned ["set-hook", "-g", "after-new-session", "wait-for -S hook-entered ; wait-for hook-release"]
            withAsync (tmux owned ["wait-for", "hook-entered"]) $ \entered ->
              withAsync (createOne owned "retained-lane") $ \_blocked -> do
                void (bounded (wait entered))
                report <- atomically (R.inspectServerHandle owned.runtime owned.handle)
                writeIORef inFlight (map fst report.unresolved)
          recovery <- case outcome of
            Left (ExceptionWithContext context problem)
              | Just (OS.NotRetired _ _) <- fromException problem
              , [found] <- OS.ownedRecoveries context -> pure (OS.recoveryOwner found)
            _ -> assertFailure "expected NotRetired with one recovery in the exception context"
          names <- readIORef watch.names >>= maybe (assertFailure "no directory") pure
          daemon <- readIORef watch.daemonFd >>= maybe (assertFailure "no witness") pure
          OS.awaitExit daemon 0 >>= assertBool "daemon is still running" . not
          doesPathExist (Ascii.unpack names.directory) >>= assertBool "names are retained while the daemon runs"
          -- Negative control: the /proc audit does see the daemon that retirement failed to remove.
          mentioning names.directory >>= assertBool "audit sees the retained daemon" . not . null
          operations <- readIORef inFlight
          assertBool "an operation was in flight" (not (null operations))
          forM_ operations $ \operation ->
            atomically (S.status operation) >>= \status ->
              assertBool "live physical responsibility keeps the logical debt" status.retained
          OS.settle recovery {OS.probe = OS.defaultProbe}
          assertRetired watch
          forM_ operations $ \operation ->
            atomically (S.status operation) >>= \status -> status.retained @?= False

    , testCase "awaiting retained daemon cleanup waits on a duplicate and closes it" $
        Fixture.inIsolatedProcess "awaiting retained daemon cleanup waits on a duplicate and closes it" $
        withTmux $ \exe -> do
          normalLifecycle exe
          before <- fdCount
          watch <- newWatch
          let probe = watching watch (Just OS.Admitted) refusingProbe
          outcome <- try @SomeException (OS.withOwnedServerWith probe exe (\_ -> pure ()))
          recovery <- OS.recoveryOwner <$> recoveryOf "the refused retirement" notRetired outcome
          daemon <- readIORef watch.daemonFd >>= maybe (assertFailure "no daemon witness") pure
          let actions = OS.cleanupActions recovery
          (do held <- fdCount
              withAsync actions.waitCleanup $ \waiter -> do
                let awaitDuplicate = do
                      count <- fdCount
                      blocked <- threadStatus (asyncThreadId waiter) >>= \case
                        ThreadBlocked _ -> pure True
                        _ -> pure False
                      stillHeld <- fdCount
                      unless (count == held + 1 && blocked && stillHeld == held + 1) (yield >> awaitDuplicate)
                bounded (race (waitCatch waiter) awaitDuplicate) >>= \case
                  Left ended -> assertFailure ("cleanup wait ended before the daemon exited: " <> either show (const "completed") ended)
                  Right () -> pure ()
                actions.observeCleanup >>= assertBool "cleanup completed while the daemon was alive" . not . (.complete)
                OS.awaitExit daemon 0 >>= assertBool "the witness observed exit before the test signaled it" . not
                N.cSignal daemon sigTERM >>= (@?= 0)
                status <- bounded (wait waiter)
                assertBool "cleanup did not finish after physical exit" status.complete)
            `finally` do
              OS.settle recovery {OS.probe = OS.defaultProbe}
              assertRetired watch
          fdCount >>= (@?= before)

    , testCase "two concurrent settlers signal and close the daemon pidfd exactly once" concurrentSettlers

    , testCase "repeated cancellation while cleanup is held at the daemon, pool and name boundaries (4 rounds each)" $
        withTmux $ \exe -> forM_ [OS.PhaseDaemon, OS.PhasePool, OS.PhaseNames] $ \point ->
          replicateM_ 4 (cancelledTwiceAt exe point)

    , testCase "a pool-phase failure keeps the owner; the retry closes the pin before removing the directory" $
        withTmux $ \exe -> do
          watch <- newWatch
          failing <- newIORef True
          let probe = (watching watch (Just OS.Admitted) OS.defaultProbe)
                {OS.phase = \point -> when (point == OS.PhasePool) $
                   atomicModifyIORef' failing (\armed -> (False, armed)) >>= \armed -> when armed (throwIO Boom)}
          outcome <- tryWithContext @SomeException (OS.withOwnedServerWith probe exe (\_ -> pure ()))
          recovery <- case outcome of
            Left (ExceptionWithContext context problem)
              | Just Boom <- fromException problem
              , [found] <- OS.ownedRecoveries context -> pure (OS.recoveryOwner found)
            _ -> assertFailure "expected the injected pool failure with one recovery"
          assertProcessesGone watch
          names <- readIORef watch.names >>= maybe (assertFailure "no directory") pure
          entries <- listDirectory (Ascii.unpack names.directory)
          assertBool ("the pin directory is still present: " <> show entries) (any ("lt-" `isPrefixOf`) entries)
          OS.settle recovery
          assertNamesGone watch

    , testCase "a name-removal failure stays reachable beside the callback's exception and a retry finishes" $
        withTmux $ \exe -> do
          watch <- newWatch
          intruder <- newIORef ""
          outcome <- tryWithContext @SomeException $
            OS.withOwnedServerWith (watching watch (Just OS.Admitted) OS.defaultProbe) exe $ \owned -> do
              let stray = Ascii.unpack owned.names.directory </> "intruder"
              writeFile stray ""
              writeIORef intruder stray
              throwIO Boom
          recovery <- case outcome of
            Left (ExceptionWithContext context problem)
              | Just Boom <- fromException problem
              , [found] <- OS.ownedRecoveries context
              , Just failure <- OS.recoveryFailure found
              , Just (_ :: IOException) <- fromException failure -> pure (OS.recoveryOwner found)
            _ -> assertFailure "expected Boom primary with the removal failure retained"
          assertProcessesGone watch
          names <- readIORef watch.names >>= maybe (assertFailure "no directory") pure
          doesPathExist (Ascii.unpack names.directory) >>= assertBool "the directory is retained"
          readIORef intruder >>= removePathForcibly
          OS.settle recovery
          assertNamesGone watch

    , testCase "a refused cleanup worker keeps the callback's class; a retry retires the daemon" $
        withTmux $ \exe -> do
          watch <- newWatch
          let probe = (watching watch (Just OS.Admitted) OS.defaultProbe)
                {OS.spawn = \_ -> throwIO (userError "cleanup worker refused")}
          outcome <- tryWithContext @SomeException $
            OS.withOwnedServerWith probe exe (\_ -> throwIO Boom)
          recovery <- case outcome of
            Left (ExceptionWithContext context problem)
              | Just Boom <- fromException problem
              , [found] <- OS.ownedRecoveries context
              , Just failure <- OS.recoveryFailure found
              , Just (_ :: IOException) <- fromException failure -> pure (OS.recoveryOwner found)
            _ -> assertFailure "expected Boom primary with the refused worker retained"
          daemon <- readIORef watch.daemonFd >>= maybe (assertFailure "no witness") pure
          OS.awaitExit daemon 0 >>= assertBool "no worker ran, so the daemon is still running" . not
          OS.settle recovery {OS.probe = OS.defaultProbe}
          assertRetired watch

    , testCase "a callback failure keeps its class when a second cancellation interrupts the held cleanup wait; the cancellation and owner stay attached" $
        withTmux callbackFailureThenCancellation
    ]
  , testGroup "name ownership"
    [ testCase "a replacement listener at the original socket path survives retirement; the owner stays until it is removed" replacedSocket
    , testCase "a replacement private directory at the original path survives retirement; the owner stays until the namespace is restored" (replacedDirectory True)
    , testCase "a renamed private directory stays owned when its original path is absent" (replacedDirectory False)
    , testCase "a lock name that appears after startup is never unlinked; the owner stays until it is removed" unrecordedLock
    ]
  , testGroup "bounded acquisition"
    [ testCase "convergence waits for a starting daemon's lock until it is unlinked, then finds no listener" $
        withTmux $ \exe -> withScratch $ \scratch -> do
          let names = scratchNames scratch
              lock = scratch </> "s.lock"
          blocked <- newIORef Nothing
          busy <- newEmptyMVar
          owner <- OS.newOwner OS.defaultProbe {OS.lockWait = writeIORef blocked . Just, OS.lockBusy = putMVar busy ()} exe
          -- Held as a pre-listen daemon holds it. A daemon releases it after listen by
          -- unlinking the file and closing the descriptor, in that order.
          held <- withCString lock holdLock
          assertBool "lock held" (held >= 0)
          withAsync (OS.converge owner names) $ \waiter -> do
            bounded (takeMVar busy)
            Files.removeLink lock
            Posix.closeFd (Fd held)
            bounded (wait waiter) >>= (@?= Nothing)
          readIORef blocked >>= (@?= Just True)

    , testCase "a lock that never frees expires the bound instead of hanging" $
        withTmux $ \exe -> withScratch $ \scratch -> do
          let names = scratchNames scratch
          owner <- OS.newOwner OS.defaultProbe {OS.lockMs = 100} exe
          held <- withCString (scratch </> "s.lock") holdLock
          assertBool "lock held" (held >= 0)
          outcome <- try @OS.OwnedError (OS.converge owner names)
          case outcome of
            Left OS.LockWaitExpired -> pure ()
            other -> assertFailure ("expected the lock bound to expire: " <> either show show other)
          Posix.closeFd (Fd held)
          OS.converge owner names >>= (@?= Nothing)
    ]
  , testGroup "adopted kill"
    [ testCase "verification rejects a pidfd that names any other process" $
        withTmux $ \exe -> Fixture.withFixture $ \fixture -> do
          runtime <- R.newRuntime P.normalFork
          adopted <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
          self <- getProcessID
          selfFd <- openPidfd (fromIntegral self)
          assertBool "self pidfd" (selfFd >= 0)
          (try @OS.OwnedError (OS.verifyPinned OS.defaultProbe runtime adopted exe selfFd) >>= \case
              Left (OS.DaemonMismatch _ (Just named)) -> named @?= toInteger self
              other -> assertFailure ("mismatch not detected: " <> either show show other))
            `finally` (N.close selfFd >> void (R.shutdown runtime))
          borrowedAlive fixture

    , testCase "an adopted kill ends the daemon through its held pidfd; the daemon's real parent reaps it" $
        withTmux $ \exe -> Fixture.withFixture $ \fixture -> do
          runtime <- R.newRuntime P.normalFork
          adopted <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
          (withKill OS.defaultProbe exe runtime adopted $ \capability -> do
              how <- OS.killAdopted capability
              assertBool "ended through the pidfd" (how `elem` [OS.Terminated, OS.Killed])
              code <- timeout 2000000 (Fixture.awaitDaemon fixture.daemon)
              -- tmux exits 0 on SIGTERM; what matters is that the fixture, the daemon's real parent, reaped it.
              assertBool "the fixture's own child observed the exit" (isJust code))
            `finally` void (R.shutdown runtime)

    , testCase "an adopted kill after the daemon left reports AlreadyGone; admission keeps no descriptor" $
        Fixture.inIsolatedProcess "an adopted kill after the daemon left reports AlreadyGone; admission keeps no descriptor" $
        withTmux $ \exe -> Fixture.withFixture $ \fixture -> do
          runtime <- R.newRuntime P.normalFork
          -- Leaving the scope closes a handle's admission, so each admission gets its own handle.
          first <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
          second <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
          third <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
          withKill OS.defaultProbe exe runtime first (\_ -> pure ())
          before <- fdCount
          withKill OS.defaultProbe exe runtime second (\_ -> pure ())
          fdCount >>= (@?= before)
          (withKill OS.defaultProbe exe runtime third $ \capability -> do
              void (Fixture.command fixture ["kill-server"])
              timeout 2000000 (Fixture.awaitDaemon fixture.daemon) >>= assertBool "the real parent saw the exit" . isJust
              OS.killAdopted capability >>= (@?= OS.AlreadyGone))
            `finally` void (R.shutdown runtime)

    , testCase "an adopted kill needs no tmux answer, lane or pool: stopped daemon, full backlog, blocked creation, closed pool" $
        withTmux $ \exe -> Fixture.withFixture $ \fixture -> do
          runtime <- R.newRuntime P.normalFork
          adopted <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
          witness <- daemonWitness fixture
          queued <- newIORef []
          let probe = OS.defaultProbe {OS.graceMs = 50}
              pinned = Ascii.unpack (Pin.pinPath (R.serverPin adopted))
          ((withKill probe exe runtime adopted $ \capability -> do
              wedged <- wedge fixture witness
              writeIORef queued wedged
              withAsync (createOn runtime adopted exe "stuck-creation") $ \_stuck -> do
                bounded (awaitInFlight runtime adopted)
                void (R.shutdown runtime)
                bounded (R.awaitCleanup runtime)
                doesPathExist pinned >>= assertBool "the pin is gone with the closed pool" . not
                how <- OS.killAdopted capability
                -- A stopped process cannot act on SIGTERM; the pidfd's SIGKILL ends it.
                how @?= OS.Killed
                timeout 2000000 (Fixture.awaitDaemon fixture.daemon) >>= assertBool "the real parent saw the exit" . isJust)
            `finally` (void (N.cSignal witness sigCONT)))
            `finally` (readIORef queued >>= mapM_ N.close >> N.close witness)

    , testCase "an adopted kill refuses a rebound socket after its post-listen event; a fresh capability ends the daemon" $
        withTmux $ \exe -> Fixture.withFixture $ \fixture -> do
          runtime <- R.newRuntime P.normalFork
          adopted <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
          witness <- daemonWitness fixture
          queued <- newIORef []
          (do withKill OS.defaultProbe exe runtime adopted $ \capability -> do
                -- Stopped and saturated, the daemon holds unaccepted connections to its old
                -- listener. tmux closes that listener only after it is listening on the new
                -- socket, so the reset of the last queued connection is a post-listen event.
                wedged <- wedge fixture witness
                writeIORef queued wedged
                void (N.cSignal witness sigUSR1)
                void (N.cSignal witness sigCONT)
                bounded (awaitReset (last wedged))
                try @OS.OwnedError (OS.killAdopted capability) >>= \case
                  Left OS.StaleGeneration -> pure ()
                  other -> assertFailure ("stale generation not refused: " <> either show show other)
                borrowedAlive fixture
              readIORef queued >>= mapM_ N.close >> writeIORef queued []
              adoptedAgain <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
              withKill OS.defaultProbe exe runtime adoptedAgain $ \fresh ->
                OS.killAdopted fresh >>= \how -> assertBool "ended through the pidfd" (how `elem` [OS.Terminated, OS.Killed])
              timeout 2000000 (Fixture.awaitDaemon fixture.daemon) >>= assertBool "the real parent saw the exit" . isJust)
            `finally` (void (N.cSignal witness sigCONT) >> readIORef queued >>= mapM_ N.close >> N.close witness
                         >> void (R.shutdown runtime))

    , testCase "a failed adoption-only release resumes as a release: the borrowed daemon stays alive and the descriptors close" $
        Fixture.inIsolatedProcess "a failed adoption-only release resumes as a release" $
        withTmux $ \exe -> Fixture.withFixture $ \fixture -> do
          runtime <- R.newRuntime P.normalFork
          adopted <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
          failing <- newIORef True
          let probe = OS.defaultProbe {OS.phase = \point -> when (point == OS.PhaseDaemon) $
                atomicModifyIORef' failing (\armed -> (False, armed)) >>= \armed -> when armed (throwIO Boom)}
          before <- fdCount
          (do outcome <- try @SomeException (withKill probe exe runtime adopted (\_ -> pure ()))
              recovery <- OS.recoveryOwner <$> recoveryOf "the failed release" (\Boom -> True) outcome
              borrowedAlive fixture
              OS.settle recovery
              survived <- try @HUnitFailure (borrowedAlive fixture)
              assertBool "the resume of an adoption-only release terminated the borrowed daemon" (isRight survived)
              fdCount >>= (@?= before))
            `finally` void (R.shutdown runtime)

    , testCase "a failed explicit kill attaches its owner where it is raised, so a callback that catches it can still recover" $
        withTmux $ \exe -> Fixture.withFixture $ \fixture -> do
          runtime <- R.newRuntime P.normalFork
          adopted <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
          (do inner <- newIORef (Right ())
              outer <- try @SomeException $ withKill refusingProbe exe runtime adopted $ \capability ->
                try @SomeException (OS.killAdopted capability) >>= writeIORef inner . void
              readIORef inner >>= void . recoveryOf "the kill failure caught inside the callback" notRetired
              -- The scope release must not discard the kill descriptor either.
              void (recoveryOf "the scope release after the swallowed kill failure" notRetired outer))
            `finally` void (R.shutdown runtime)

    , testCase "a failed explicit kill keeps its single owner and descriptors through scope release; the resume retires the daemon" $
        withTmux $ \exe -> Fixture.withFixture $ \fixture -> do
          runtime <- R.newRuntime P.normalFork
          adopted <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
          (do outer <- try @SomeException $ withKill refusingProbe exe runtime adopted $ \capability ->
                void (OS.killAdopted capability)
              -- The failure leaves the callback untouched and the scope's own failed release adds the
              -- same owner: it is attached once.
              recovery <- OS.recoveryOwner <$> recoveryOf "the propagated kill failure" notRetired outer
              Fixture.pollDaemon fixture.daemon >>= (@?= Nothing)
              OS.settle recovery {OS.probe = OS.defaultProbe}
              timeout 2000000 (Fixture.awaitDaemon fixture.daemon)
                >>= assertBool "the resume retired the daemon through the retained pidfd" . isJust)
            `finally` void (R.shutdown runtime)

    , testCase "a late kill refuses once the callback has left, and the held release stays a release" $
        Fixture.inIsolatedProcess "a late kill refuses once the callback has left, and the held release stays a release" $
        withTmux $ \exe -> Fixture.withFixture $ \fixture -> do
          runtime <- R.newRuntime P.normalFork
          adopted <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
          witness <- daemonWitness fixture
          reached <- newEmptyMVar
          proceed <- newEmptyMVar
          queued <- newEmptyMVar
          spawned <- newIORef (0 :: Int)
          escaped <- newIORef Nothing
          -- The scope's release is the first worker and holds the gate at the daemon phase; the late kill is the second.
          let probe = (holdingDaemonPhase reached proceed OS.defaultProbe)
                {OS.spawn = \work -> do
                  count <- atomicModifyIORef' spawned (\n -> (n + 1, n + 1))
                  when (count == 2) (void (tryPutMVar queued ()))
                  OS.defaultSpawn work}
              open = OS.admissionOpen adopted
          before <- fdCount
          (do withAsync (OS.withKillCapability probe exe runtime adopted $ \admitted ->
                           either throwIO (writeIORef escaped . Just) admitted) $ \scope -> do
                awaitEvent scope reached
                capability <- readIORef escaped >>= maybe (assertFailure "no capability was admitted") pure
                withAsync (try @SomeException (OS.killAdoptedIf open capability)) $ \late -> do
                  awaitEvent late queued
                  putMVar proceed ()
                  waitCatch scope >>= either (assertFailure . ("the release failed: " <>) . show) pure
                  wait late >>= \case
                    Left problem | Just Scope.ServerClosed <- fromException problem -> pure ()
                    other -> assertFailure ("a late kill was not refused: " <> either show show other)
              OS.awaitExit witness 0 >>= assertBool "a kill after the callback left ended the borrowed daemon" . not
              borrowedAlive fixture
              fdCount >>= (@?= before))
            `finally` (N.close witness >> void (R.shutdown runtime))

    , testCase "a kill admitted before the callback left keeps its authority over the release" $
        withTmux $ \exe -> Fixture.withFixture $ \fixture -> do
          runtime <- R.newRuntime P.normalFork
          adopted <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
          witness <- daemonWitness fixture
          reached <- newEmptyMVar
          proceed <- newEmptyMVar
          escaped <- newEmptyMVar
          let probe = holdingDaemonPhase reached proceed OS.defaultProbe
              open = OS.admissionOpen adopted
          -- The kill passes its check and journals its request, then holds the gate; the callback leaves
          -- and closes admission; only then does the kill finish.
          (withAsync (OS.withKillCapability probe exe runtime adopted $ \admitted -> do
              capability <- either throwIO pure admitted
              killer <- async (OS.killAdoptedIf open capability)
              putMVar escaped killer
              awaitEvent killer reached) $ \scope -> do
              killer <- takeMVar escaped
              bounded (atomically (readTVar (R.serverPool adopted).closing >>= check))
              putMVar proceed ()
              wait killer >>= \how -> assertBool "the admitted kill ended through the pidfd" (how `elem` [OS.Terminated, OS.Killed])
              waitCatch scope >>= either (assertFailure . ("the release failed: " <>) . show) pure
              OS.awaitExit witness 0 >>= assertBool "the admitted kill did not end the daemon"
              timeout 2000000 (Fixture.awaitDaemon fixture.daemon) >>= assertBool "the real parent saw the exit" . isJust)
            `finally` (N.close witness >> void (R.shutdown runtime))

    , testCase "an unsupported host leaves plain adoption to the callback, and the kill's failure is the stored one" $
        Fixture.inIsolatedProcess "an unsupported host leaves plain adoption to the callback, and the kill's failure is the stored one" $
        withTmux $ \exe -> Fixture.withFixture $ \fixture -> do
          runtime <- R.newRuntime P.normalFork
          adopted <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
          before <- fdCount
          (do stored <- OS.withKillCapability OS.defaultProbe {OS.features = pure 0} exe runtime adopted $ \admitted -> do
                void (C.captureSnapshot runtime adopted exe 2000000)
                pure (either (fromException @OS.OwnedError) (const Nothing) admitted)
              case stored of
                Just (OS.HostUnsupported _) -> pure ()
                other -> assertFailure ("the callback did not receive the admission failure: " <> show other)
              fdCount >>= (@?= before)
              borrowedAlive fixture)
            `finally` void (R.shutdown runtime)

    , testCase "an identity read that fails leaves plain adoption to the callback, with no logical debt kept for its unknown outcome" $
        withTmux $ \exe -> Fixture.withFixture $ \fixture -> do
          runtime <- R.newRuntime P.normalFork
          adopted <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
          let probe = OS.defaultProbe {OS.hooks = P.defaultHooks {P.afterStart = throwIO (userError "read checkpoint failed")}}
          (do stored <- OS.withKillCapability probe exe runtime adopted $ \admitted -> do
                report <- atomically (R.inspectServerHandle runtime adopted)
                length report.unresolved @?= 0
                pure (either (fromException @IOException) (const Nothing) admitted)
              fmap ioeGetErrorString stored @?= Just "read checkpoint failed"
              borrowedAlive fixture)
            `finally` void (R.shutdown runtime)

    , testCase "an admission failure whose release fails never reaches the callback and keeps its owner" $
        withTmux $ \exe -> Fixture.withFixture $ \fixture -> do
          runtime <- R.newRuntime P.normalFork
          adopted <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
          failing <- newIORef True
          entered <- newIORef False
          let probe = OS.defaultProbe {OS.features = pure 0, OS.phase = \point -> when (point == OS.PhaseDaemon) $
                atomicModifyIORef' failing (\armed -> (False, armed)) >>= \armed -> when armed (throwIO Boom)}
          (do outcome <- try @SomeException (OS.withKillCapability probe exe runtime adopted (\_ -> writeIORef entered True))
              readIORef entered >>= assertBool "the callback ran although the partial capability could not be released" . not
              recovery <- recoveryOf "the failed release" (\case OS.HostUnsupported _ -> True; _ -> False) outcome
              case OS.recoveryFailure recovery >>= fromException of
                Just Boom -> pure ()
                Nothing -> assertFailure "the retained owner does not carry the release failure"
              OS.settle (OS.recoveryOwner recovery))
            `finally` void (R.shutdown runtime)
    ]
  ]

-- Name ownership ------------------------------------------------------------

-- | The kernel identity of whatever a path names now, without following links.
identityAt :: FilePath -> IO (Maybe (DeviceID, FileID))
identityAt path = (Just . (\status -> (Files.deviceID status, Files.fileID status)) <$> Files.getSymbolicLinkStatus path)
  `catch` \(problem :: IOException) -> if isDoesNotExistError problem then pure Nothing else throwIO problem

-- | A recorded path with the identity this test gave it. Test cleanup removes a path only while
-- it still names that identity, so a library mistake can never make the test delete anything else.
data Planted = Planted {path :: FilePath, planted :: Maybe (DeviceID, FileID)}

plant :: FilePath -> IO Planted
plant path = Planted path <$> identityAt path

-- | Remove the planted name, once, if and only if it is still the recorded one.
unplant :: IORef (Maybe Planted) -> (FilePath -> IO ()) -> IO ()
unplant ref remove = atomicModifyIORef' ref (\held -> (Nothing, held)) >>= mapM_ (\recorded ->
  identityAt recorded.path >>= \now -> when (isJust now && now == recorded.planted) (remove recorded.path))

-- | The callback of an unsettled scope: the application's exception stays primary, one owner is
-- attached, and its cleanup failure is recorded.
retainedAfter :: String -> Either SomeException a -> IO OS.OwnedRecovery
retainedAfter label outcome = do
  recovery <- recoveryOf label (\Boom -> True) outcome
  assertBool (label <> ": the cleanup failure is retained") (isJust (OS.recoveryFailure recovery))
  pure recovery

-- | The original daemon's socket path is unlinked and a test-owned listener binds the same path,
-- then the callback fails. The original daemon must still retire through its pidfd and the
-- replacement name and listener must survive; the scope stays unsettled until the test removes
-- exactly the listener and name it planted.
replacedSocket :: Assertion
replacedSocket = withTmux $ \exe -> do
  watch <- newWatch
  listener <- newIORef Nothing
  replacement <- newIORef Nothing
  let discard = do
        unplant replacement Files.removeLink
        atomicModifyIORef' listener (\held -> (Nothing, held)) >>= mapM_ (Posix.closeFd . Fd)
  (do outcome <- try @SomeException $ OS.withOwnedServerWith (watching watch (Just OS.Admitted) OS.defaultProbe) exe $ \owned -> do
        let socket = Ascii.unpack owned.names.socket
        Files.removeLink socket
        fd <- withCString socket (\name -> listenAt name 1)
        assertBool "the replacement listener bound the original path" (fd >= 0)
        writeIORef listener (Just fd)
        plant socket >>= writeIORef replacement . Just
        throwIO Boom
      assertProcessesGone watch
      recorded <- readIORef replacement >>= maybe (assertFailure "no replacement was planted") pure
      identityAt recorded.path >>= \now ->
        assertBool "cleanup unlinked the replacement socket name" (now == recorded.planted)
      self <- getProcessID
      OS.peerPidfd (Ascii.pack recorded.path) >>= \case
        Right pidfd -> (OS.pidfdPid pidfd >>= (@?= Just (toInteger self))) `finally` N.close pidfd
        Left problem -> assertFailure ("the replacement listener is unreachable: errno " <> show problem)
      recovery <- retainedAfter "the replaced socket name" outcome
      names <- readIORef watch.names >>= maybe (assertFailure "no directory") pure
      doesPathExist (Ascii.unpack names.directory) >>= assertBool "the private directory is retained with its owner"
      discard
      OS.settle (OS.recoveryOwner recovery)
      assertNamesGone watch)
    `finally` (discard >> retireWitnessed watch)

-- | After the original witness is held and before the pin is acquired, the private directory is
-- renamed to a recorded backup and an empty directory takes its path. The original daemon must still
-- retire; the replacement must stay and the owner remain until the test restores the namespace
-- from the exact paths it recorded.
replacedDirectory :: Bool -> Assertion
replacedDirectory replace = withTmux $ \exe -> do
  watch <- newWatch
  backup <- newIORef Nothing
  replacement <- newIORef Nothing
  let displace point names = when (point == OS.DaemonOwned) $ do
        let original = Ascii.unpack names.directory
            moved = original <> ".displaced"
        Files.rename original moved
        writeIORef backup (Just moved)
        when replace $ do
          createDirectory original
          plant original >>= writeIORef replacement . Just
        throwIO Boom
      probe = watching watch (Just OS.DaemonOwned) OS.defaultProbe {OS.stage = displace}
      discard = do
        unplant replacement removeDirectory
        atomicModifyIORef' backup (\held -> (Nothing, held)) >>= mapM_ removePathForcibly
  (do outcome <- try @SomeException (OS.withOwnedServerWith probe exe (\_ -> pure ()))
      assertProcessesGone watch
      names <- readIORef watch.names >>= maybe (assertFailure "no original directory") pure
      let original = Ascii.unpack names.directory
      when replace $ do
        recorded <- readIORef replacement >>= maybe (assertFailure "no replacement was planted") pure
        identityAt recorded.path >>= \now ->
          assertBool "cleanup removed the replacement private directory" (now == recorded.planted)
      recovery <- retainedAfter "the replaced private directory" outcome
      -- Restore the namespace with the exact paths acquired above, then resume.
      unplant replacement removeDirectory
      moved <- readIORef backup >>= maybe (assertFailure "no backup was recorded") pure
      Files.rename moved original
      writeIORef backup Nothing
      OS.settle (OS.recoveryOwner recovery)
      assertNamesGone watch)
    `finally` (discard >> retireWitnessed watch)

-- | Normal tmux unlinks its startup lock once it listens, so a lock name present after
-- admission is not evidence that this run made it. It must stay, and the directory with it.
unrecordedLock :: Assertion
unrecordedLock = withTmux $ \exe -> do
  watch <- newWatch
  lock <- newIORef Nothing
  let discard = unplant lock Files.removeLink
  (do outcome <- try @SomeException $ OS.withOwnedServerWith (watching watch (Just OS.Admitted) OS.defaultProbe) exe $ \owned -> do
        let path = Ascii.unpack owned.names.socket <> ".lock"
        writeFile path ""
        plant path >>= writeIORef lock . Just
        throwIO Boom
      assertProcessesGone watch
      recorded <- readIORef lock >>= maybe (assertFailure "no lock was planted") pure
      identityAt recorded.path >>= \now ->
        assertBool "cleanup unlinked a lock name it never recorded" (now == recorded.planted)
      recovery <- retainedAfter "the unrecorded lock name" outcome
      discard
      OS.settle (OS.recoveryOwner recovery)
      assertNamesGone watch)
    `finally` (discard >> retireWitnessed watch)

-- Cases --------------------------------------------------------------------

-- | Descriptor 900 is never allocated here (the kernel hands out the lowest free number),
-- so after closing it the descriptor is reliably invalid: POLLNVAL, not another file.
invalidDescriptor :: Assertion
invalidDescriptor = do
  self <- getProcessID
  live <- openPidfd (fromIntegral self)
  assertBool "self pidfd" (live >= 0)
  _ <- Posix.dupTo (Fd live) (Fd 900)
  N.close 900
  OS.awaitExit live 0 >>= assertBool "a live process is not an exit" . not
  N.close live
  try @IOException (OS.awaitExit 900 0) >>= \case
    Left _ -> pure ()
    Right gone -> assertFailure ("a closed descriptor was read as a physical exit: " <> show gone)
  try @IOException (OS.awaitExit (-1) 0) >>= either (const (pure ())) (const (assertFailure "negative descriptor accepted"))

saturatedListener :: Assertion
saturatedListener = withScratch $ \scratch -> do
  let path = scratch </> "s"
  listenerClosed <- newIORef False
  let acquire = do
        listener <- withCString path (\name -> listenAt name 1)
        assertBool "listener" (listener >= 0)
        pure listener
      closeListener listener = do
        wasClosed <- atomicModifyIORef' listenerClosed (\closed -> (True, closed))
        unless wasClosed (N.close listener)
  bracket acquire closeListener $ \listener ->
    bracket (saturating path) (mapM_ N.close) $ \queued -> do
      assertBool "backlog filled" (not (null queued))
      -- A blocking connect would hang here; the bounded form answers at once.
      timeout 1000000 (OS.peerPidfd (Ascii.pack path)) >>= \case
        Just (Left problem) -> problem @?= N.errno eAGAIN
        Just (Right pidfd) -> N.close pidfd >> assertFailure "a full backlog produced a pidfd"
        Nothing -> assertFailure "peer acquisition did not return within one second"
      closeListener listener
      -- A concurrent fork may still hold the listener until exec; its queued peer proves closure.
      bounded (awaitReset (last queued))
      OS.peerPidfd (Ascii.pack path) >>= \case
        Left problem -> problem @?= N.errno eCONNREFUSED
        Right pidfd -> N.close pidfd >> assertFailure "a closed listener produced a pidfd"

normalLifecycle :: ByteString -> IO ()
normalLifecycle exe = do
  watch <- newWatch
  (created, pid, listed) <- OS.withOwnedServerWith (watching watch (Just OS.Admitted) OS.defaultProbe) exe $ \owned -> do
    created <- createOne owned "owned-normal"
    watchPane watch owned created
    -- The chained option is what keeps the empty daemon alive after its start client left.
    (code, option, _) <- tmux owned ["show-options", "-gv", "exit-empty"]
    (code, option) @?= (ExitSuccess, "off\n")
    snapshot <- captureOne owned
    pure (created, owned.daemonPid, isRight (G.lookupSession (G.entities snapshot) created.session))
  listed @?= True
  created.serverPid @?= pid
  assertRetired watch

-- | Two settlers race for one recovery. Attempts queue behind the owner's gate, so the
-- daemon's pidfd is signaled and closed by exactly one attempt. Without the gate both
-- attempts read the same journaled descriptor and close it twice.
concurrentSettlers :: Assertion
concurrentSettlers = withTmux $ \exe -> do
  watch <- newWatch
  mode <- newIORef (FailOnce :: Mode)
  entered <- newIORef (0 :: Int)
  release <- newEmptyMVar
  signals <- newIORef []
  closes <- newIORef []
  let probe = (watching watch (Just OS.Admitted) OS.defaultProbe)
        { OS.phase = \point -> when (point == OS.PhaseDaemon) $ readIORef mode >>= \case
            FailOnce -> writeIORef mode Hold >> throwIO Boom
            Hold -> modifyIORef' entered (+ 1) >> readMVar release
        , OS.signal = \pidfd number -> modifyIORef' signals ((pidfd, number) :) >> N.cSignal pidfd number
        , OS.closeFd = \pidfd -> modifyIORef' closes (pidfd :) >> N.close pidfd }
  outcome <- tryWithContext @SomeException (OS.withOwnedServerWith probe exe (\_ -> pure ()))
  recovery <- case outcome of
    Left (ExceptionWithContext context problem)
      | Just Boom <- fromException problem, [found] <- OS.ownedRecoveries context -> pure (OS.recoveryOwner found)
    _ -> assertFailure "expected the injected daemon-phase failure with one recovery"
  daemon <- readIORef watch.daemonFd >>= maybe (assertFailure "no witness") pure
  OS.awaitExit daemon 0 >>= assertBool "the failed attempt left the daemon running" . not
  withAsync (OS.settle recovery) $ \first -> withAsync (OS.settle recovery) $ \second -> do
    awaitWorkers 2
    putMVar release ()
    wait first
    wait second
  readIORef mode >>= \case Hold -> pure (); _ -> assertFailure "hold mode was not reached"
  terminations <- length . filter ((== sigTERM) . snd) <$> readIORef signals
  closed <- readIORef closes
  assertBool ("at most one SIGTERM, saw " <> show terminations) (terminations <= 1)
  assertBool ("the daemon pidfd was closed exactly once, saw " <> show closed) (length closed == 1)
  assertRetired watch

data Mode = FailOnce | Hold

-- | Wait, boundedly, until exactly this many cleanup workers are blocked on an MVar:
-- one at the held phase and one queued behind the gate, or both held without a gate.
awaitWorkers :: Int -> Assertion
awaitWorkers wanted = timeout 2000000 loop >>= maybe (assertFailure "cleanup workers did not park") pure
  where
    loop = do
      workers <- cleanupWorkers
      parked <- filterM (\worker -> (== ThreadBlocked BlockedOnMVar) <$> threadStatus worker) workers
      if length parked == wanted && length workers == wanted then pure () else yield >> loop

cleanupWorkers :: IO [ThreadId]
cleanupWorkers = do
  threads <- listThreads
  labelled <- forM threads $ \thread -> (,) thread <$> threadLabel thread
  filterM (\thread -> (`notElem` [ThreadFinished, ThreadDied]) <$> threadStatus thread)
    [thread | (thread, Just "libtmux-owned-cleanup") <- labelled]

-- | Cancel the caller twice while cleanup is held at a boundary. The held worker, not
-- the cancelled caller, finishes: the daemon is gone and the names are removed once it
-- is released, and the recovery stays reachable from the exception.
cancelledTwiceAt :: ByteString -> OS.Phase -> Assertion
cancelledTwiceAt exe point = do
  watch <- newWatch
  entered <- newEmptyMVar
  reached <- newEmptyMVar
  proceed <- newEmptyMVar
  finished <- newEmptyMVar
  never <- newEmptyMVar @()
  let probe = (watching watch (Just OS.Admitted) OS.defaultProbe)
        { OS.phase = \current -> when (current == point) (void (tryPutMVar reached ()) >> readMVar proceed)
        , OS.spawn = \work -> OS.defaultSpawn (work `finally` void (tryPutMVar finished ())) }
  outcome <- withAsync
    (OS.withOwnedServerWith probe exe $ \owned -> do
      void (createOne owned "owned-double")
      putMVar entered ()
      takeMVar never) $ \worker -> do
    awaitEvent worker entered
    withAsync (cancel worker) $ \first -> do
      awaitEvent worker reached
      daemon <- readIORef watch.daemonFd >>= maybe (assertFailure "no witness") pure
      alive <- not <$> OS.awaitExit daemon 0
      assertBool "the boundary is where the test thinks it is" (alive == (point == OS.PhaseDaemon))
      names <- readIORef watch.names >>= maybe (assertFailure "no directory") pure
      doesPathExist (Ascii.unpack names.directory) >>= assertBool "names are present at every held boundary"
      withAsync (throwTo (asyncThreadId worker) Boom) $ \second -> do
        void (waitCatch second)
        void (waitCatch first)
        putMVar proceed ()
      waitCatch worker
  problem <- case outcome of
    Left caught
      | Just AsyncCancelled <- fromException caught -> pure caught
      | Just Boom <- fromException caught -> pure caught
    other -> assertFailure ("unexpected outcome after two cancellations: " <> either show (const "success") other)
  recovery <- case OS.ownedRecoveries (someExceptionContext problem) of
    [found] -> pure (OS.recoveryOwner found)
    _ -> assertFailure "one OwnedRecovery is reachable from the exception context"
  -- No new attempt starts: the cleanup worker that was held finishes by itself, even
  -- though both callers left, and a later settle only finds the work done.
  bounded (takeMVar finished)
  assertRetired watch
  OS.settle recovery

-- | The same boundary twice: a failure and a cancellation at one startup stage. The daemon
-- witness is opened at that stage, so retirement is checked physically, not by absence.
stageBoundary :: ByteString -> OS.Stage -> Assertion
stageBoundary exe point = do
  failed <- newWatch
  failure <- try @Boom $ OS.withOwnedServerWith
    (watching failed (Just point) OS.defaultProbe {OS.stage = \current _ -> when (current == point) (throwIO Boom)}) exe (\_ -> pure ())
  assertBool ("failure class preserved at " <> show point) (isLeft failure)
  assertRetired failed
  cancelled <- newWatch
  reached <- newEmptyMVar
  never <- newEmptyMVar @()
  let probe = watching cancelled (Just point) OS.defaultProbe
        {OS.stage = \current _ -> when (current == point) (putMVar reached () >> takeMVar never)}
  outcome <- withAsync (OS.withOwnedServerWith probe exe (\_ -> pure ())) $ \worker -> do
    awaitEvent worker reached
    cancel worker
    waitCatch worker
  assertCancelled outcome
  assertRetired cancelled

-- | Three ways the start client can end without a daemon the library holds. None proves that no
-- daemon exists: a failed or custom executable may have started one, and an absent or refusing
-- socket is not death proof. Each keeps its owner and its private directory. Only an atomic
-- launch refusal, which has no child, removes the directory (covered above). The blocked client
-- is still killed and reaped, never abandoned.
startShapes :: Assertion
startShapes = withScratch $ \scratch -> withScratch $ \scripts -> do
  let attempt executable probe = try @SomeException $
        OS.withOwnedServerWith probe {OS.root = Ascii.pack scratch} executable (\_ -> pure ())
      retained label matches outcome = do
        recovery <- recoveryOf label matches outcome
        case OS.recoveryFailure recovery >>= fromException of
          Just (OS.NotRetired _ _) -> pure ()
          _ -> assertFailure (label <> ": the retained owner does not report an unproved start")
        listDirectory scratch >>= \entries -> length entries @?= 1
        listDirectory scratch >>= mapM_ (removePathForcibly . (scratch </>))
  attempt "/bin/false" OS.defaultProbe >>= retained "a failed start"
    (\case OS.StartFailed (Just (N.Exited 1)) _ -> True; _ -> False)
  attempt "/bin/true" OS.defaultProbe >>= retained "a start that left no listener"
    (\case OS.NoDaemon -> True; _ -> False)
  let blocker = scripts </> "block.sh"
  writeFile blocker "#!/bin/sh\nexec /bin/sleep 613\n"
  Files.setFileMode blocker 0o755
  attempt (Ascii.pack blocker) OS.defaultProbe {OS.startMs = 100} >>= retained "a start that never returned"
    (\case OS.StartTimedOut -> True; _ -> False)
  mentioning "/bin/sleep\NUL613\NUL" >>= (@?= [])

-- | The start client exited, then the daemon was stopped and its socket path unlinked before the
-- library acquired a pidfd. No listener and an exited client are not death proof: the run must
-- not complete, the private directory must stay, and the attached owner must find the daemon
-- again once the endpoint is restored. The stopped daemon is restored and ended only through the
-- test's own pidfd, which also cleans up a failed case.
unlistedDaemon :: Assertion
unlistedDaemon = withTmux $ \exe -> do
  watch <- newWatch
  queued <- newIORef []
  let vanish point names = when (point == OS.ClientExited) $ do
        daemon <- readIORef watch.daemonFd >>= maybe (assertFailure "no witness") pure
        N.cSignal daemon sigSTOP >>= (@?= 0)
        -- Connections queued on the old listener reset once the daemon listens on a new socket.
        wedged <- saturating (Ascii.unpack names.socket)
        assertBool "backlog filled" (not (null wedged))
        writeIORef queued wedged
        Files.removeLink (Ascii.unpack names.socket)
      probe = watching watch (Just OS.ClientExited) OS.defaultProbe {OS.stage = vanish}
  (do outcome <- try @SomeException (OS.withOwnedServerWith probe exe (\_ -> pure ()))
      case outcome of
        Right _ -> assertFailure "a stopped daemon with an unlinked socket was reported as a completed run"
        Left _ -> pure ()
      names <- readIORef watch.names >>= maybe (assertFailure "no directory") pure
      daemon <- readIORef watch.daemonFd >>= maybe (assertFailure "no witness") pure
      OS.awaitExit daemon 0 >>= assertBool "the stopped daemon is still alive" . not
      doesPathExist (Ascii.unpack names.directory)
        >>= assertBool "the private directory was removed while the born daemon is alive"
      recovery <- recoveryOf "the unproved start" (\case OS.NoDaemon -> True; _ -> False) outcome
      -- Restore the endpoint: the stopped daemon rebinds its socket once it runs again.
      void (N.cSignal daemon sigUSR1)
      void (N.cSignal daemon sigCONT)
      wedged <- readIORef queued
      bounded (awaitReset (last wedged))
      OS.settle (OS.recoveryOwner recovery)
      assertRetired watch)
    `finally` do
      retireWitnessed watch
      readIORef queued >>= mapM_ N.close
      readIORef watch.names >>= mapM_ (removePathForcibly . Ascii.unpack . (.directory))

-- | End a witnessed daemon that a failed case may have left stopped, through its pidfd only.
retireWitnessed :: Watch -> IO ()
retireWitnessed watch = readIORef watch.daemonFd >>= mapM_ (\pidfd -> do
  void (N.cSignal pidfd sigCONT)
  void (N.cSignal pidfd sigTERM)
  exited <- OS.awaitExit pidfd 2000
  unless exited (void (N.cSignal pidfd sigKILL) >> void (OS.awaitExit pidfd 2000))
  N.close pidfd
  writeIORef watch.daemonFd Nothing)

-- | The one recovery an unsettled run attached to an exception of the expected class.
recoveryOf :: Exception e => String -> (e -> Bool) -> Either SomeException a -> IO OS.OwnedRecovery
recoveryOf wanted matches = \case
  Left caught
    | Just known <- fromException caught, matches known
    , [found] <- OS.ownedRecoveries (someExceptionContext caught) -> pure found
    | otherwise -> assertFailure (wanted <> ": saw " <> show caught <> " with "
        <> show (length (OS.ownedRecoveries (someExceptionContext caught))) <> " attached recoveries")
  Right _ -> assertFailure (wanted <> ": the run completed")

notRetired :: OS.OwnedError -> Bool
notRetired = \case OS.NotRetired _ _ -> True; _ -> False

-- | Every signal is refused, so an explicit kill cannot observe the daemon's exit.
refusingProbe :: OS.Probe
refusingProbe = OS.defaultProbe {OS.signal = \_ _ -> pure 1, OS.graceMs = 20, OS.killMs = 20}

-- | The callback fails, then a second cancellation interrupts the wait for cleanup, which is held
-- at the daemon phase. The application error keeps its class, the cancellation and the owner stay
-- attached, and the held worker still retires the daemon once released.
callbackFailureThenCancellation :: ByteString -> Assertion
callbackFailureThenCancellation exe = do
  watch <- newWatch
  reached <- newEmptyMVar
  proceed <- newEmptyMVar
  finished <- newEmptyMVar
  let probe = (watching watch (Just OS.Admitted) OS.defaultProbe)
        { OS.phase = \current -> when (current == OS.PhaseDaemon) (void (tryPutMVar reached ()) >> readMVar proceed)
        , OS.spawn = \work -> OS.defaultSpawn (work `finally` void (tryPutMVar finished ())) }
      release = void (tryPutMVar proceed ())
  (do outcome <- withAsync (OS.withOwnedServerWith probe exe (\_ -> throwIO Boom)) $ \worker -> do
        bounded (takeMVar reached)
        cancel worker
        waitCatch worker
      recovery <- recoveryOf "the callback failure" (\Boom -> True) outcome
      case OS.recoveryFailure recovery >>= fromException of
        Just AsyncCancelled -> pure ()
        Nothing -> assertFailure "the cancellation that interrupted the cleanup wait is not attached"
      release
      bounded (readMVar finished)
      assertRetired watch
      OS.settle (OS.recoveryOwner recovery))
    `finally` (release >> void (timeout 2000000 (readMVar finished)))

-- | The premise behind the chained option, without the library: a lone daemon exits once
-- its client leaves, and one that ran @exit-empty off@ in the same client stays.
loneStartServer :: Assertion
loneStartServer = withTmux $ \exe -> do
  (lone, option) <- heldStart exe []
  option @?= "on\n"
  OS.awaitExit lone 2000 >>= assertBool "a lone daemon exits once its client left"
  N.close lone
  (chained, kept) <- heldStart exe ["set-option", "-g", "exit-empty", "off", ";"]
  kept @?= "off\n"
  rc <- N.cSignal chained sigTERM
  rc @?= 0
  OS.awaitExit chained 2000 >>= assertBool "the chained daemon was retired through its pidfd"
  N.close chained

-- | Run @start-server ; EXTRA run-shell HOLD@ as a client held attached by a foreground job.
-- The daemon's pidfd is taken once its lock is gone (it is listening) while the client is
-- still attached, so nothing races the daemon's own exit. The hold is then released and the
-- client's exit awaited. Returns the pidfd and the daemon's reported @exit-empty@.
heldStart :: ByteString -> [String] -> IO (CInt, Lazy.ByteString)
heldStart exe extra = withScratch $ \scratch -> do
  let names = scratchNames scratch
      socket = scratch </> "s"
      fifo = scratch </> "fifo"
      arguments = ["-u", "-S", socket, "-f", "/dev/null", "start-server", ";"]
        <> extra <> ["run-shell", "read x < " <> fifo <> " || true"]
      config = setEnv [("LANG", "C.UTF-8")] $ setStdin nullStream $ setStdout nullStream $ setStderr nullStream $
        proc (Ascii.unpack exe) arguments
  Files.createNamedPipe fifo 0o600
  withProcessTerm config $ \client -> do
    awaitCreated names "s.lock"
    void (OS.awaitLock names.directory (names.socket <> ".lock") (pure ()))
    pidfd <- OS.peerPidfd names.socket >>= either (\problem -> assertFailure ("no listener: errno " <> show problem)) pure
    (code, shown, _) <- readProcess $ setEnv [("LANG", "C.UTF-8")] $ setStdin nullStream $
      proc (Ascii.unpack exe) ["-N", "-S", socket, "show-options", "-gv", "exit-empty"]
    code @?= ExitSuccess
    -- The job opens the FIFO for reading; this open waits for it, then ends its read.
    writer <- bounded (openWriter fifo)
    Posix.closeFd writer
    waitExitCode client >>= (@?= ExitSuccess)
    pure (pidfd, shown)

-- Helpers ------------------------------------------------------------------

retryStartClient :: Assertion
retryStartClient = withTmux $ \executable -> do
  armed <- newIORef True
  let hooks = P.defaultHooks {P.signalChild = \child -> readIORef armed >>= \case
        True -> throwIO Boom
        False -> N.signalChild child 9}
      probe = OS.defaultProbe {OS.hooks = hooks, OS.clientMs = 20}
  owner <- OS.newOwner probe executable
  (runtime, serverOwner) <- maybe (assertFailure "missing server owner") pure owner.scope
  let cleanup = writeIORef armed False >> void (R.shutdown runtime) >> R.awaitCleanup runtime
  (`finally` cleanup) $ do
    let pool = R.serverOwnerPool serverOwner
    ticket <- P.submitInputRegistered (const (pure ())) B.Ordinary hooks pool
      (N.spec "/bin/cat" ["/bin/cat"]) P.KeepInputOpen
    OS.journal owner (\held -> held {OS.client = Just ticket})
    atomically (readTMVar ticket.launchEvidence) >>= (@?= P.NativeStarted)
    child <- readIORef ticket.child >>= maybe (assertFailure "missing client child") pure
    pid <- OS.pidfdPid child.pidfd >>= maybe (assertFailure "client exited before the witness") pure
    witness <- openPidfd (fromIntegral pid)
    assertBool "client witness" (witness >= 0)
    (`finally` N.close witness) $ do
      P.abort ticket
      bounded $ atomically $ do
        failed <- readTVar ticket.cleanupFailure
        busy <- readTVar ticket.busy
        check (isJust failed && not busy)
      try @OS.OwnedError (OS.settle owner) >>= \case
        Left (OS.NotRetired _ _) -> pure ()
        other -> assertFailure ("expected a retained start client: " <> either show (const "success") other)
      OS.awaitExit witness 0 >>= assertBool "the failed cleanup lost its live client" . not
      writeIORef armed False
      try @OS.OwnedError (OS.settle owner) >>= \case
        Right () -> pure ()
        Left problem -> assertFailure ("retry never resumed the registered start client cleanup: " <> show problem)
      OS.awaitExit witness 0 >>= assertBool "the resumed cleanup did not retire the client"

withTmux :: (ByteString -> IO a) -> IO a
withTmux action = lookupEnv "LIBTMUX_TEST_TMUX" >>= \case
  Just path@('/' : _) -> action (Ascii.pack path)
  _ -> assertFailure "LIBTMUX_TEST_TMUX must name the absolute release under test"

withScratch :: (FilePath -> IO a) -> IO a
withScratch = bracket (mkdtemp "/tmp/libtmux-haskell-scratch-") removePathForcibly

-- | Wait for an event the worker should raise. If the worker ends first its own result is the
-- failure, so a broken system under test fails the case at once instead of hanging it.
awaitEvent :: Async a -> MVar () -> Assertion
awaitEvent worker event = race (waitCatch worker) (takeMVar event) >>= \case
  Left ended -> assertFailure ("the worker ended before the event: " <> either show (const "returned normally") ended)
  Right () -> pure ()

bounded :: IO a -> IO a
bounded action = timeout 2000000 action >>= maybe (assertFailure "owned event did not arrive within two seconds") pure

assertCancelled :: Either SomeException a -> Assertion
assertCancelled outcome = case outcome of
  Left problem | Just AsyncCancelled <- fromException problem -> pure ()
  Left problem -> assertFailure ("cancellation changed class: " <> show problem)
  Right _ -> assertFailure "cancelled bracket returned normally"

-- | After a start that failed or was cancelled while its client ran. A client killed before it
-- forked leaves nothing that distinguishes it from a hidden daemon, so either the daemon was found
-- and retired and its names are gone, or the owner and directory are retained. Either way no live
-- process names the directory. Returns whether the owner was retained, and removes the directory.
assertSettledOrRetained :: Exception e => Watch -> (e -> Bool) -> Either SomeException a -> IO Bool
assertSettledOrRetained watch matches outcome = do
  names <- readIORef watch.names >>= maybe (assertFailure "no private directory was observed") pure
  assertProcessesGone watch
  mentioning names.directory >>= (@?= [])
  retained <- doesPathExist (Ascii.unpack names.directory)
  when retained $ do
    void (recoveryOf "an aborted start that found no listener" matches outcome)
    removePathForcibly (Ascii.unpack names.directory)
  pure retained

fdCount :: IO Int
fdCount = length <$> listDirectory "/proc/self/fd"

-- | Test seams that record the private directory and open independent witnesses.
watching :: Watch -> Maybe OS.Stage -> OS.Probe -> OS.Probe
watching watch at probe = probe {OS.stage = \point names -> do
  writeIORef watch.names (Just names)
  when (Just point == at) (openDaemon watch names)
  probe.stage point names}

openDaemon :: Watch -> OS.Names -> IO ()
openDaemon watch names = OS.peerPidfd names.socket >>= \case
  Right pidfd -> writeIORef watch.daemonFd (Just pidfd)
  Left problem -> assertFailure ("witness could not reach the daemon: errno " <> show problem)

watchPane :: Watch -> OS.Owned -> G.CreatedSession -> IO ()
watchPane watch owned created = do
  let G.PaneRef _ paneIdent = created.pane
  (code, output, _) <- tmux owned
    ["display-message", "-p", "-t", Text.unpack (Id.renderPaneId paneIdent), "-F", "#{pane_pid}"]
  code @?= ExitSuccess
  pid <- maybe (assertFailure "invalid pane PID") pure (readMaybe (Ascii.unpack (Lazy.toStrict output)))
  pidfd <- openPidfd pid
  assertBool "pane pidfd" (pidfd >= 0)
  modifyIORef' watch.paneFds (pidfd :)

-- | Block, boundedly, until the directory gains the name; the watch is armed before the check.
awaitCreated :: OS.Names -> String -> IO ()
awaitCreated names name = bracket (Ascii.useAsCString names.directory watchCreate) (Posix.closeFd . Fd) $ \watch -> do
  present <- doesPathExist (Ascii.unpack names.directory </> name)
  unless present $ void $ timeout 2000000 $ waitFor watch
  where
    waitFor watch = threadWaitRead (Fd watch) >> withCString name (createdName watch) >>= \seen ->
      unless (seen == 1) (waitFor watch)

scratchNames :: FilePath -> OS.Names
scratchNames scratch = OS.Names (Ascii.pack scratch) (Ascii.pack (scratch </> "s"))

-- | Readable and reset: the listener that held this unaccepted connection has closed.
awaitReset :: CInt -> IO ()
awaitReset fd = threadWaitRead (Fd fd) >> hungUp fd >>= \seen -> unless (seen == 1) (awaitReset fd)

-- | A pidfd on the borrowed fixture daemon, opened through its own pid report. The
-- daemon is the fixture's unreaped child, so that pid cannot have been reused.
daemonWitness :: Fixture.Fixture -> IO CInt
daemonWitness fixture = do
  (code, output, _) <- Fixture.command fixture ["display-message", "-p", "#{pid}"]
  code @?= ExitSuccess
  pid <- maybe (assertFailure "daemon PID") pure (readMaybe (Ascii.unpack (Lazy.toStrict output)))
  pidfd <- openPidfd pid
  assertBool "daemon pidfd" (pidfd >= 0)
  pure pidfd

-- | Stop the daemon and fill its listen backlog: no tmux command can reach it now.
wedge :: Fixture.Fixture -> CInt -> IO [CInt]
wedge fixture witness = do
  rc <- N.cSignal witness sigSTOP
  rc @?= 0
  queued <- saturating fixture.socket
  assertBool "backlog filled" (not (null queued))
  pure queued

saturating :: FilePath -> IO [CInt]
saturating path = withCString path $ \name -> allocaArray 1024 $ \fds -> do
  count <- saturate name fds 1024
  when (count < 0) (throwErrno "saturate")
  peekArray (fromIntegral count) fds

-- | Wait, by STM, until an operation of this handle has left the queue.
awaitInFlight :: R.Runtime -> R.ServerHandle -> IO ()
awaitInFlight runtime server = atomically $ do
  report <- R.inspectServerHandle runtime server
  check (any ((/= S.Queued) . (.stage) . snd) report.unresolved)

-- | Witness every pane process of the owned daemon, whatever created it.
watchPanes :: Watch -> OS.Owned -> IO ()
watchPanes watch owned = do
  (code, output, _) <- tmux owned ["list-panes", "-a", "-F", "#{pane_pid}"]
  code @?= ExitSuccess
  forM_ (Ascii.lines (Lazy.toStrict output)) $ \line -> do
    pid <- maybe (assertFailure "invalid pane PID") pure (readMaybe (Ascii.unpack line))
    pidfd <- openPidfd pid
    assertBool "pane pidfd" (pidfd >= 0)
    modifyIORef' watch.paneFds (pidfd :)

-- | After the bracket: the daemon and panes are physically gone (witness pidfds
-- readable), the private directory is removed, and no process names it.
assertRetired :: Watch -> IO ()
assertRetired watch = assertProcessesGone watch >> assertNamesGone watch

assertProcessesGone :: Watch -> IO ()
assertProcessesGone watch = do
  readIORef watch.daemonFd >>= \daemon -> forM_ daemon $ \pidfd -> do
    OS.awaitExit pidfd 0 >>= assertBool "daemon pidfd readable: the original daemon exited"
    N.close pidfd
  writeIORef watch.daemonFd Nothing
  readIORef watch.paneFds >>= \panes -> forM_ panes $ \pidfd -> do
    OS.awaitExit pidfd 1000 >>= assertBool "pane process exited"
    N.close pidfd
  writeIORef watch.paneFds []

assertNamesGone :: Watch -> IO ()
assertNamesGone watch = do
  names <- readIORef watch.names >>= maybe (assertFailure "no private directory was observed") pure
  doesPathExist (Ascii.unpack names.directory) >>= assertBool "private directory removed" . not
  mentioning names.directory >>= (@?= [])

-- | Command lines of live processes that mention a private path.
mentioning :: ByteString -> IO [ByteString]
mentioning needle = do
  entries <- filter (all isDigit) <$> listDirectory "/proc"
  concat <$> forM entries (\entry ->
    (do cmd <- Bytes.readFile ("/proc" </> entry </> "cmdline")
        pure [cmd | needle `Bytes.isInfixOf` cmd]) `catch` \(_ :: IOException) -> pure [])

createOne :: OS.Owned -> Text -> IO G.CreatedSession
createOne owned = createOn owned.runtime owned.handle owned.executable

createOn :: R.Runtime -> R.ServerHandle -> ByteString -> Text -> IO G.CreatedSession
createOn runtime server executable name = Create.performCreation P.defaultHooks 2000000 runtime server executable
  Creation.defaultSessionOptions
    { Creation.name = Just name
    , Creation.process = Creation.DirectCommand (Os.fromBytestring "/bin/cat") (Os.fromBytestring "-" :| []) }

captureOne :: OS.Owned -> IO G.Snapshot
captureOne owned = do
  (started, finished, decoded) <- C.captureSnapshot owned.runtime owned.handle owned.executable 2000000
  either (assertFailure . show) pure (G.stampSnapshot started finished decoded)

-- | A separate command client addressed at the owned socket by path.
tmux :: OS.Owned -> [String] -> IO (ExitCode, Lazy.ByteString, Lazy.ByteString)
tmux owned arguments = readProcess $ setEnv [("LANG", "C.UTF-8")] $ setStdin nullStream $
  proc (Ascii.unpack owned.executable) (["-N", "-S", Ascii.unpack owned.names.socket] <> arguments)

configure :: OS.Owned -> [String] -> Assertion
configure owned arguments = do
  (code, output, errors) <- tmux owned arguments
  (code, output, errors) @?= (ExitSuccess, "", "")

-- | Hold the cleanup worker at its daemon phase, with the owner's gate taken, until released.
holdingDaemonPhase :: MVar () -> MVar () -> OS.Probe -> OS.Probe
holdingDaemonPhase reached proceed probe = probe
  {OS.phase = \point -> when (point == OS.PhaseDaemon) (void (tryPutMVar reached ()) >> readMVar proceed)}

-- | The kill capability, with any admission failure raised: the existing cases need the capability.
withKill :: OS.Probe -> ByteString -> R.Runtime -> R.ServerHandle -> (OS.Kill -> IO a) -> IO a
withKill probe exe runtime adopted action = OS.withKillCapability probe exe runtime adopted (either throwIO action)

borrowedAlive :: Fixture.Fixture -> Assertion
borrowedAlive fixture = do
  Fixture.pollDaemon fixture.daemon >>= (@?= Nothing)
  (code, _, errors) <- Fixture.command fixture ["display-message", "-p", "#{pid}"]
  (code, errors) @?= (ExitSuccess, "")
  doesPathExist fixture.socket >>= assertBool "borrowed socket still present"

adoptConfig :: Fixture.Fixture -> Tmux.ServerConfig
adoptConfig fixture = (Tmux.serverConfig (Os.fromBytestring (Ascii.pack fixture.socket)))
  {Tmux.executable = Os.fromBytestring (Ascii.pack fixture.executable)}
