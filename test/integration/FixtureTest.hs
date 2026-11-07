module FixtureTest (tests) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async (AsyncCancelled (..), cancel, race, wait, waitCatch, withAsync)
import Control.Exception (IOException, fromException, throwIO, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import Fixture
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
  ]

assertReleased :: Fixture -> IO ()
assertReleased fixture = do
  getExitCode fixture.daemon >>= \case
    Nothing -> assertFailure "owned daemon remains alive"
    Just _ -> pure ()
  present <- doesDirectoryExist fixture.directory
  assertBool "owned directory remains" (not present)
  readIORef fixture.paneExitObserved >>= assertBool "initial pane exit was not observed"
