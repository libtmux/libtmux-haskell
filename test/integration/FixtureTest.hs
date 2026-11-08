module FixtureTest (tests) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async (AsyncCancelled (..), cancel, race, wait, waitCatch, waitEither, withAsync)
import Control.Exception (bracket, IOException, fromException, throwIO, try)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Fixture
import GHC.Conc (closeFdWith, threadWaitRead)
import System.Posix.IO (closeFd)
import System.Posix.Types (Fd)
import System.Timeout (timeout)
import System.Directory (doesDirectoryExist)
import System.Exit (ExitCode (..))
import System.IO.Error (ioeGetErrorString)
import System.Process.Typed (getExitCode)
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
  ]

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
  getExitCode fixture.daemon >>= \case
    Nothing -> assertFailure "owned daemon remains alive"
    Just _ -> pure ()
  present <- doesDirectoryExist fixture.directory
  assertBool "owned directory remains" (not present)
