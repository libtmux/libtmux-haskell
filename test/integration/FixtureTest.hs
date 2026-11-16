module FixtureTest (tests) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async (AsyncCancelled (..), cancel, race, wait, waitCatch, waitEither, withAsync)
import Control.Exception (Exception, SomeException, bracket, IOException, finally, fromException, throwIO, try)
import Control.Monad (void, when)
import Data.ByteString.Lazy.Char8 qualified as Bytes
import Data.Foldable (for_, traverse_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Foreign.C.Types (CInt)
import Fixture
import GHC.Clock (getMonotonicTime)
import GHC.Conc (closeFdWith, threadWaitRead)
import System.FilePath ((</>))
import System.Posix.Files (createNamedPipe, readSymbolicLink)
import System.Posix.IO (OpenFileFlags (..), OpenMode (ReadOnly), closeFd, defaultFileFlags, openFd)
import System.Posix.Types (Fd (..))
import System.Timeout (timeout)
import System.Directory
  ( doesDirectoryExist, emptyPermissions, removeFile, setOwnerExecutable, setOwnerReadable
  , setPermissions
  )
import System.Exit (ExitCode (..))
import System.IO.Error (ioeGetErrorString, ioeGetLocation, isDoesNotExistError, isPermissionError)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests = testGroup "owned tmux fixture"
  [ testCase "observes daemon and initial pane exit after success" $ do
      fixture <- withFixture $ \fixture -> do
        (code, output, errors) <- command fixture ["list-sessions", "-F", "#{session_name}"]
        code @?= ExitSuccess
        output @?= "fixture\n"
        errors @?= ""
        pure fixture
      assertReleased fixture
  , testCase "cleans up when the callback fails" $ do
      saved <- newIORef Nothing
      result <- try @IOException $ withFixture $ \fixture -> do
        writeIORef saved (Just fixture)
        throwIO (userError "fixture callback failed")
      case result of
        Left problem -> ioeGetErrorString problem @?= "fixture callback failed"
        Right () -> assertFailure "callback should have failed"
      readIORef saved >>= maybe (assertFailure "callback never started") assertReleased
  , testCase "cleans up after asynchronous cancellation" $ do
      ready <- newEmptyMVar
      never <- newEmptyMVar @()
      withAsync (withFixture $ \fixture -> putMVar ready fixture >> takeMVar never) $ \worker -> do
        race (wait worker) (takeMVar ready) >>= \case
          Left () -> assertFailure "fixture returned before cancellation"
          Right fixture -> do
            cancel worker
            waitCatch worker >>= \case
              Left problem -> case fromException problem of
                Just AsyncCancelled -> pure ()
                Nothing -> assertFailure ("unexpected worker failure: " <> show problem)
              Right () -> assertFailure "worker returned without cancellation"
            assertReleased fixture
  , testCase "releases control clients after callback failure and cancellation" $
      withFixture $ \fixture -> do
        failed <- try @IOException (withAttachedClient fixture "$0" (throwIO (userError "control callback failed")))
        case failed of
          Left problem -> ioeGetErrorString problem @?= "control callback failed"
          Right () -> assertFailure "control callback should have failed"
        command fixture ["list-clients", "-F", "#{client_pid}"] >>= (@?= (ExitSuccess, "", ""))
        ready <- newEmptyMVar
        never <- newEmptyMVar @()
        withAsync (withAttachedClient fixture "$0" (putMVar ready () >> takeMVar never)) $ \worker -> do
          race (wait worker) (takeMVar ready) >>= \case
            Left () -> assertFailure "control callback returned before cancellation"
            Right () -> cancel worker
          waitCatch worker >>= \case
            Left problem -> case fromException problem of
              Just AsyncCancelled -> pure ()
              Nothing -> assertFailure (show problem)
            Right () -> assertFailure "control callback returned without cancellation"
        command fixture ["list-clients", "-F", "#{client_pid}"] >>= (@?= (ExitSuccess, "", ""))
  , testCase "cancellation before dispatch stops the owned daemon" (cancelDuringStartup False)
  , testCase "cancellation before pane tracking observes the original pane exit" (cancelDuringStartup True)
  , testCase "cancellation while session creation waits in its hook retires the original pane" cancelPendingCreation
  , testCase "tracked pane teardown survives cancellation at callback entry" $
      withFixture $ \fixture -> do
        (code, pid, errors) <- command fixture
          ["new-window", "-d", "-t", "fixture:1", "-P", "-F", "#{pane_pid}", "/bin/cat", "-"]
        (code, errors) @?= (ExitSuccess, "")
        let teardown = command fixture ["kill-window", "-t", "fixture:1"] >>= (@?= (ExitSuccess, "", ""))
        result <- try @AsyncCancelled (withTrackedPane pid teardown (throwIO AsyncCancelled))
        result @?= Left @AsyncCancelled @() AsyncCancelled
  , testCase "a failing pane teardown never replaces the body's exception and is raised after a clean body" $
      withFixture $ \fixture -> for_ [True, False] $ \failing -> do
        (code, pid, errors) <- command fixture
          ["new-window", "-d", "-t", "fixture:1", "-P", "-F", "#{pane_pid}", "/bin/cat", "-"]
        (code, errors) @?= (ExitSuccess, "")
        let teardown = do
              command fixture ["kill-window", "-t", "fixture:1"] >>= (@?= (ExitSuccess, "", ""))
              throwIO (userError "teardown failed")
        result <- try @SomeException (withTrackedPane pid teardown (when failing (throwIO Boom)))
        case (failing, result) of
          (True, Left problem) -> fromException problem @?= Just Boom
          (False, Left problem) -> fmap ioeGetErrorString (fromException problem) @?= Just "teardown failed"
          _ -> assertFailure ("unexpected outcome: " <> show result)
  , testCase "a daemon ended outside the fixture is collected once, after success and after failure" $
      for_ [False, True] $ \failing -> do
        saved <- newIORef Nothing
        result <- try @IOException $ withFixture $ \fixture -> do
          writeIORef saved (Just fixture)
          void (command fixture ["kill-server"])
          when failing (throwIO (userError "body failed"))
        case (failing, result) of
          (False, Right ()) -> pure ()
          (True, Left problem) -> ioeGetErrorString problem @?= "body failed"
          _ -> assertFailure ("unexpected outcome: " <> show result)
        readIORef saved >>= maybe (assertFailure "callback never started") assertReleased
  , testCase "retiring a daemon collects no other child" $
      withDaemon retirement "bystander" "/bin/sh" ["-c", "exit 7"] [] $ \bystander -> do
        -- A readable pidfd means the bystander has exited and is waiting to be collected.
        threadWaitRead bystander.pidfd
        withFixture (\_ -> pure ())
        awaitDaemon bystander >>= (@?= ExitFailure 7)
  , testCase "a refused daemon never runs its body, and one that exits at once reports its status" $ do
      refused <- try @IOException (withDaemon retirement "missing" "/nonexistent/fixture-daemon" [] [] (\_ -> assertFailure "ran"))
      either (assertBool "refusal is not a missing file" . isDoesNotExistError) (const (assertFailure "a missing program started")) refused
      withDaemon retirement "exits at once" "/bin/false" [] [] awaitDaemon >>= (@?= ExitFailure 1)
  , testCase "a waiter blocked on a daemon is released with its status by the retirement" $
      withDaemon retirement "sleeper" "/bin/sleep" ["30"] [] $ \sleeper ->
        withAsync (awaitDaemon sleeper) $ \waiter -> do
          retireDaemon sleeper
          timeout 2000000 (wait waiter) >>= (@?= Just (ExitFailure (-15)))
  , testCase "retirement signals only a live child, escalates to SIGKILL, and keeps one that survives" retireBounds
  , testCase "a client's streams, status, arguments and environment pass through exactly" clientFidelity
  , testCase "a failed or cancelled client scope retires its client once and keeps its cause" clientScopes
  , testCase "cancelling command ends the running client within the bound" commandCancellation
  , testCase "a client that ignores SIGTERM is killed, and one that survives is retained with the body's cause" clientEscalation
  , testCase "a control client reports a missing acknowledgement, stderr and a failed exit" controlClientFailures
  ]

-- | A body failure of a class no cleanup raises, so only its preservation can pass the test.
data Boom = Boom deriving (Eq, Show)

instance Exception Boom

-- | Run an action that may block uninterruptibly, as a retirement does and 'timeout' cannot
-- interrupt, and fail the test at the bound. A worker that outlives the bound is not abandoned:
-- 'rescue' ends what it waits on, and the worker is joined before the test fails.
boundedly :: IO () -> IO a -> IO a
boundedly rescue action = do
  done <- newEmptyMVar
  _ <- forkIO (try action >>= putMVar done)
  timeout 2000000 (takeMVar done) >>= \case
    Just result -> either (throwIO @SomeException) pure result
    Nothing -> do
      rescue
      void (timeout 2000000 (takeMVar done))
      assertFailure "retirement blocked past its bound"

describe :: Either SomeException a -> String
describe = \case
  Right _ -> "returned"
  Left problem -> case (fromException problem, fromException problem) of
    (Just Boom, _) -> "Boom"
    (_, Just io) -> ioeGetErrorString io
    _ -> show problem

-- | Signals are logged in delivery order. A swallowed signal reaches the pidfd's owner as
-- success, as it would for a child that ignores it. A delivered signal ends the sleeping child,
-- and the stub sees that before it returns, so the short step below never races the child's exit:
-- only a swallowed signal lets a step expire. Every child the test starts is ended for real,
-- through its own pidfd, however the test leaves.
retireBounds :: IO ()
retireBounds = do
  sent <- newIORef []
  mine <- newIORef []
  let quick = retirement {step = 20000}
      logged :: [CInt] -> Retirement
      logged swallow = quick {deliver = \fd number -> do
        modifyIORef' sent (<> [number])
        if number `elem` swallow then pure 0 else do
          rc <- quick.deliver fd number
          when (rc == 0) (threadWaitRead fd)
          pure rc}
      observe :: IO a -> IO (a, [CInt])
      observe action = writeIORef sent [] >> action >>= \result -> (result,) <$> readIORef sent
      owned :: Retirement -> String -> FilePath -> [String] -> (Daemon -> IO a) -> IO a
      owned retiring label program arguments body =
        withDaemon retiring label program arguments [] (\owner -> modifyIORef' mine (owner :) >> body owner)
      sleeper :: Retirement -> (Daemon -> IO a) -> IO a
      sleeper retiring = owned retiring "sleeper" "/bin/sleep" ["30"]
      endAll = readIORef mine >>= traverse_ (\owner -> retireDaemon owner {how = quick})
      -- Tests run in parallel, so the registry may hold other tests' owners.
      retainedMine :: IO [Daemon]
      retainedMine = do
        ours <- map (.phase) <$> readIORef mine
        filter ((`elem` ours) . (.phase)) <$> retainedDaemons
      bounded :: IO a -> IO a
      bounded = boundedly endAll
  flip finally endAll $ do
    -- Already collected: nothing is signaled.
    bounded (observe (owned (logged []) "exited" "/bin/true" [] awaitDaemon)) >>= (@?= (ExitSuccess, []))
    -- A live child gets SIGTERM only.
    bounded (observe (sleeper (logged []) (\_ -> pure ()))) >>= (@?= ((), [15]))
    -- SIGTERM swallowed: SIGKILL ends it within the second step.
    bounded (observe (sleeper (logged [15]) pure >>= pollDaemon)) >>= (@?= (Just (ExitFailure (-9)), [15, 9]))
    -- Both swallowed: bounded, the body's exception keeps its class, and the owner is kept.
    let stuck = logged [15, 9]
    try @SomeException (bounded (sleeper stuck (\_ -> throwIO Boom))) >>= (@?= "Boom") . describe
    try @SomeException (bounded (sleeper stuck (\_ -> pure ()))) >>= (@?= "fixture daemon did not exit: sleeper") . describe
    -- A refused delivery is raised with its cause instead of waiting out the bound; the child stays owned.
    refused <- try @IOException (bounded (sleeper quick {deliver = \_ _ -> pure 1} (\_ -> pure ())))
    either (\problem -> (isPermissionError problem, ioeGetLocation problem)) (const (False, "returned")) refused
      @?= (True, "fixture daemon signal")
    retainedMine >>= (@?= ["sleeper", "sleeper", "sleeper"]) . map (.label)
    -- A step is microseconds: SIGKILL follows SIGTERM, and the failure follows SIGKILL, one step
    -- later each. A step read as a tenth or as ten times too long leaves these bounds.
    stamped <- newIORef []
    let ms = 50
        timed = retirement {step = ms * 1000, deliver = \_ _ -> do
          at <- getMonotonicTime
          modifyIORef' stamped (<> [at])
          pure 0}
    try @SomeException (bounded (sleeper timed (\_ -> pure ()))) >>= (@?= "fixture daemon did not exit: sleeper") . describe
    failedAt <- getMonotonicTime
    readIORef stamped >>= \case
      [terminated, killed] ->
        for_ [killed - terminated, failedAt - killed] $ \seconds -> do
          let gap = round (seconds * 1000) :: Int
          assertBool ("a retirement step lasted " <> show gap <> " ms, not about " <> show ms <> " ms")
            (gap * 10 >= ms * 9 && gap < ms * 5)
      other -> assertFailure ("expected a SIGTERM and a SIGKILL delivery, saw " <> show (length other))
    -- End them for real through the retained pidfds, with the default bounds.
    retainedMine >>= traverse_ (\owner -> retireDaemon owner {how = retirement})
    retainedMine >>= (@?= []) . map (.label)

-- | A client program for the fixture: a shell script in its directory that opens descriptor 3 on
-- a marker pipe and, when it writes @up@, has finished its setup. 'announced' returns then.
-- 'ended' returns once every process holding that descriptor is gone, so a test sees a client
-- die without a PID. Both give up after a second, which only a failing test reaches.
data Script = Script {announced :: IO (), ended :: IO ()}

withScript :: Fixture -> String -> (Fixture -> Script -> IO a) -> IO a
withScript fixture body use = do
  let path = fixture.directory </> "client"
      marker = fixture.directory </> "marker"
  writeFile path ("#!/bin/sh\nexec 3>\"${0%/*}/marker\"\n" <> body)
  setPermissions path (setOwnerExecutable True (setOwnerReadable True emptyPermissions))
  createNamedPipe marker 0o600
  let open = openFd marker ReadOnly defaultFileFlags {nonBlock = True, cloexec = True}
      script end = Script
        { announced = timeout 1000000 (threadWaitRead end >> readSome end) >>= (@?= Just (Just "up"))
        , ended = timeout 1000000 (readSome end) >>= (@?= Just Nothing)
        }
  bracket open closeFd (use fixture {executable = path} . script) `finally` (removeFile marker >> removeFile path)

-- | A client that has set up and then runs until signaled, and one that also ignores SIGTERM. A
-- client that nothing ends still exits on its own after ten seconds.
running, ignoringTerm :: String
running = "printf up >&3\nexec sleep 10\n"
ignoringTerm = "trap '' TERM\n" <> running

-- | What a descriptor names now, so a closed pipe end is seen closed even when another test, which
-- runs in parallel, has since been given its number.
referent :: Fd -> IO (Maybe FilePath)
referent (Fd number) = either (const Nothing) Just <$> try @IOException (readSymbolicLink ("/proc/self/fd/" <> show number))

-- | The pipe ends a client holds and what they name.
pipeEnds :: Client -> IO [(Fd, Maybe FilePath)]
pipeEnds client = traverse (\end -> (end,) <$> referent end) [client.output, client.errors]

-- | Each end still names a different object, or none: the pipes were closed.
assertClosed :: [(Fd, Maybe FilePath)] -> IO ()
assertClosed ends = for_ ends $ \(end, named) -> do
  assertBool "the client's pipe was never open" (named /= Nothing)
  now <- referent end
  assertBool "a client's pipe end stayed open" (now /= named)

-- | The owners this fixture's directory keeps. Tests run in parallel, so the registry also holds
-- other tests' owners, which these tests neither inspect nor end.
retainedBy :: Fixture -> IO [Daemon]
retainedBy fixture = filter ((== fixture.directory) . (.home)) <$> retainedDaemons

cancelledBy :: Either SomeException a -> String
cancelledBy = \case
  Left problem | Just AsyncCancelled <- fromException problem -> "cancelled"
  other -> describe other

-- | Stdout, stderr, arguments and environment are bytes. Each stream outgrows its pipe, so the
-- readers must drain both at once. The child's stdin reads end of file, even when the test's own
-- stdin is open and idle.
clientFidelity :: IO ()
clientFidelity = withFixture $ \fixture -> do
  let script = unlines
        [ "printf '%s\\000' \"$@\""
        , "head -c 300000 /dev/zero | tr '\\000' e >&2"
        , "printf '%s|%s' \"$PROBE\" \"${LIBTMUX_TEST_TMUX-absent}\" >&2"
        , "if read line; then printf stdin >&2; fi"
        , "head -c 300000 /dev/zero | tr '\\000' o"
        , "printf '\\377\\000\\376'"
        , "exit 3"
        ]
  withScript fixture script $ \stub _ -> do
    let isolated = stub {environment = [("PATH", "/usr/bin:/bin"), ("PROBE", "x\xDCFFy")]}
        expectedOut = "-N\0-S\0" <> Bytes.pack stub.socket <> "\0a b\0\255\0\195\169\0"
          <> Bytes.replicate 300000 'o' <> "\255\0\254"
        expectedErr = Bytes.replicate 300000 'e' <> "x\255y|absent"
    result <- timeout 5000000 (command isolated ["a b", "\xDCFF", "\xDCC3\xDCA9"])
    fmap (\(code, out, err) -> (code, out == expectedOut, err == expectedErr)) result
      @?= Just (ExitFailure 3, True, True)
  -- A refused start raises the system's error.
  refused <- try @IOException (command fixture {executable = "/nonexistent/client"} [])
  either isDoesNotExistError (const False) refused @?= True

-- | A body that fails and one that is cancelled both leave the client collected once, by
-- SIGTERM, with the primary cause intact and its pipes closed.
clientScopes :: IO ()
clientScopes = withFixture $ \fixture -> for_ [False, True] $ \cancelled ->
  withScript fixture running $ \stub script -> do
    saved <- newIORef Nothing
    never <- newEmptyMVar @()
    let scope body = withClient stub (Null, Pipe, Pipe) [] $ \client -> do
          pipeEnds client >>= writeIORef saved . Just . (client,)
          body
    outcome <-
      if cancelled
        then withAsync (scope (takeMVar never)) $ \worker -> script.announced >> cancel worker >> waitCatch worker
        else try @SomeException (scope (script.announced >> throwIO Boom))
    cancelledBy outcome @?= if cancelled then "cancelled" else "Boom"
    readIORef saved >>= maybe (assertFailure "client never started") (\(client, ends) -> do
      pollDaemon client.process >>= (@?= Just (ExitFailure (-15)))
      assertClosed ends)
    script.ended
    retainedBy stub >>= (@?= []) . map (.label)

-- | Cancelling command ends the running client, within the bound even when the client ignores
-- SIGTERM. A wait that SIGKILL never ends would run until the client exits on its own.
commandCancellation :: IO ()
commandCancellation = withFixture $ \fixture -> for_ [running, ignoringTerm] $ \body ->
  withScript fixture body $ \stub script ->
    withAsync (command (retiringBy killing stub) []) $ \worker -> do
      script.announced
      timeout 1000000 (cancel worker >> waitCatch worker) >>= (@?= Just "cancelled") . fmap cancelledBy
      script.ended
      retainedBy stub >>= (@?= []) . map (.label)

-- | The fixture with its owner's retirement replaced. Its clients are retired the same way.
retiringBy :: Retirement -> Fixture -> Fixture
retiringBy how fixture = let owner = fixture.daemon in fixture {daemon = owner {how = how}}

-- | Real delivery with a short step that returns only once a SIGKILLed child can be collected,
-- so the step never races that death; only a signal the child ignores lets a step expire.
killing :: Retirement
killing = retirement {step = 20000, deliver = \fd number -> do
  rc <- retirement.deliver fd number
  when (number == 9 && rc == 0) (threadWaitRead fd)
  pure rc}

-- | The client's retirement is the daemon's: SIGKILL follows an ignored SIGTERM, and a client
-- that survives both stays owned, with its fixture's directory, while the body's cause is kept.
clientEscalation :: IO ()
clientEscalation = withFixture $ \fixture -> do
  sent <- newIORef []
  let logging swallow = killing {deliver = \fd number -> do
        modifyIORef' sent (<> [number])
        if number `elem` swallow then pure 0 else killing.deliver fd number}
      endAll = retainedBy fixture >>= traverse_ (\owner -> retireDaemon owner {how = killing})
      cause = "fixture daemon did not exit: client of " <> fixture.directory
  flip finally endAll $ do
    -- SIGTERM is ignored and delivered once; SIGKILL ends the client within the second step.
    withScript fixture ignoringTerm $ \stub script -> do
      saved <- newIORef Nothing
      withClient (retiringBy (logging []) stub) (Null, Pipe, Pipe) [] $ \client ->
        writeIORef saved (Just client) >> script.announced
      readIORef sent >>= (@?= [15, 9])
      readIORef saved >>= maybe (assertFailure "client never started") (\client ->
        pollDaemon client.process >>= (@?= Just (ExitFailure (-9))))
      script.ended
      retainedBy fixture >>= (@?= []) . map (.label)
    -- Both swallowed: the body's exception keeps its class, or a clean body fails with the cause,
    -- and the client stays owned with its fixture's directory until it is ended for real.
    for_ [True, False] $ \failing -> withScript fixture ignoringTerm $ \stub script -> do
      outcome <- try @SomeException $ withClient (retiringBy (logging [15, 9]) stub) (Null, Pipe, Pipe) [] $ \_ ->
        script.announced >> when failing (throwIO Boom)
      describe outcome @?= (if failing then "Boom" else cause)
      retainedBy fixture >>= (@?= ["client of " <> fixture.directory]) . map (.label)
      endAll
      script.ended
      retainedBy fixture >>= (@?= []) . map (.label)

-- | Control clients that fail in each way they can: no acknowledgement, a noisy stderr, a
-- refused detachment. Each raises its own cause and leaves no descriptor open.
controlClientFailures :: IO ()
controlClientFailures = withFixture $ \fixture -> do
  let acknowledge = "printf '%%begin 1 1 0\\n%%end 1 1 0\\n'\n"
      cases =
        [ ("exit 0\n", "owned control client did not acknowledge attachment")
        , (acknowledge <> "printf noise >&2\nread line\nexit 0\n", "owned control client stderr: \"noise\"")
        , (acknowledge <> "read line\nexit 4\n", "owned control client did not exit")
        , (acknowledge <> "read line\n[ \"$line\" = detach-client ]\n", "returned")
        ]
  for_ cases $ \(body, expected) -> withScript fixture body $ \stub _ ->
    try @SomeException (withAttachedClient stub "$0" (pure ())) >>= (@?= expected) . describe

cancelDuringStartup :: Bool -> IO ()
cancelDuringStartup afterCreation = bracket (newIORef Nothing) closeProbe $ \probe -> do
  ready <- newEmptyMVar
  never <- newEmptyMVar @()
  callbackStarted <- newIORef False
  let pause fixture = putMVar ready fixture >> takeMVar never
      checkpoint stage fixture = case stage of
        SocketReady | not afterCreation -> pause fixture
        PaneCreated response | afterCreation -> registerPane probe response >> pause fixture
        _ -> pure ()
  withAsync (withFixtureAt checkpoint (\_ -> writeIORef callbackStarted True)) $ \worker -> do
    race (wait worker) (takeMVar ready) >>= \case
      Left () -> assertFailure "fixture reached the user callback before its startup checkpoint"
      Right fixture -> do
        cancel worker
        waitCatch worker >>= \case
          Left problem -> case fromException problem of
            Just AsyncCancelled -> pure ()
            Nothing -> assertFailure ("unexpected startup failure: " <> show problem)
          Right () -> assertFailure "startup returned without cancellation"
        assertStopped fixture
        readIORef callbackStarted >>= (@?= False)
        readIORef fixture.paneExitObserved >>= (@?= False)
        readIORef probe >>= \case
          Nothing -> assertBool "pane was created without an observation handle" (not afterCreation)
          Just fd -> do
            assertBool "pane was observed before dispatch" afterCreation
            timeout 1000000 (threadWaitRead fd) >>= (@?= Just ())

cancelPendingCreation :: IO ()
cancelPendingCreation = bracket (newIORef Nothing) closeProbe $ \probe -> do
  ready <- newEmptyMVar
  proceed <- newEmptyMVar
  responded <- newIORef False
  callbackStarted <- newIORef False
  let checkpoint stage fixture = case stage of
        SocketReady -> do
          configured <- command fixture ["set-hook", "-g", "after-new-session",
            "wait-for -S fixture-started ; wait-for fixture-held"]
          configured @?= (ExitSuccess, "", "")
          putMVar ready fixture
          takeMVar proceed
        PaneCreated _ -> writeIORef responded True
  withAsync (withFixtureAt checkpoint (\_ -> writeIORef callbackStarted True)) $ \worker ->
    race (wait worker) (takeMVar ready) >>= \case
      Left () -> assertFailure "fixture returned before hook setup"
      Right fixture -> do
        withAsync (command fixture ["wait-for", "fixture-started"]) $ \receipt -> do
          putMVar proceed ()
          timeout 1000000 (waitEither worker receipt) >>= (@?= Just (Right (ExitSuccess, "", "")))
        (code, pane, errors) <- command fixture ["list-panes", "-a", "-F", "#{pane_pid}"]
        (code, errors) @?= (ExitSuccess, "")
        registerPane probe pane
        readIORef responded >>= (@?= False)
        readIORef callbackStarted >>= (@?= False)
        cancel worker
        waitCatch worker >>= \case
          Left problem -> case fromException problem of
            Just AsyncCancelled -> pure ()
            Nothing -> assertFailure ("unexpected pending-creation failure: " <> show problem)
          Right () -> assertFailure "creation completed without cancellation"
        assertStopped fixture
        readIORef fixture.paneExitObserved >>= (@?= False)
        readIORef responded >>= (@?= False)
        readIORef callbackStarted >>= (@?= False)
        readIORef probe >>= \case
          Nothing -> assertFailure "pending creation had no observed pane"
          Just fd -> timeout 1000000 (threadWaitRead fd) >>= (@?= Just ())

closeProbe :: IORef (Maybe Fd) -> IO ()
closeProbe probe = readIORef probe >>= maybe (pure ()) (closeFdWith closeFd)

assertReleased :: Fixture -> IO ()
assertReleased fixture = do
  assertStopped fixture
  readIORef fixture.paneExitObserved >>= assertBool "initial pane exit was not observed"

assertStopped :: Fixture -> IO ()
assertStopped fixture = do
  pollDaemon fixture.daemon >>= \case
    Nothing -> assertFailure "owned daemon remains alive"
    Just _ -> pure ()
  present <- doesDirectoryExist fixture.directory
  assertBool "owned directory remains" (not present)
