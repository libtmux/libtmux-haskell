module FixtureTest (tests) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async (AsyncCancelled (..), cancel, race, wait, waitCatch, waitEither, withAsync)
import Control.Exception (Exception, SomeException, bracket, IOException, fromException, throwIO, try)
import Control.Monad (void, when)
import Data.Foldable (for_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Foreign.C.Types (CInt)
import Fixture
import GHC.Conc (closeFdWith, threadWaitRead)
import System.Posix.IO (closeFd)
import System.Posix.Types (Fd)
import System.Timeout (timeout)
import System.Directory (doesDirectoryExist)
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
  ]

-- | A body failure of a class no cleanup raises, so only its preservation can pass the test.
data Boom = Boom deriving (Eq, Show)

instance Exception Boom

-- | Run an action that may block uninterruptibly, as a retirement does and 'timeout' cannot
-- interrupt, and fail the test at the bound. A worker that never returns is abandoned.
boundedly :: IO a -> IO a
boundedly action = do
  done <- newEmptyMVar
  _ <- forkIO (try action >>= putMVar done)
  timeout 2000000 (takeMVar done) >>= \case
    Nothing -> assertFailure "retirement blocked past its bound"
    Just result -> either (throwIO @SomeException) pure result

-- | Signals are logged in delivery order. A swallowed signal reaches the pidfd's owner as
-- success, as it would for a child that ignores it. A delivered signal ends the sleeping child,
-- and the stub sees that before it returns, so the short step below never races the child's exit:
-- only a swallowed signal lets a step expire.
retireBounds :: IO ()
retireBounds = do
  sent <- newIORef []
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
      sleeper retiring = withDaemon retiring "sleeper" "/bin/sleep" ["30"] []
      describe :: Either SomeException () -> String
      describe = \case
        Right () -> "returned"
        Left problem -> case (fromException problem, fromException problem) of
          (Just Boom, _) -> "Boom"
          (_, Just io) -> ioeGetErrorString io
          _ -> show problem
  -- Already collected: nothing is signaled.
  boundedly (observe (withDaemon (logged []) "exited" "/bin/true" [] [] awaitDaemon)) >>= (@?= (ExitSuccess, []))
  -- A live child gets SIGTERM only.
  boundedly (observe (sleeper (logged []) (\_ -> pure ()))) >>= (@?= ((), [15]))
  -- SIGTERM swallowed: SIGKILL ends it within the second step.
  boundedly (observe (sleeper (logged [15]) pure >>= pollDaemon)) >>= (@?= (Just (ExitFailure (-9)), [15, 9]))
  -- Both swallowed: bounded, the body's exception keeps its class, and the owner is kept.
  let stuck = logged [15, 9]
  try @SomeException (boundedly (sleeper stuck (\_ -> throwIO Boom))) >>= (@?= "Boom") . describe
  try @SomeException (boundedly (sleeper stuck (\_ -> pure ()))) >>= (@?= "fixture daemon did not exit: sleeper") . describe
  -- A refused delivery is raised with its cause instead of waiting out the bound; the child stays owned.
  refused <- try @IOException (boundedly (sleeper quick {deliver = \_ _ -> pure 1} (\_ -> pure ())))
  either (\problem -> (isPermissionError problem, ioeGetLocation problem)) (const (False, "returned")) refused
    @?= (True, "fixture daemon signal")
  owners <- retainedDaemons
  map (.label) owners @?= ["sleeper", "sleeper", "sleeper"]
  -- End them for real through the retained pidfds, with the default bounds.
  for_ owners $ \owner -> retireDaemon owner {how = retirement}
  retainedDaemons >>= (@?= []) . map (.label)

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
