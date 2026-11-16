module FixtureTest (tests) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
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

-- | Signals are logged in delivery order. A swallowed signal reaches the pidfd's owner as
-- success, as it would for a child that ignores it.
retireBounds :: IO ()
retireBounds = do
  sent <- newIORef []
  let quick = retirement {step = 50000}
      logged :: [CInt] -> Retirement
      logged swallow = quick {deliver = \fd number -> do
        modifyIORef' sent (<> [number])
        if number `elem` swallow then pure 0 else quick.deliver fd number}
      signalsOf :: IO a -> IO [CInt]
      signalsOf action = writeIORef sent [] >> action >> readIORef sent
      sleeper retiring = withDaemon retiring "sleeper" "/bin/sleep" ["30"] []
  -- Already collected: nothing is signaled.
  signalsOf (withDaemon (logged []) "exited" "/bin/true" [] [] awaitDaemon) >>= (@?= [])
  -- A live child gets SIGTERM only.
  signalsOf (sleeper (logged []) (\_ -> pure ())) >>= (@?= [15])
  -- SIGTERM swallowed: SIGKILL ends it within the second step.
  signalsOf (sleeper (logged [15]) pure >>= \daemon -> pollDaemon daemon >>= (@?= Just (ExitFailure (-9))))
    >>= (@?= [15, 9])
  -- Both swallowed: bounded, the body's exception keeps its class, and the owner is kept.
  let stuck = logged [15, 9]
  failing <- timeout 2000000 (try @IOException (sleeper stuck (\_ -> throwIO (userError "body failed"))))
  fmap (either ioeGetErrorString (const "returned")) failing @?= Just "body failed"
  clean <- timeout 2000000 (try @IOException (sleeper stuck (\_ -> pure ())))
  fmap (either ioeGetErrorString (const "returned")) clean @?= Just "fixture daemon did not exit: sleeper"
  -- A refused delivery is raised with its cause instead of waiting out the bound; the child stays owned.
  refused <- try @IOException (sleeper quick {deliver = \_ _ -> pure 1} (\_ -> pure ()))
  either (\problem -> (isPermissionError problem, ioeGetLocation problem)) (const (False, "returned")) refused
    @?= (True, "fixture daemon signal")
  owners <- retainedDaemons
  map (.label) owners @?= ["sleeper", "sleeper", "sleeper"]
  -- End them for real through the retained pidfds.
  for_ owners $ \owner -> retireDaemon owner {how = quick}
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
