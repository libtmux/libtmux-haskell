module PublicProgramTest (tests) where

import Control.Concurrent.Async (asyncThreadId, wait, withAsync)
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (forM_)
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Maybe (isJust)
import Data.Text qualified as Text
import Fixture qualified
import GHC.Conc (threadWaitRead)
import LibTmux qualified as Tmux
import LibTmux.Capabilities qualified as Cap
import LibTmux.Internal.Process.Native qualified as Native
import LibTmux.Program qualified as Program
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.Directory qualified as Directory
import System.FilePath ((</>))
import System.Posix.Files qualified as File
import System.Posix.IO qualified as Posix
import System.Posix.Types (Fd (..))
import System.OsString.Posix qualified as Os
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

-- The floor daemon executes refusal. Enabled workloads are assembled from an
-- actual daemon probe; they are absent, rather than passing empty, below 3.8.
tests :: IO TestTree
tests = do
  enabled <- withServer $ \_ server ->
    pure (Cap.supports (Tmux.serverCapabilities server) Cap.ManagedPrograms)
  pure (testGroup "public Program API" (discovery : [applications | enabled]))

discovery :: TestTree
discovery = testCase "daemon discovery and refusal precede application effects" $
  Fixture.withFixture $ \fixture -> do
    alternate <- lookupEnv "LIBTMUX_TEST_CLIENT_TMUX"
    forM_ (fixture.executable : maybe [] pure alternate) $ \client ->
      Tmux.withServer ((config fixture) {Tmux.executable = Os.fromBytestring (Bytes.pack client)}) $ \server -> do
        before <- Tmux.capture server
        Cap.daemonVersion (Tmux.serverCapabilities server) @?= (Tmux.serverInfo before).version
        if Cap.supports (Tmux.serverCapabilities server) Cap.ManagedPrograms
          then Tmux.runProgram server (options "/bin/true" []) >>= \result ->
            result.programExit @?= Program.ProgramExited 0
          else try @Cap.CapabilityError (Tmux.runProgram server (options "/bin/true" [])) >>= \case
            Left (Cap.CapabilityUnavailable Cap.ManagedPrograms version) ->
              version @?= (Tmux.serverInfo before).version
            _ -> assertFailure "unsupported daemon admitted an application"
        borrowedOnly server

applications :: TestTree
applications = testGroup "enabled application operations"
  [ testCase "native CString paths terminate before bytes outside a slice" $
      withServer $ \fixture server -> do
        snapshot <- Tmux.capture server
        let sliced value = let bytes = Bytes.pack value in
              Bytes.take (Bytes.length bytes) (bytes <> "/unowned-suffix")
        bracket (Native.daemonWatch (sliced fixture.socket) (Tmux.serverInfo snapshot).pid)
          Native.close (const (pure ()))
        bracket (Native.watchDirectory (sliced fixture.directory)) Native.close (const (pure ()))
  , testCase "literal argv, native bytes, cwd, environment and terminal geometry" $
      withServer $ \fixture server -> do
        let script = "[ -t 0 ] && [ -t 1 ] && [ -t 2 ] || exit 98; printf 'cwd=%s env=%s arg=%s\\n' \"$PWD\" \"$VALUE\" \"$1\"; stty size"
        result <- Tmux.runProgram server (options "/bin/sh" ["-c", script, "literal", "#{pid};"])
          { Program.workingDirectory = Just (Os.fromBytestring (Bytes.pack fixture.directory))
          , Program.environment = [(Os.fromBytestring "VALUE", Os.fromBytestring "#{pid};")]
          , Program.columns = 91, Program.rows = 31 }
        result.programExit @?= Program.ProgramExited 0
        assertBool "cwd/env/argv changed" (Bytes.pack ("cwd=" <> fixture.directory <> " env=#{pid}; arg=#{pid};") `Bytes.isPrefixOf` result.programOutput.screenBytes)
        assertBool "terminal geometry changed" ("31 91" `Bytes.isInfixOf` result.programOutput.screenBytes)
        bytes <- Tmux.runProgram server (Program.programOptions (Os.fromBytestring "/bin/sh")
          [Os.fromBytestring "-c", Os.fromBytestring "printf '%s' \"$1\" | od -An -tx1", Os.fromBytestring "bytes", Os.fromBytestring "\255;#{pid}"])
        assertBool "native argv bytes changed" ("ff 3b 23 7b 70 69 64 7d" `Bytes.isInfixOf` bytes.programOutput.screenBytes)
        descriptors <- Tmux.runProgram server (options "/bin/sh"
          ["-c", "for fd in /proc/$$/fd/*; do [ -p \"$fd\" ] && exit 93; done; exit 0"])
        descriptors.programExit @?= Program.ProgramExited 0
        File.createSymbolicLink "/bin/true" (fixture.directory </> "-literal")
        leading <- Tmux.runProgram server (options "-literal" [])
          {Program.environment = [(Os.fromBytestring "PATH", Os.fromBytestring (Bytes.pack fixture.directory))]}
        leading.programExit @?= Program.ProgramExited 0
        variables <- Tmux.runProgram server (options "/usr/bin/printenv" ["error", "RANDOM"])
          {Program.environment = [(Os.fromBytestring "error", Os.fromBytestring "literal error"),
            (Os.fromBytestring "RANDOM", Os.fromBytestring "literal random")]}
        variables.programExit @?= Program.ProgramExited 0
        assertBool "bootstrap altered an application environment value"
          ("literal error\nliteral random\n" `Bytes.isPrefixOf` variables.programOutput.screenBytes)
        borrowedOnly server
  , testCase "fast exit, zero arguments, normal 137 and a real signal remain distinct" $
      withServer $ \_ server -> do
        forM_ [1 :: Int .. 3] $ \_ -> do
          result <- Tmux.runProgram server (options "/usr/bin/printf" ["%s", "final-output"])
          result.programExit @?= Program.ProgramExited 0
          assertBool "final output was not drained" ("final-output" `Bytes.isPrefixOf` result.programOutput.screenBytes)
        forM_ [(options "/bin/true" [], Program.ProgramExited 0),
               (options "/bin/sh" ["-c", "exit 137"], Program.ProgramExited 137),
               (options "/bin/sh" ["-c", "kill -KILL $$"], Program.ProgramSignalled "9")] $ \(settings, expected) ->
          Tmux.runProgram server settings >>= \result -> case (result.programExit, expected) of
            (Program.ProgramSignalled actual, Program.ProgramSignalled _) ->
              assertBool "KILL status lost its native signal spelling" (actual `elem` ["9", "KILL"])
            _ -> result.programExit @?= expected
        borrowedOnly server
  , testCase "strict cwd and failed exec differ from application exit 127" $
      withServer $ \_ server -> do
        missingCwd <- Tmux.runProgram server (options "/bin/true" [])
          {Program.workingDirectory = Just (Os.fromBytestring "/libtmux-haskell-missing-cwd")}
        case missingCwd.programExit of
          Program.ProgramStartFailed (Program.StartFailure Program.WorkingDirectory _) -> pure ()
          other -> assertFailure ("cwd failure became " <> show other)
        missing <- Tmux.runProgram server (options "/libtmux-haskell-missing-executable" [])
        missing.programExit @?= Program.ProgramStartFailed (Program.StartFailure Program.Executable 127)
        normal <- Tmux.runProgram server (options "/bin/sh" ["-c", "exit 127"])
        normal.programExit @?= Program.ProgramExited 127
        borrowedOnly server
  , testCase "input and cancelled or expired observations leave the owner running" $
      withServer $ \_ server -> do
        Tmux.withProgram server (options "/bin/sh" ["-c", "IFS= read -r line; printf 'ack=%s' \"$line\""]) $ \program -> do
          Program.waitProgramFor 0.001 program >>= (@?= Nothing)
          observing <- newEmptyTMVarIO
          withAsync (try @AsyncException (atomically (putTMVar observing ()) >> Program.waitProgram program)) $ \observer -> do
            atomically (readTMVar observing)
            throwTo (asyncThreadId observer) ThreadKilled
            bounded (wait observer) >>= (@?= Left ThreadKilled)
          Program.sendProgramInput program "#{pid}; literal\n"
          Program.waitProgram program >>= (@?= Program.ProgramExited 0)
          output <- Program.readProgramScreen program
          assertBool "application did not consume literal input" ("ack=#{pid}; literal" `Bytes.isInfixOf` output.screenBytes)
        borrowedOnly server
  , testCase "stale input and cleanup preserve a replacement at dispatch" $
      Fixture.withFixture $ \fixture -> do
        let wrapper = fixture.directory </> "client-wrapper"
            targetFile = fixture.directory </> "replacement-target"
            armFile = fixture.directory </> "replace-before-input"
            reportFile = fixture.directory </> "replacement-input"
            shellWord value = "'" <> concatMap (\character -> if character == '\'' then "'\\''" else [character]) value <> "'"
            native = shellWord fixture.executable <> " -N -S " <> shellWord fixture.socket
            replacement = "stty -echo -icanon min 1 time 0; " <> native <> " wait-for -S program-replacement-ready; "
              <> native <> " wait-for program-replacement-release; IFS= read -r -t 0.1 -N 1 received; printf '%s' \"$received\" > "
              <> shellWord reportFile <> "; " <> native <> " wait-for -S program-replacement-done"
            shim = "#!/bin/sh\nif [ -f " <> shellWord armFile <> " ]; then\n  for argument in \"$@\"; do\n    case \"$argument\" in *send-keys*)\n"
              <> "      /bin/rm -- " <> shellWord armFile <> "\n      " <> native <> " respawn-pane -k -t \"$(/bin/cat " <> shellWord targetFile <> ")\" /bin/bash -c " <> shellWord replacement <> " || exit $?\n"
              <> "      " <> native <> " wait-for program-replacement-ready || exit $?\n      break;;\n    esac\n  done\nfi\nexec " <> shellWord fixture.executable <> " \"$@\"\n"
        Bytes.writeFile wrapper (Bytes.pack shim)
        File.setFileMode wrapper 0o700
        Tmux.withServer ((config fixture) {Tmux.executable = Os.fromBytestring (Bytes.pack wrapper)}) $ \server -> do
          selected <- newEmptyTMVarIO
          observed <- newEmptyTMVarIO
          outcome <- tryWithContext @SomeException $ Tmux.withProgram server (options "/bin/cat" ["-"]) $ \program -> do
            snapshot <- Tmux.capture server
            session <- case [value | value <- Tmux.sessions snapshot, value.name /= "fixture"] of
              [value] -> pure (Text.unpack (Tmux.renderSessionId (Tmux.sessionId value.ref)))
              _ -> fail "owned application session was not unique"
            (code, pane, errors) <- Fixture.command fixture ["display-message", "-p", "-t", session <> ":", "#{pane_id}"]
            (code, errors) @?= (ExitSuccess, "")
            Bytes.writeFile targetFile (Lazy.toStrict pane)
            Bytes.writeFile armFile "armed"
            atomically (putTMVar selected session)
            refusal <- try @SomeException (Program.sendProgramInput program "must not reach replacement\n")
            configured fixture ["wait-for", "-S", "program-replacement-release"]
            bounded (configured fixture ["wait-for", "program-replacement-done"])
            received <- Bytes.readFile reportFile
            let refused = case refusal of Left _ -> True; Right () -> False
            atomically (putTMVar observed (refused, received))
          case outcome of
            Left (ExceptionWithContext context _) -> do
              recovery <- case Program.programRecoveries context of
                [value] -> pure value
                _ -> fail "stale cleanup lost its recovery owner"
              session <- bounded (atomically (readTMVar selected))
              configured fixture ["has-session", "-t", session]
              (code, dead, errors) <- Fixture.command fixture ["display-message", "-p", "-t", session <> ":", "#{pane_dead}"]
              (code, dead, errors) @?= (ExitSuccess, "1\n", "")
              configured fixture ["kill-session", "-t", session]
              Program.resumeProgramCleanup recovery
            Right () -> assertFailure "stale cleanup removed the replacement"
          (refused, received) <- bounded (atomically (readTMVar observed))
          assertBool "stale input was accepted" refused
          received @?= ""
          borrowedOnly server
  , testCase "capture hooks cannot add output and byte bounds report omission" $ do
      retained <- withServer $ \fixture server -> do
        configured fixture ["set-buffer", "-b", "borrowed", "borrowed bytes"]
        configured fixture ["set-hook", "-g", "after-capture-pane", "display-message -p injected-after-capture"]
        flip finally (configured fixture ["set-hook", "-gu", "after-capture-pane"]) $ do
          result <- Tmux.runProgram server (options "/usr/bin/printf" ["%s", "0123456789abcdef"])
            {Program.outputLimit = 8}
          result.programOutput.screenBytes @?= "01234567"
          assertBool "omitted bytes were hidden" (result.programOutput.omittedBytes > 0)
        (code, buffers, errors) <- Fixture.command fixture ["list-buffers", "-F", "#{buffer_name}"]
        (code, buffers, errors) @?= (ExitSuccess, "borrowed\n", "")
        failure <- tryWithContext @SomeException $
          Tmux.withProgram server (options "/bin/cat" ["-"]) $ \program -> do
            snapshot <- Tmux.capture server
            session <- case [value | value <- Tmux.sessions snapshot, value.name /= "fixture"] of
              [value] -> pure (Text.unpack (Tmux.renderSessionId (Tmux.sessionId value.ref)))
              _ -> fail "owned application session was not unique"
            (splitCode, createdPane, splitErrors) <- Fixture.command fixture
              ["split-window", "-P", "-F", "#{pane_id}", "-t", session <> ":", "/bin/cat", "-"]
            (splitCode, splitErrors) @?= (ExitSuccess, "")
            foreignPane <- case Bytes.lines (Lazy.toStrict createdPane) of
              [value] -> pure (Bytes.unpack value)
              _ -> fail "foreign pane identity was not unique"
            flip finally (configured fixture ["kill-pane", "-t", foreignPane]) $
              Program.readProgramScreen program >> pure ()
        borrowedOnly server
        (bufferCode, contents, bufferErrors) <- Fixture.command fixture ["show-buffer", "-b", "borrowed"]
        (bufferCode, contents, bufferErrors) @?= (ExitSuccess, "borrowed bytes", "")
        pure failure
      case retained of
        Left (ExceptionWithContext context problem) -> do
          let recoveries = Program.programRecoveries context
          -- The daemon has exited, so a failing regression can retire its
          -- retained owner without sending another remote mutation.
          mapM_ Program.resumeProgramCleanup recoveries
          case fromException problem of
            Just (Tmux.MutationAppliedWithErrors _) -> pure ()
            _ -> assertFailure ("capture refusal lost its original failure: " <> displayException problem)
          assertBool ("an absent owned buffer retained cleanup: " <>
            show (map (fmap displayException . Program.programCleanupFailure) recoveries)) (null recoveries)
        Right () -> assertFailure "capture accepted the externally split pane"
  , testCase "capture refuses changed geometry before allocating output" $
      withServer $ \fixture server -> do
        Tmux.withProgram server (options "/bin/cat" ["-"]) $ \program -> do
          snapshot <- Tmux.capture server
          session <- case [value | value <- Tmux.sessions snapshot, value.name /= "fixture"] of
            [value] -> pure (Text.unpack (Tmux.renderSessionId (Tmux.sessionId value.ref)))
            _ -> fail "owned application session was not unique"
          configured fixture ["resize-window", "-t", session <> ":", "-x", "501", "-y", "201"]
          try @Tmux.TmuxException (Program.readProgramScreen program) >>= \case
            Left (Tmux.MutationAppliedWithErrors _) -> pure ()
            _ -> assertFailure "capture ignored the changed terminal bounds"
        (code, buffers, errors) <- Fixture.command fixture ["list-buffers", "-F", "#{buffer_name}"]
        (code, buffers, errors) @?= (ExitSuccess, "", "")
        borrowedOnly server
  , testCase "invalid settings refuse before new sessions" $
      withServer $ \_ server ->
        forM_ [(options "/bin/true" []) {Program.arguments = [Os.fromBytestring "bad\NULarg"]},
               (options "/bin/true" []) {Program.outputLimit = 0},
               (options "/bin/true" []) {Program.columns = 501},
               (options "/bin/true" []) {Program.environment = [(Os.fromBytestring "bad-name", Os.fromBytestring "x")]},
               (options "/bin/true" []) {Program.environment = [(Os.fromBytestring "PPID", Os.fromBytestring "x")]},
               (options "/bin/true" []) {Program.environment = [(Os.fromBytestring "A=B", Os.fromBytestring "x")]}] $ \settings -> do
          try @Program.ProgramError (Tmux.runProgram server settings) >>= \case
            Left (Program.InvalidProgramOptions _) -> pure ()
            _ -> assertFailure "invalid settings reached application execution"
          borrowedOnly server
  , testCase "owning execution deadline cleans up before returning" $
      withServer $ \_ server -> do
        entered <- newEmptyTMVarIO
        try @Program.ProgramError (Tmux.withProgram server
          (options "/bin/sh" ["-c", "trap '' HUP TERM; exec /bin/cat -"])
            {Program.executionTimeout = Just 0.5} $ \program ->
              atomically (putTMVar entered ()) >> Program.waitProgram program) >>= \case
          Left Program.ProgramTimedOut -> pure ()
          other -> assertFailure ("owning timeout became " <> show other)
        atomically (tryReadTMVar entered) >>= (@?= Just ())
        borrowedOnly server
  , testCase "unavailable or incompatible Bash refuses before application creation" $
      withServer $ \_ server -> forM_ ["/libtmux-haskell-missing-bash", "/bin/sh"] $ \shell -> do
        try @Program.ProgramError (Tmux.runProgram server
          (options "/bin/true" []) {Program.bootstrapShell = Os.fromBytestring shell}) >>= \case
          Left Program.ProgramBootstrapUnavailable -> pure ()
          _ -> assertFailure "unqualified bootstrap shell admitted an application"
        borrowedOnly server
  , testCase "rename before acquisition preserves identity and respawn refuses execution" $
      Fixture.withFixture $ \fixture -> forM_ [False, True] $ \replace -> do
        let marker = fixture.directory </> "application-effect"
            hook = "wait-for -S program-created-entered ; wait-for program-created-release"
        bracket_ (configured fixture ["set-hook", "-g", "after-new-session", hook])
          (configured fixture ["set-hook", "-gu", "after-new-session"]) $
          Tmux.withServer (config fixture) $ \server -> do
            withAsync (tryWithContext @SomeException (Tmux.runProgram server
              (options "/bin/sh" ["-c", "printf launched > \"$1\"", "app", marker])
                {Program.commandTimeout = 0.25})) $ \owner -> do
              configured fixture ["wait-for", "program-created-entered"]
              (code, targets, errors) <- Fixture.command fixture ["list-sessions", "-F", "#{session_id}:#{session_name}"]
              (code, errors) @?= (ExitSuccess, "")
              session <- case [Bytes.takeWhile (/= ':') row | row <- Bytes.lines (Lazy.toStrict targets),
                  ":libtmux-haskell-program-" `Bytes.isInfixOf` row] of
                [value] -> pure (Bytes.unpack value)
                _ -> fail "created application session was not unique"
              configured fixture ["rename-session", "-t", session, "renamed-program"]
              if replace then configured fixture ["respawn-pane", "-k", "-t", session <> ":", "/bin/cat", "-"] else pure ()
              configured fixture ["wait-for", "-S", "program-created-release"]
              result <- bounded (wait owner)
              if replace then case result of
                Left (ExceptionWithContext context _) -> do
                  Directory.doesFileExist marker >>= (@?= False)
                  recoveries <- case Program.programRecoveries context of
                    [] -> assertFailure "replacement refusal lost cleanup ownership" >> fail "unreachable"
                    values -> pure values
                  configured fixture ["kill-session", "-t", session]
                  mapM_ Program.resumeProgramCleanup recoveries
                Right _ -> assertFailure "factory executed through external respawn"
              else case result of
                Right output -> do
                  output.programExit @?= Program.ProgramExited 0
                  Bytes.readFile marker >>= (@?= "launched")
                  Directory.removeFile marker
                Left problem -> rethrowIO problem
            borrowedOnly server
  , testCase "daemon replacement preserves the new daemon and settles the original group" $
      Fixture.withFixture $ \fixture -> Fixture.withFixture $ \replacement -> do
        let inputFile = fixture.directory </> "daemon-loss-input"
            rebound = replacement {Fixture.socket = fixture.socket}
        File.createNamedPipe inputFile 0o600
        (beforeCode, beforePid, beforeErrors) <- Fixture.command replacement ["display-message", "-p", "#{pane_pid}"]
        (beforeCode, beforeErrors) @?= (ExitSuccess, "")
        bracket (Posix.openFd inputFile Posix.ReadWrite
          Posix.defaultFileFlags {Posix.nonBlock = True, Posix.cloexec = True}) Posix.closeFd $ \_ ->
          Tmux.withServer (config fixture) $ \server -> do
            snapshot <- Tmux.capture server
            bracket (Native.daemonWatch (Bytes.pack fixture.socket) (Tmux.serverInfo snapshot).pid) Native.close $ \daemon -> do
              entered <- newEmptyTMVarIO
              release <- newEmptyTMVarIO
              withAsync (tryWithContext @SomeException $ Tmux.withProgram server
                (options "/bin/sh" ["-c", "trap '' HUP TERM; exec /bin/cat \"$1\"", "application", inputFile]) $ \program -> do
                  current <- Tmux.capture server
                  session <- case [value | value <- Tmux.sessions current, value.name /= "fixture"] of
                    [value] -> pure (Text.unpack (Tmux.renderSessionId (Tmux.sessionId value.ref)))
                    _ -> fail "owned application session was not unique"
                  (code, pid, errors) <- Fixture.command fixture ["display-message", "-p", "-t", session <> ":", "#{pane_pid}"]
                  (code, errors) @?= (ExitSuccess, "")
                  atomically (putTMVar entered pid)
                  atomically (readTMVar release)
                  Program.waitProgram program) $ \owner -> do
                    pid <- bounded (atomically (readTMVar entered))
                    Fixture.withTrackedPane pid (atomically (putTMVar release ())) $
                      bracket (Native.openPid (read (Bytes.unpack (Lazy.toStrict pid)))) Native.close $ \application -> do
                        configured fixture ["kill-server"]
                        bounded (threadWaitRead (Fd daemon))
                        Directory.renameFile replacement.socket fixture.socket
                        Native.pidReady application >>= (@?= False)
                    bounded (wait owner) >>= \case
                      Left (ExceptionWithContext context problem)
                        | Just (Program.ProgramObservationLost _) <- fromException problem ->
                            assertBool "daemon loss retained unnecessary cleanup" (null (Program.programRecoveries context))
                      other -> assertFailure ("daemon loss became " <> show other)
        (afterCode, afterPid, afterErrors) <- Fixture.command rebound ["display-message", "-p", "#{pane_pid}"]
        (afterCode, afterPid, afterErrors) @?= (ExitSuccess, beforePid, "")
  , testCase "cleanup retains its cause and survives the borrowing Server scope" $
      Fixture.withFixture $ \fixture -> do
        selected <- newEmptyTMVarIO
        outcome <- Tmux.withServer (config fixture) $ \server ->
          tryWithContext @SomeException $ Tmux.withProgram server (options "/bin/cat" ["-"]) $ \_ -> do
            snapshot <- Tmux.capture server
            session <- case [value | value <- Tmux.sessions snapshot, value.name /= "fixture"] of
              [value] -> pure (Text.unpack (Tmux.renderSessionId (Tmux.sessionId value.ref)))
              _ -> fail "owned application session was not unique"
            atomically (putTMVar selected session)
            configured fixture ["respawn-pane", "-k", "-t", session <> ":", "/bin/cat", "-"]
            throwIO (userError "original program callback")
        case outcome of
          Left (ExceptionWithContext context problem) -> do
            assertBool "primary callback failure was replaced" ("original program callback" `Text.isInfixOf` Text.pack (displayException problem))
            recovery <- case Program.programRecoveries context of
              [value] -> pure value
              _ -> fail "expected one Program recovery"
            assertBool "cleanup failure cause was discarded" (isJust (Program.programCleanupFailure recovery))
            before <- Program.inspectProgramCleanup recovery
            before.resourcesRetired @?= False
            session <- atomically (readTMVar selected)
            configured fixture ["kill-session", "-t", session]
            Program.resumeProgramCleanup recovery
            after <- Program.inspectProgramCleanup recovery
            after @?= Program.ProgramCleanupStatus True True False
          Right () -> assertFailure "callback failure did not propagate"
  , testCase "owning cleanup settles a TERM-resistant same-group descendant" $
      withServer $ \fixture server -> do
        entered <- newEmptyTMVarIO
        release <- newEmptyTMVarIO
        let pidFile = fixture.directory </> "descendant-pid"
            inputFile = fixture.directory </> "descendant-input"
            child = "trap '' HUP TERM; printf '%s\\n' \"$$\" > \"$1\"; \"$2\" -N -S \"$3\" wait-for -S program-child-ready; exec /bin/cat \"$4\""
            parent = "trap '' HUP TERM; /bin/sh -c \"$1\" child \"$2\" \"$3\" \"$4\" \"$5\" & wait"
        File.createNamedPipe inputFile 0o600
        -- A background shell otherwise redirects cat's stdin to /dev/null.
        bracket (Posix.openFd inputFile Posix.ReadWrite
          Posix.defaultFileFlags {Posix.nonBlock = True, Posix.cloexec = True}) Posix.closeFd $ \_ ->
          withAsync (Tmux.withProgram server (options "/bin/sh" ["-c", parent, "parent", child,
              pidFile, fixture.executable, fixture.socket, inputFile]) $ \_ -> do
            configured fixture ["wait-for", "program-child-ready"]
            childPid <- Bytes.readFile pidFile
            atomically (putTMVar entered childPid)
            atomically (readTMVar release)) $ \owner -> do
              childPid <- bounded (atomically (readTMVar entered))
              Fixture.withTrackedPane (Lazy.fromStrict childPid) (atomically (putTMVar release ())) (pure ())
              bounded (wait owner)
        borrowedOnly server
  , testCase "callback failure and owning cancellation preserve exception classes" $
      withServer $ \fixture server -> forM_ [False, True] $ \cancelled -> do
        entered <- newEmptyTMVarIO
        release <- newEmptyTMVarIO
        withAsync (tryWithContext @SomeException (Tmux.withProgram server
          (options "/bin/sh" ["-c", "trap '' HUP TERM; exec /bin/cat -"]) $ \_ -> do
            snapshot <- Tmux.capture server
            let owned = [session | session <- Tmux.sessions snapshot, session.name /= "fixture"]
            session <- case owned of [one] -> pure one; _ -> fail "application session identity missing"
            let target = Text.unpack (Tmux.renderSessionId (Tmux.sessionId session.ref)) <> ":"
            (code, pid, errors) <- Fixture.command fixture ["display-message", "-p", "-t", target, "#{pane_pid}"]
            (code, errors) @?= (ExitSuccess, "")
            atomically (putTMVar entered pid)
            atomically (readTMVar release)
            throwIO (userError "program callback failure"))) $ \owner -> do
              pid <- bounded (atomically (readTMVar entered))
              Fixture.withTrackedPane pid
                (if cancelled then throwTo (asyncThreadId owner) ThreadKilled else atomically (putTMVar release ())) (pure ())
              bounded (wait owner) >>= \case
                Left (ExceptionWithContext _ problem)
                  | cancelled -> fromException @AsyncException problem @?= Just ThreadKilled
                  | otherwise -> assertBool "callback failure was replaced" ("program callback failure" `Text.isInfixOf` Text.pack (displayException problem))
                _ -> assertFailure "owning failure did not propagate"
        borrowedOnly server
  ]

withServer :: (Fixture.Fixture -> Tmux.Server -> IO a) -> IO a
withServer action = Fixture.withFixture $ \fixture -> Tmux.withServer (config fixture) (action fixture)

config :: Fixture.Fixture -> Tmux.ServerConfig
config fixture = (Tmux.serverConfig (Os.fromBytestring (Bytes.pack fixture.socket)))
  {Tmux.executable = Os.fromBytestring (Bytes.pack fixture.executable)}

options :: String -> [String] -> Program.ProgramOptions
options file args = Program.programOptions (Os.fromBytestring (Bytes.pack file))
  (map (Os.fromBytestring . Bytes.pack) args)

borrowedOnly :: Tmux.Server -> IO ()
borrowedOnly server = do
  snapshot <- Tmux.capture server
  map (.name) (Tmux.sessions snapshot) @?= ["fixture"]

configured :: Fixture.Fixture -> [String] -> IO ()
configured fixture args = do
  (code, _, errors) <- Fixture.command fixture args
  (code, errors) @?= (ExitSuccess, "")

bounded :: IO a -> IO a
bounded action = timeout 1000000 action >>= maybe (assertFailure "event watchdog elapsed" >> fail "unreachable") pure
