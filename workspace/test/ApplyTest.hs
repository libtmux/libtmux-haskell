module ApplyTest (tests) where

import Control.Concurrent.Async (asyncThreadId, wait, withAsync)
import Control.Exception
import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as Bytes
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import LibTmux.Recovery qualified as Recovery
import LibTmux.Workspace qualified as Workspace
import System.Directory (getTemporaryDirectory, removeFile)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (..))
import System.IO (hClose, openBinaryTempFile)
import System.OsString.Posix qualified as Os
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "workspace effects"
  [ testCase "apply window indexes, layout, paths and environment" $
      withServer $ \server native -> do
        native ["set-option", "-g", "default-shell", "/bin/sh"]
        plan <- require (Workspace.planTmuxp inputs sample)
        before <- Tmux.capture server
        length (Tmux.sessions before) @?= 0
        session <- Workspace.applyWorkspace server plan
        graph <- Tmux.capture server
        length (Tmux.clients graph) @?= 0
        actual <- require (Tmux.lookupSession graph session)
        actual.name @?= "workspace-test"
        links <- require (Tmux.linksForSession graph session)
        map (Tmux.windowIndexValue . (.index)) links @?= [0, 2]
        editor <- one [link | link <- links, Tmux.windowIndexValue link.index == 2]
        assertBool "the explicitly focused slot is active" editor.active
        window <- require (Tmux.lookupWindow graph editor.window)
        Tmux.labelText window.name @?= Right "editor"
        panes <- require (Tmux.panesForWindow graph editor.window)
        length panes @?= 2
        map (.height) panes @?= [window.height, window.height]
        sum (map (Tmux.dimensionValue . (.width)) panes) + 1 @?= Tmux.dimensionValue window.width
        case panes of
          [first, second] -> do
            assertBool "explicit pane focus was applied" first.active
            (path first.currentPath, path second.currentPath) @?= ("/tmp", "/")
            observed server first.ref "effect:session:window:/tmp"
            bracket createOutputFile removeFile $ \output -> do
              let redirect = " >" <> shellArgument (Text.pack output) <> "; printf 'probe:%s\\n' complete"
              Tmux.sendKeys server second.ref (Tmux.LiteralText redirect)
              Tmux.sendKeys server second.ref (Tmux.NamedKeys ("Enter" :| []))
              observed server second.ref "probe:complete"
              Bytes.readFile output >>= (@?= "effect:session:pane:/\n")
          _ -> assertFailure "expected exactly two pane identities"
        Tmux.getEnvironment server (Tmux.SessionEnvironment session) "SESSION_FLAG" >>= \case
          Just (Tmux.EnvironmentValue Tmux.Visible value) -> value @?= "session"
          _ -> assertFailure "the new session lacked its explicit environment"
        Tmux.killSession server session
  , testCase "echo alone cannot authorize pane commands" $
      withServer $ \server native -> do
        native ["set-option", "-g", "default-shell", "/bin/sh"]
        native ["set-option", "-g", "default-command", "exec /bin/cat -u"]
        survivor <- Tmux.createSession server Creation.defaultSessionOptions {Creation.name = Just "survivor"}
        plan <- require (Workspace.planTmuxp inputs
          "session_name: no-shell\nwindows: [{panes: [{shell_command: user-configured-input}]}]\n")
        tryWithContext @SomeException (Workspace.applyWorkspace server plan) >>= \case
          Left (ExceptionWithContext context problem) -> do
            rejected <- case fromException @Workspace.WorkspaceApplyError problem of
              Just (Workspace.ShellAcknowledgementTimedOut rejected) -> pure rejected
              _ -> fail (show problem)
            owner <- one (Workspace.workspaceRecoveries context)
            session <- Workspace.workspaceRecoverySession owner >>= maybe (fail "missing new session") pure
            graph <- Tmux.capture server
            length (Tmux.clients graph) @?= 0
            link <- require (Tmux.linksForSession graph session) >>= one
            pane <- require (Tmux.panesForWindow graph link.window) >>= one
            pane.ref @?= rejected
            screen <- Tmux.paneText <$> Tmux.capturePane server pane.ref Tmux.defaultPaneCapture
            assertBool "the pane received workspace commands before acknowledging the shell"
              (not ("user-configured-input" `Text.isInfixOf` screen))
            Tmux.killSession server session
            fresh <- Tmux.capture server
            map (.ref) (Tmux.sessions fresh) @?= [survivor.session]
          Right _ -> assertFailure "apply accepted a pane that only echoes its input"
  , testCase "cancel after the pane consumes the readiness probe" $
      withServer $ \server native -> do
        native ["set-option", "-g", "default-shell", "/bin/sh"]
        executable <- tmuxExecutable
        initial <- Tmux.capture server
        let socket = path (Tmux.serverInfo initial).socketPath
            notify = Text.unwords [shellArgument (Text.pack executable), "-N", "-S", shellArgument (Text.pack socket),
              "wait-for -S workspace-probed"]
            shell = "IFS= read -r probe; " <> notify <> "; exec /bin/cat -u"
        native ["set-option", "-g", "default-command", Text.unpack shell]
        survivor <- Tmux.createSession server Creation.defaultSessionOptions {Creation.name = Just "survivor"}
        plan <- require (Workspace.planTmuxp inputs
          "session_name: interrupted\nwindows: [{panes: [{shell_command: user-configured-input}]}]\n")
        withAsync (native ["wait-for", "workspace-probed"]) $ \entered ->
          withAsync (tryWithContext @SomeException (Workspace.applyWorkspace server plan)) $ \worker -> do
            bounded (wait entered)
            active <- Tmux.capture server
            length (Tmux.clients active) @?= 1
            partial <- one [session | session <- Tmux.sessions active, session.name == "interrupted"]
            throwTo (asyncThreadId worker) ThreadKilled
            bounded (wait worker) >>= \case
              Left (ExceptionWithContext context problem) -> do
                fromException @AsyncException problem @?= Just ThreadKilled
                owner <- one (Workspace.workspaceRecoveries context)
                Workspace.workspaceRecoverySession owner >>= (@?= Just partial.ref)
                forM_ (Recovery.controlRecoveries context) $ \recovery ->
                  Recovery.resumeControlCleanup recovery >>= assertBool "retire the retained control observer"
                fresh <- Tmux.capture server
                length (Tmux.clients fresh) @?= 0
                Tmux.killSession server partial.ref
                after <- Tmux.capture server
                map (.ref) (Tmux.sessions after) @?= [survivor.session]
              Right _ -> assertFailure "apply returned after the readiness wait was cancelled"
  , testCase "planning and path refusals preserve an existing session" $
      withServer $ \server _ -> do
        survivor <- Tmux.createSession server Creation.defaultSessionOptions {Creation.name = Just "survivor"}
        let wrong = "session_name: invalid\nbefore_script: no\nwindows: [{}]\n"
        case Workspace.planTmuxp inputs wrong of
          Left (Workspace.UnsupportedField "before_script") -> pure ()
          _ -> assertFailure "unsupported shell script was accepted"
        planned <- require (Workspace.planTmuxp inputs
          "session_name: invalid\nstart_directory: /dev/null/impossible\nwindows: [{}]\n")
        tryWithContext @SomeException (Workspace.applyWorkspace server planned) >>= \case
          Left (ExceptionWithContext context problem) -> do
            case fromException @Workspace.WorkspaceApplyError problem of
              Just (Workspace.DirectoryUnavailable "/dev/null/impossible") -> pure ()
              _ -> assertFailure (show problem)
            assertBool "preflight retained no mutation owner" (null (Workspace.workspaceRecoveries context))
          Right _ -> assertFailure "invalid directory created a session"
        graph <- Tmux.capture server
        map (.ref) (Tmux.sessions graph) @?= [survivor.session]
        actual <- require (Tmux.lookupPane graph survivor.pane)
        actual.window @?= survivor.window
  , testCase "cancellation preserves an owner during session birth and later window construction" $
      forM_ [("after-new-session", True), ("after-new-window", False)] $ \(hook, initial) ->
        withServer $ \server native -> do
          survivor <- Tmux.createSession server Creation.defaultSessionOptions {Creation.name = Just "survivor"}
          plan <- require (Workspace.planTmuxp inputs "session_name: interrupted\nwindows: [{}]\n")
          let gate = "wait-for -S workspace-entered ; wait-for workspace-release"
          bracket_ (native ["set-hook", "-g", hook, gate]) (native ["set-hook", "-gu", hook]) $
            flip finally (native ["wait-for", "-S", "workspace-release"]) $
              withAsync (native ["wait-for", "workspace-entered"]) $ \entered ->
                withAsync (tryWithContext @SomeException (Workspace.applyWorkspace server plan)) $ \worker -> do
                  bounded (wait entered)
                  graph <- Tmux.capture server
                  partial <- one [session | session <- Tmux.sessions graph, session.name == "interrupted"]
                  throwTo (asyncThreadId worker) ThreadKilled
                  bounded (wait worker) >>= \case
                    Left (ExceptionWithContext context problem) -> do
                      fromException @AsyncException problem @?= Just ThreadKilled
                      owner <- one (Workspace.workspaceRecoveries context)
                      Workspace.workspaceRecoverySession owner >>= (@?= Just partial.ref)
                      fmap (const True) (Workspace.pendingWorkspaceCreation owner) @?=
                        (if initial then Just True else Nothing)
                      forM_ (Recovery.creationRecoveries context) $ \recovery -> do
                        void (bounded (Recovery.awaitCreationRecovery recovery))
                        void (Recovery.detachCreationRecovery recovery)
                      forM_ (Recovery.mutationRecoveries context) $ \recovery -> do
                        void (bounded (Recovery.awaitMutationRecovery recovery))
                        void (Recovery.detachMutationRecovery recovery)
                      Tmux.killSession server partial.ref
                      fresh <- Tmux.capture server
                      map (.ref) (Tmux.sessions fresh) @?= [survivor.session]
                      void (require (Tmux.lookupPane fresh survivor.pane))
                    Right _ -> assertFailure "cancelled workspace returned success"
  ]

sample :: ByteString
sample = Bytes.unlines
  [ "session_name: workspace-test"
  , "start_directory: /tmp"
  , "environment: {SESSION_FLAG: session}"
  , "windows:"
  , "  - window_name: editor"
  , "    window_index: 2"
  , "    layout: even-horizontal"
  , "    focus: true"
  , "    environment: {PANE_FLAG: window}"
  , "    panes:"
  , "      - focus: true"
  , "        shell_command: >-"
  , "          printf 'effect:%s:%s:%s\\n' \"$SESSION_FLAG\" \"$PANE_FLAG\" \"$(pwd)\""
  , "      - start_directory: /"
  , "        environment: {PANE_FLAG: pane}"
  , "        enter: false"
  , "        shell_command: >-"
  , "          printf 'effect:%s:%s:%s\\n' \"$SESSION_FLAG\" \"$PANE_FLAG\" \"$(pwd)\""
  , "  - window_name: spare"
  , "    window_index: 0"
  ]

inputs :: Workspace.PlanInputs
inputs = Workspace.defaultPlanInputs "/tmp"

observed :: Tmux.Server -> Tmux.PaneRef -> Text -> Assertion
observed server pane expected = Tmux.waitForText server pane Tmux.defaultPaneWait expected >>= \case
  Tmux.PaneTextMatched _ -> pure ()
  Tmux.PaneTextTimedOut latest _ -> missing "timed out" latest
  Tmux.PaneTextExited latest -> missing "pane exited" latest
  where
    missing reason latest = assertFailure
      (reason <> " while looking for " <> show expected <> " in " <> show (Tmux.paneText <$> latest))

type Native = [String] -> IO ()

tmuxExecutable :: IO FilePath
tmuxExecutable = maybe "tmux" id <$> lookupEnv "LIBTMUX_TEST_TMUX"

withServer :: (Tmux.Server -> Native -> IO value) -> IO value
withServer run = do
  executable <- tmuxExecutable
  let config = Tmux.defaultOwnedServerConfig {Tmux.tmuxExecutable = Os.fromBytestring (Bytes.pack executable)}
  Tmux.withOwnedServer config $ \server -> do
    graph <- Tmux.capture server
    inherited <- filter (\(key, _) -> key /= "TMUX" && key /= "TMUX_PANE") <$> getEnvironment
    let socket = path (Tmux.serverInfo graph).socketPath
        native arguments = do
          let command = (proc executable ("-N" : "-S" : socket : arguments)) {env = Just inherited}
          readCreateProcessWithExitCode command "" >>= (@?= (ExitSuccess, "", ""))
    run server native

createOutputFile :: IO FilePath
createOutputFile = do
  directory <- getTemporaryDirectory
  (file, outputHandle) <- openBinaryTempFile directory "libtmux-workspace-output-"
  hClose outputHandle
  pure file

shellArgument :: Text -> Text
shellArgument argument = "'" <> Text.replace "'" "'\\''" argument <> "'"

path :: Os.PosixString -> FilePath
path = map Os.toChar . Os.unpack

one :: [value] -> IO value
one [value] = pure value
one _ = fail "expected one value"

require :: Show problem => Either problem value -> IO value
require = either (fail . show) pure

bounded :: IO value -> IO value
bounded action = timeout 1000000 action >>= maybe (fail "workspace event did not arrive") pure
