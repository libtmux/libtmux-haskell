module PublicMutationTest (tests) where

import Control.Concurrent.Async (asyncThreadId, wait, withAsync)
import Control.Exception
  ( AsyncException (..), ExceptionWithContext (..), SomeException, finally
  , fromException, throwTo, tryWithContext
  )
import Control.Monad (forM_)
import Data.ByteString.Char8 qualified as Bytes
import Fixture qualified
import LibTmux qualified as Tmux
import LibTmux.Snapshot.Fixture qualified as F
import System.Exit (ExitCode (..))
import System.OsString.Posix qualified as Os
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "public mutation API"
  [ testCase "renames physical entities and keeps the old snapshot detached" $
      Fixture.withFixture $ \fixture -> do
        configured fixture ["rename-window", "-t", "@0", "original-window"]
        configured fixture ["select-pane", "-t", "%0", "-T", "original-title"]
        configured fixture ["link-window", "-s", "@0", "-t", "fixture:3"]
        Tmux.withServer (config fixture) $ \server -> do
          before <- Tmux.capture server
          session <- one (Tmux.sessions before)
          window <- one (Tmux.windows before)
          pane <- one (Tmux.panes before)
          Tmux.renameSession server session.ref "renamed-#{pid};"
          Tmux.renameWindow server window.ref "api #{pid};"
          Tmux.setPaneTitle server pane.ref "editor #{pid};"
          after <- Tmux.capture server
          newerSession <- require (Tmux.lookupSession after session.ref)
          newerWindow <- require (Tmux.lookupWindow after window.ref)
          newerPane <- require (Tmux.lookupPane after pane.ref)
          newerSession.name @?= "renamed-#{pid};"
          newerWindow.name @?= "api #{pid};"
          newerPane.title @?= "editor #{pid};"
          length (Tmux.windows after) @?= 1
          length (Tmux.windowLinks after) @?= 2
          forM_ (Tmux.windowLinks after) $ \link -> do
            observed <- require (Tmux.lookupWindow after link.window)
            observed.name @?= "api #{pid};"
          oldSession <- require (Tmux.lookupSession before session.ref)
          oldWindow <- require (Tmux.lookupWindow before window.ref)
          oldPane <- require (Tmux.lookupPane before pane.ref)
          oldSession.name @?= "fixture"
          oldWindow.name @?= "original-window"
          oldPane.title @?= "original-title"

  , testCase "refuses foreign and offline references before changing the daemon" $
      Fixture.withFixture $ \fixture -> do
        configured fixture ["rename-window", "-t", "@0", "original-window"]
        Tmux.withRuntime $ \runtime -> Tmux.withServerIn runtime (config fixture) $ \first -> do
          snapshot <- Tmux.capture first
          window <- one (Tmux.windows snapshot)
          Tmux.withServerIn runtime (config fixture) $ \other -> do
            rejected <- Tmux.tryTmux (Tmux.renameWindow other window.ref "foreign-write")
            expectInvalidTarget rejected
            let offline = F.windowRef (F.fixtureOrigin "test") (Tmux.windowId window.ref)
            Tmux.tryTmux (Tmux.renameWindow other offline "fixture-write") >>= expectInvalidTarget
          after <- Tmux.capture first
          observed <- require (Tmux.lookupWindow after window.ref)
          observed.name @?= "original-window"

  , testCase "closed handles reject before dispatch" $
      Fixture.withFixture $ \fixture -> do
        configured fixture ["rename-window", "-t", "@0", "original-window"]
        (closed, ref) <- Tmux.withServer (config fixture) $ \server -> do
          snapshot <- Tmux.capture server
          window <- one (Tmux.windows snapshot)
          pure (server, window.ref)
        Tmux.tryTmux (Tmux.renameWindow closed ref "closed-write") >>= \case
          Left (ExceptionWithContext _ Tmux.ServerClosed) -> pure ()
          _ -> assertFailure "closed handle admitted a mutation"

  , testCase "invalid timeouts and NUL operands reject before dispatch" $
      Fixture.withFixture $ \fixture -> do
        configured fixture ["rename-window", "-t", "@0", "original-window"]
        Tmux.withServer (config fixture) $ \server -> do
          snapshot <- Tmux.capture server
          window <- one (Tmux.windows snapshot)
          forM_ [0, -1, 11] $ \duration -> do
            let options = Tmux.defaultMutationOptions {Tmux.timeout = duration}
            Tmux.tryTmux (Tmux.renameWindowWith options server window.ref "invalid-deadline") >>= \case
              Left (ExceptionWithContext _ (Tmux.InvalidConfiguration _)) -> pure ()
              _ -> assertFailure "invalid timeout admitted a mutation"
          Tmux.tryTmux (Tmux.renameWindow server window.ref (Tmux.labelFromBytes "x\NULy")) >>= \case
            Left (ExceptionWithContext _ (Tmux.InvalidMutationArgument _)) -> pure ()
            _ -> assertFailure "invalid operand admitted a mutation"
          after <- Tmux.capture server
          observed <- require (Tmux.lookupWindow after window.ref)
          observed.name @?= "original-window"

  , testCase "reports an applied hook error separately from a missing pane" $
      Fixture.withFixture $ \fixture -> Tmux.withServer (config fixture) $ \server -> do
        snapshot <- Tmux.capture server
        window <- one (Tmux.windows snapshot)
        pane <- one (Tmux.panes snapshot)
        configured fixture ["set-hook", "-g", "after-rename-window", "has-session -t =libtmux-missing"]
        flip finally (configured fixture ["set-hook", "-gu", "after-rename-window"]) $ do
          Tmux.tryTmux (Tmux.renameWindow server window.ref "applied-before-hook-error") >>= \case
            Left (ExceptionWithContext context (Tmux.MutationAppliedWithErrors _)) ->
              case Tmux.mutationRecoveries context of
                [recovery] -> do
                  observed <- Tmux.inspectMutationRecovery recovery
                  observed.logical.outcome @?= Just Tmux.Failed
                  observed.logical.retained @?= False
                  Tmux.operationStatus (Tmux.mutationOperation recovery) >>= (@?= observed.logical)
                _ -> assertFailure "known failure lost its correlated status"
            _ -> assertFailure "applied hook failure lost its outcome"
          after <- Tmux.capture server
          changed <- require (Tmux.lookupWindow after window.ref)
          changed.name @?= "applied-before-hook-error"
        configured fixture ["kill-pane", "-t", "%0"]
        Tmux.tryTmux (Tmux.setPaneTitle server pane.ref "disappeared") >>= \case
          Left (ExceptionWithContext _ (Tmux.MutationRejected _)) -> pure ()
          _ -> assertFailure "disappeared pane did not reject its command"

  , testCase "an explicit deadline bounds an accepted waiting hook" $
      Fixture.withFixture $ \fixture -> Tmux.withServer (config fixture) $ \server -> do
        snapshot <- Tmux.capture server
        window <- one (Tmux.windows snapshot)
        configured fixture ["set-hook", "-g", "after-rename-window",
          "wait-for -S libtmux-deadline-entered ; wait-for libtmux-deadline-release"]
        let release = do
              configured fixture ["wait-for", "-S", "libtmux-deadline-release"]
              configured fixture ["set-hook", "-gu", "after-rename-window"]
            options = Tmux.defaultMutationOptions {Tmux.timeout = 0.2}
        flip finally release $
          withAsync (configured fixture ["wait-for", "libtmux-deadline-entered"]) $ \entered ->
            withAsync (Tmux.tryTmux (Tmux.renameWindowWith options server window.ref "deadline-applied")) $ \worker -> do
              bounded (wait entered)
              timeout 500000 (wait worker) >>= \case
                Just (Left (ExceptionWithContext context Tmux.MutationTimedOut)) ->
                  case Tmux.mutationRecoveries context of
                    [recovery] -> do
                      observed <- bounded (Tmux.awaitMutationRecovery recovery)
                      observed.logical.outcome @?= Just Tmux.OutcomeUnknown
                      observed.logical.retained @?= True
                      release
                      Tmux.detachMutationRecovery recovery >>= (@?= True)
                    _ -> assertFailure "deadline lost its accepted operation"
                _ -> assertFailure "explicit timeout did not bound the call"

  , testCase "accepted cancellation exposes recovery and permits explicit later progress" $
      Fixture.withFixture $ \fixture ->
        Tmux.withRuntime $ \runtime -> Tmux.withServerIn runtime (config fixture) $ \server -> do
          snapshot <- Tmux.capture server
          window <- one (Tmux.windows snapshot)
          configured fixture ["set-hook", "-g", "after-rename-window",
            "wait-for -S libtmux-public-entered ; wait-for libtmux-public-release"]
          let release = do
                configured fixture ["wait-for", "-S", "libtmux-public-release"]
                configured fixture ["set-hook", "-gu", "after-rename-window"]
          flip finally release $
            withAsync (configured fixture ["wait-for", "libtmux-public-entered"]) $ \entered ->
              withAsync (tryWithContext @SomeException (Tmux.renameWindow server window.ref "accepted")) $ \worker -> do
                bounded (wait entered)
                throwTo (asyncThreadId worker) ThreadKilled
                bounded (wait worker) >>= \case
                  Left (ExceptionWithContext context problem) -> do
                    fromException @AsyncException problem @?= Just ThreadKilled
                    case Tmux.mutationRecoveries context of
                      [recovery] -> do
                        Tmux.mutationGeneration recovery @?= Tmux.serverGeneration server
                        observed <- bounded (Tmux.awaitMutationRecovery recovery)
                        observed.workerOwned @?= False
                        observed.nativeOwned @?= False
                        observed.logical.outcome @?= Just Tmux.OutcomeUnknown
                        observed.logical.retained @?= True
                        Tmux.resumeMutationRecovery recovery
                        release
                        Tmux.detachMutationRecovery recovery >>= (@?= True)
                        Tmux.renameWindow server window.ref "after-public-recovery"
                        after <- Tmux.capture server
                        changed <- require (Tmux.lookupWindow after window.ref)
                        changed.name @?= "after-public-recovery"
                      _ -> assertFailure "cancelled public call lost its owner"
                  Right () -> assertFailure "cancelled public mutation returned success"
  ]

config :: Fixture.Fixture -> Tmux.ServerConfig
config fixture = (Tmux.serverConfig (Os.fromBytestring (Bytes.pack fixture.socket)))
  {Tmux.executable = Os.fromBytestring (Bytes.pack fixture.executable)}

configured :: Fixture.Fixture -> [String] -> Assertion
configured fixture arguments = do
  (code, output, errors) <- Fixture.command fixture arguments
  (code, output, errors) @?= (ExitSuccess, "", "")

one :: [a] -> IO a
one [value] = pure value
one _ = fail "owned fixture has an unexpected entity count"

require :: Show problem => Either problem a -> IO a
require = either (fail . show) pure

expectInvalidTarget :: Either (ExceptionWithContext Tmux.TmuxException) () -> Assertion
expectInvalidTarget (Left (ExceptionWithContext _ (Tmux.InvalidTarget _))) = pure ()
expectInvalidTarget _ = assertFailure "foreign target admitted a mutation"

bounded :: IO a -> IO a
bounded action = timeout 1000000 action >>= maybe (fail "public mutation missed its event") pure
