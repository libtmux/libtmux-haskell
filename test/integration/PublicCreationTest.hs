module PublicCreationTest (tests) where

import Control.Concurrent.Async (asyncThreadId, wait, withAsync)
import Control.Exception
import Control.Monad (forM_, void)
import Data.List.NonEmpty (NonEmpty (..))
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Text qualified as Text
import Data.Text (Text)
import Fixture qualified
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import System.Exit (ExitCode (..))
import System.OsString.Posix qualified as Os
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "public session creation"
  [ testCase "created refs target native objects and remain detached after closure" $
      Fixture.withFixture $ \fixture -> do
        (closed, created, before, after) <- Tmux.withServer (config fixture) $ \server -> do
          before <- Tmux.capture server
          created <- Tmux.createSession server (options "created-workspace")
          withCreated fixture created $ do
            Tmux.renameWindow server created.window "api #{pid};"
            Tmux.setPaneTitle server created.pane "created-ready"
            after <- Tmux.capture server
            pure (server, created, before, after)
        length (Tmux.sessions before) @?= 1
        length (Tmux.sessions after) @?= 2
        session <- require (Tmux.lookupSession after created.session)
        window <- require (Tmux.lookupWindow after created.window)
        pane <- require (Tmux.lookupPane after created.pane)
        session.name @?= "created-workspace"
        Tmux.labelBytes window.name @?= "api #{pid};"
        pane.title @?= "created-ready"
        pane.window @?= created.window
        links <- require (Tmux.linksForSession after created.session)
        [(link.index, link.window) | link <- links] @?= [(created.windowIndex, created.window)]
        created.serverPid @?= (Tmux.serverInfo after).pid
        Tmux.tryTmux (Tmux.createSession closed (options "closed")) >>= \case
          Left (ExceptionWithContext _ Tmux.ServerClosed) -> pure ()
          _ -> assertFailure "closed Server accepted creation"

  , testCase "default and explicit shell modes retain native process selection" $
      Fixture.withFixture $ \fixture -> do
        configured fixture ["set-option", "-g", "default-command", "exec /bin/cat -u"]
        Tmux.withServer (config fixture) $ \server ->
          forM_ [("default-process", Creation.DefaultProcess, True),
                 ("shell-process", Creation.ShellCommand "exec /bin/cat -", False)] $ \(name, mode, inherited) -> do
            created <- Tmux.createSession server (options name) {Creation.process = mode}
            withCreated fixture created $ do
              let pane = Text.unpack (Tmux.renderPaneId (Tmux.paneId created.pane))
              (code, command, errors) <- Fixture.command fixture ["display-message", "-p", "-t", pane, "-F", "#{pane_start_command}"]
              (code, errors) @?= (ExitSuccess, "")
              ("cat -u" `Bytes.isInfixOf` Lazy.toStrict command) @?= inherited

  , testCase "duplicate rejection and failed hooks retain their distinct outcomes" $
      Fixture.withFixture $ \fixture -> Tmux.withServer (config fixture) $ \server -> do
        first <- Tmux.createSession server (options "duplicate-public")
        withCreated fixture first $ Tmux.tryTmux (Tmux.createSession server (options "duplicate-public")) >>= \case
          Left (ExceptionWithContext context (Tmux.MutationRejected _)) -> do
            recovery <- one (Tmux.creationRecoveries context)
            Tmux.creationReceipt recovery >>= (@?= Nothing)
            Tmux.awaitCreationRecovery recovery >>= \status -> status.logical.retained @?= False
          _ -> assertFailure "duplicate session was not rejected"
        withHook fixture "has-session -t =missing-public-created" $
          Tmux.tryTmux (Tmux.createSession server (options "hook-public")) >>= \case
            Left (ExceptionWithContext context (Tmux.MutationAppliedWithErrors _)) -> do
              recovery <- one (Tmux.creationRecoveries context)
              created <- Tmux.creationReceipt recovery >>= maybe (fail "hook error lost creation IDs") pure
              withCreated fixture created $ do
                snapshot <- Tmux.capture server
                _ <- require (Tmux.lookupSession snapshot created.session)
                Tmux.creationGeneration recovery @?= Tmux.serverGeneration server
                Tmux.awaitCreationRecovery recovery >>= \status -> status.logical.retained @?= False
            _ -> assertFailure "hook failure lost the applied creation outcome"

  , testCase "deletion after creation leaves a historical receipt, not an observation" $
      Fixture.withFixture $ \fixture -> Tmux.withServer (config fixture) $ \server ->
        withHook fixture "wait-for -S delete-entered ; wait-for delete-release ; kill-session -t =deleted-public" $
          flip finally (configured fixture ["wait-for", "-S", "delete-release"]) $
            withAsync (configured fixture ["wait-for", "delete-entered"]) $ \entered ->
              withAsync (Tmux.createSession server (options "deleted-public")) $ \worker -> do
                bounded (wait entered)
                withNamedPane fixture "deleted-public" $ do
                  configured fixture ["wait-for", "-S", "delete-release"]
                  created <- bounded (wait worker)
                  snapshot <- Tmux.capture server
                  case Tmux.lookupSession snapshot created.session of
                    Left (Tmux.MissingSession _) -> pure ()
                    _ -> assertFailure "destructive hook did not remove the created session"

  , testCase "timeout retains created IDs and explicit recovery permits another creation" $
      Fixture.withFixture $ \fixture -> Tmux.withRuntime $ \runtime ->
        Tmux.withServerIn runtime (config fixture) $ \server ->
          withHook fixture "wait-for public-creation-release" $
            flip finally (configured fixture ["wait-for", "-S", "public-creation-release"]) $ do
              Tmux.tryTmux (Tmux.createSessionWith (Tmux.MutationOptions 0.25) server (options "expired-public")) >>= \case
                Left (ExceptionWithContext context Tmux.MutationTimedOut) -> do
                  recovery <- one (Tmux.creationRecoveries context)
                  created <- Tmux.creationReceipt recovery >>= maybe (fail "timeout lost observed creation IDs") pure
                  withCreated fixture created $ do
                    snapshot <- Tmux.capture server
                    _ <- require (Tmux.lookupSession snapshot created.session)
                    status <- bounded (Tmux.awaitCreationRecovery recovery)
                    status.logical.outcome @?= Just Tmux.OutcomeUnknown
                    status.logical.retained @?= True
                    Tmux.detachCreationRecovery recovery >>= (@?= True)
                _ -> assertFailure "waiting creation did not time out"
              configured fixture ["wait-for", "-S", "public-creation-release"]
              configured fixture ["set-hook", "-gu", "after-new-session"]
              next <- Tmux.createSession server (options "after-public-recovery")
              withCreated fixture next (pure ())

  , testCase "cancellation keeps its class and the exact creation owner" $
      Fixture.withFixture $ \fixture -> Tmux.withRuntime $ \runtime ->
        Tmux.withServerIn runtime (config fixture) $ \server ->
          withHook fixture "wait-for -S public-creation-entered ; wait-for public-creation-release" $
            flip finally (configured fixture ["wait-for", "-S", "public-creation-release"]) $
              withAsync (configured fixture ["wait-for", "public-creation-entered"]) $ \entered ->
                withAsync (tryWithContext @SomeException (Tmux.createSession server (options "cancelled-public"))) $ \worker -> do
                  bounded (wait entered)
                  withNamedPane fixture "cancelled-public" $ do
                    throwTo (asyncThreadId worker) ThreadKilled
                    bounded (wait worker) >>= \case
                      Left (ExceptionWithContext context problem) -> do
                        fromException @AsyncException problem @?= Just ThreadKilled
                        recovery <- one (Tmux.creationRecoveries context)
                        Tmux.creationGeneration recovery @?= Tmux.serverGeneration server
                        status <- bounded (Tmux.awaitCreationRecovery recovery)
                        status.logical.outcome @?= Just Tmux.OutcomeUnknown
                        status.logical.retained @?= True
                        Tmux.detachCreationRecovery recovery >>= (@?= True)
                      Right _ -> assertFailure "cancelled creation returned success"

  , testCase "invalid creation options fail before changing the graph" $
      Fixture.withFixture $ \fixture -> Tmux.withServer (config fixture) $ \server -> do
        before <- Tmux.capture server
        Tmux.tryTmux (Tmux.createSession server (options "bad") {Creation.name = Just "bad\NULname"}) >>= \case
          Left (ExceptionWithContext _ (Tmux.InvalidMutationArgument _)) -> pure ()
          _ -> assertFailure "invalid creation options were dispatched"
        after <- Tmux.capture server
        map (.ref) (Tmux.sessions after) @?= map (.ref) (Tmux.sessions before)
  ]

options :: Text -> Tmux.SessionOptions
options name = Creation.defaultSessionOptions {Creation.name = Just name, Creation.process = Creation.DirectCommand (Os.fromBytestring "/bin/cat") (Os.fromBytestring "-" :| [])}

withCreated :: Fixture.Fixture -> Tmux.CreatedSession -> IO a -> IO a
withCreated fixture created = trackPane fixture
  (Text.unpack (Tmux.renderPaneId (Tmux.paneId created.pane)))
  (Text.unpack (Tmux.renderSessionId (Tmux.sessionId created.session)))

withNamedPane :: Fixture.Fixture -> String -> IO a -> IO a
withNamedPane fixture name = trackPane fixture ("=" <> name <> ":") ("=" <> name)

trackPane :: Fixture.Fixture -> String -> String -> IO a -> IO a
trackPane fixture pane session action = do
  (code, pid, errors) <- Fixture.command fixture ["display-message", "-p", "-t", pane, "-F", "#{pane_pid}"]
  (code, errors) @?= (ExitSuccess, "")
  Fixture.withTrackedPane pid (void (Fixture.command fixture ["kill-session", "-t", session])) action

config :: Fixture.Fixture -> Tmux.ServerConfig
config fixture = (Tmux.serverConfig (Os.fromBytestring (Bytes.pack fixture.socket)))
  {Tmux.executable = Os.fromBytestring (Bytes.pack fixture.executable)}

withHook :: Fixture.Fixture -> String -> IO a -> IO a
withHook fixture hook = bracket_
  (configured fixture ["set-hook", "-g", "after-new-session", hook])
  (configured fixture ["set-hook", "-gu", "after-new-session"])

configured :: Fixture.Fixture -> [String] -> Assertion
configured fixture arguments = do
  (code, output, errors) <- Fixture.command fixture arguments
  (code, output, errors) @?= (ExitSuccess, "", "")

bounded :: IO a -> IO a
bounded action = timeout 1000000 action >>= maybe (fail "public creation event did not arrive") pure

one :: [a] -> IO a
one [value] = pure value
one _ = fail "expected one creation recovery owner"

require :: Show problem => Either problem a -> IO a
require = either (fail . show) pure
