module CommandIntegrationTest (tests) where

import Control.Concurrent.Async (wait, withAsync)
import Control.Concurrent.STM (atomically, retry)
import Control.Exception (bracket, finally, try)
import Control.Monad (forM_, void)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.ByteString.Lazy qualified as Lazy
import Data.Text.Encoding qualified as Utf8
import Fixture qualified
import LibTmux.Id qualified as Id
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.Command qualified as C
import LibTmux.Internal.Frame qualified as Frame
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Native qualified as N
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.SocketPin (pinPath)
import LibTmux.Internal.TmuxText qualified as Label
import LibTmux.Value qualified as Value
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))

tests :: TestTree
tests = testGroup "native mutation lowering"
  [ testCase "compiled operands match literal native values through normalization" $
      Fixture.withFixture $ \fixture -> bracket (R.newRuntime P.normalFork) R.awaitCleanup $ \runtime -> do
        client <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
        session <- require (Id.parseSessionId "$0")
        window <- require (Id.parseWindowId "@0")
        pane <- require (Id.parsePaneId "%0")
        let raw = invoke fixture client
            readField target name = do
              result <- raw ["display-message", "-p", "-t", target, "-F", "#{" <> name <> "}"]
              (result.exit, result.errors) @?= (Just (N.Exited 0), "")
              pure result.output
            values = ["#{pid};", "#{?pane_active,a,b}", "-t", "", "a\\b;",
                      "a\nb\t", "name.with:punctuation", Bytes.pack [206, 187], Bytes.singleton 255,
                      "#[fg=red]", "##[fg=red]", "###[", "#[", "#[#{pid}]",
                      "#[fg=red]#{pid};", "#[#(not-a-command)]"]
        forM_ values $ \value -> do
          let text = either (const []) pure (Utf8.decodeUtf8' value)
              requests = (C.RenameWindow window (Label.fromBytes value), "@0", "window_name") :
                [entry | label <- text, entry <-
                  [(C.RenameSession session label, "$0", "session_name"),
                   (C.SetPaneTitle pane label, "%0", "pane_title")]]
              -- User options retain literal bytes without format expansion.
              argument = maybe value (<> "\\;") (Bytes.stripSuffix ";" value)
          configured <- raw ["set-option", "-g", "@libtmux-mutation-oracle", argument]
          (configured.exit, configured.errors) @?= (Just (N.Exited 0), "")
          forM_ requests $ \(mutation, target, name) -> do
            arguments <- require (C.compileMutation mutation)
            let oracle = take 4 arguments <> ["#{@libtmux-mutation-oracle}"]
            expectedResult <- raw oracle
            expected <- readField target name
            actualResult <- raw arguments
            actual <- readField target name
            assertEqual (show mutation) (expectedResult.exit, expectedResult.errors, expected)
              (actualResult.exit, actualResult.errors, actual)
  , testCase "native control replies retain rejection and errors after effects" $
      Fixture.withFixture $ \fixture -> bracket (R.newRuntime P.normalFork) R.awaitCleanup $ \runtime -> do
        client <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
        session <- require (Id.parseSessionId "$0")
        window <- require (Id.parseWindowId "@0")
        pane <- require (Id.parsePaneId "%0")
        missing <- require (Id.parseWindowId "@999999")
        let raw = invoke fixture client
            run mutation = do
              arguments <- require (C.compileMutation mutation)
              completed <- invokeWithInput fixture client ("-C" : arguments) P.KeepInputOpen
              let exited = case completed.exit of
                    Just (N.Exited status) -> Just (fromIntegral status)
                    _ -> Nothing
              require (C.decodeControlReply exited completed.output completed.errors)
            inspect target name = do
              completed <- raw ["display-message", "-p", "-t", target, "-F", "#{" <> name <> "}"]
              (completed.exit, completed.errors) @?= (Just (N.Exited 0), "")
              pure completed.output
            configured arguments = do
              completed <- raw arguments
              (completed.exit, completed.output, completed.errors) @?= (Just (N.Exited 0), "", "")
        run (C.RenameSession session "renamed") >>= (@?= C.Applied)
        inspect "$0" "session_name" >>= (@?= "renamed\n")
        run (C.RenameWindow window "#[#{pid}];") >>= (@?= C.Applied)
        inspect "@0" "window_name" >>= (@?= "#[#{pid}];\n")
        let title = "quotes\" and $HOME\nλ"
        configured ["set-option", "-g", "@libtmux-script-title", Utf8.encodeUtf8 title]
        configured ["select-pane", "-t", "%0", "-T", "#{@libtmux-script-title}"]
        expectedTitle <- inspect "%0" "pane_title"
        run (C.SetPaneTitle pane title) >>= (@?= C.Applied)
        inspect "%0" "pane_title" >>= (@?= expectedTitle)
        forM_ ["\"$HOME`id`\\;", "tab\tline\n", "#[#(not-a-command)]",
               Bytes.singleton 255, Bytes.pack [1 .. 255]] $ \value -> do
          let argument = maybe value (<> "\\;") (Bytes.stripSuffix ";" value)
          configured ["set-option", "-g", "@libtmux-script-window", argument]
          oracle <- raw ["rename-window", "-t", "@0", "--", "#{@libtmux-script-window}"]
          expected <- inspect "@0" "window_name"
          reply <- run (C.RenameWindow window (Label.fromBytes value))
          case oracle.exit of
            Just (N.Exited 0) -> reply @?= C.Applied
            Just (N.Exited 1) -> case reply of
              C.Rejected _ -> pure ()
              other -> fail (show other)
            other -> fail (show other)
          inspect "@0" "window_name" >>= (@?= expected)
        run (C.RenameWindow missing "absent") >>= \case
          C.Rejected diagnostic -> Bytes.null diagnostic @?= False
          other -> fail (show other)
        configured ["set-hook", "-g", "after-rename-window", "has-session -t =libtmux-command-missing"]
        run (C.RenameWindow window "effect-before-hook-error") >>= \case
          C.AppliedWithErrors diagnostic -> Bytes.null diagnostic @?= False
          other -> fail (show other)
        inspect "@0" "window_name" >>= (@?= "effect-before-hook-error\n")
        configured ["set-hook", "-gu", "after-rename-window"]
  , testCase "session creation returns actual identities and rejects duplicate names" $
      Fixture.withFixture $ \fixture -> bracket (R.newRuntime P.normalFork) R.awaitCleanup $ \runtime -> do
        client <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
        nonce <- require (Frame.parseNonce (Bytes.replicate 64 97))
        let name = "created-native"
        completed <- createSessionProbe fixture client nonce name
        withCreatedPane fixture client name $ do
          case creationReply nonce completed of
            C.SessionCreated receipt -> verifyCreated fixture client name receipt
            other -> fail (show other)
          before <- invoke fixture client ["list-sessions", "-F", "#{session_id}"]
          duplicate <- createSessionProbe fixture client nonce name
          case creationReply nonce duplicate of
            C.SessionCreationRejected diagnostic -> assertBool "empty rejection" (not (Bytes.null diagnostic))
            other -> fail (show other)
          after <- invoke fixture client ["list-sessions", "-F", "#{session_id}"]
          (before.exit, before.errors, after.exit, after.errors) @?=
            (Just (N.Exited 0), "", Just (N.Exited 0), "")
          before.output @?= after.output
  , testCase "session creation separates hook failure and control-shaped hook output" $
      Fixture.withFixture $ \fixture -> bracket (R.newRuntime P.normalFork) R.awaitCleanup $ \runtime -> do
        client <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
        nonce <- require (Frame.parseNonce (Bytes.replicate 64 98))
        let fake = Frame.scalarFormat nonce "1 $0 @0 %0 0"
            cases = [("created-after-error", "has-session -t =libtmux-creation-missing", True),
                     ("created-after-output", "display-message -p '" <> fake <> "'", False)]
        forM_ cases $ \(name, hook, failing) ->
          flip finally (prepareCreation fixture client ["set-hook", "-gu", "after-new-session"]) $ do
            prepareCreation fixture client ["set-hook", "-g", "after-new-session", hook]
            completed <- createSessionProbe fixture client nonce name
            withCreatedPane fixture client name $ do
              receipt <- case (failing, creationReply nonce completed) of
                (True, C.SessionCreatedWithErrors value diagnostic) -> do
                  assertBool "empty hook error" (not (Bytes.null diagnostic))
                  pure value
                (False, C.SessionCreated value) -> do
                  assertBool "hook did not print the competing receipt" (fake `Bytes.isInfixOf` completed.output)
                  pure value
                (_, other) -> fail (show other)
              verifyCreated fixture client name receipt
  , testCase "session creation retains its receipt after a hook deletes the session" $
      Fixture.withFixture $ \fixture -> bracket (R.newRuntime P.normalFork) R.awaitCleanup $ \runtime -> do
        client <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
        nonce <- require (Frame.parseNonce (Bytes.replicate 64 99))
        let name = "created-delete"
            ready = "libtmux-create-ready"
            release = "libtmux-create-release"
            signal = prepareCreation fixture client ["wait-for", "-S", release]
            hook = "wait-for -S " <> ready <> " ; wait-for " <> release <>
              " ; kill-session -t =" <> name
            cleanup = signal `finally` prepareCreation fixture client ["set-hook", "-gu", "after-new-session"]
        flip finally cleanup $ do
          prepareCreation fixture client ["set-hook", "-g", "after-new-session", hook]
          withAsync (createSessionProbe fixture client nonce name) $ \request -> do
            prepareCreation fixture client ["wait-for", ready]
            withCreatedPane fixture client name $ do
              observed <- invoke fixture client ["display-message", "-p", "-t", "=" <> name <> ":", "-F", "#{session_id}"]
              (observed.exit, observed.errors) @?= (Just (N.Exited 0), "")
              signal
              completed <- wait request
              case creationReply nonce completed of
                C.SessionCreated receipt -> do
                  Utf8.encodeUtf8 (Id.renderSessionId receipt.sessionId) <> "\n" @?= observed.output
                  missing <- invoke fixture client ["has-session", "-t", Utf8.encodeUtf8 (Id.renderSessionId receipt.sessionId)]
                  missing.exit @?= Just (N.Exited 1)
                other -> fail (show other)
  , testCase "session creation retains observed IDs when a waiting hook is cancelled" $
      Fixture.withFixture $ \fixture -> bracket (R.newRuntime P.normalFork) R.awaitCleanup $ \runtime -> do
        client <- R.adopt runtime (Ascii.pack fixture.socket) (Ascii.pack fixture.directory)
        nonce <- require (Frame.parseNonce (Bytes.replicate 64 100))
        let name = "created-cancel"
            release = "libtmux-created-cancel-release"
            signal = prepareCreation fixture client ["wait-for", "-S", release]
            cleanup = signal `finally` prepareCreation fixture client ["set-hook", "-gu", "after-new-session"]
        flip finally cleanup $ do
          prepareCreation fixture client ["set-hook", "-g", "after-new-session", "wait-for " <> release]
          ticket <- submitWithInput fixture client
            ["-C", "new-session", "-d", "-P", "-F", C.sessionCreationFormat nonce,
             "-s", name, "-n", "created-window", "--", "/bin/cat", "-"] P.KeepInputOpen
          receipt <- atomically $ do
            prefix <- P.stdoutPrefix ticket
            case C.decodeSessionCreation nonce Nothing prefix "" of
              C.SessionCreationUnknown (Just value) _ -> pure value
              _ -> retry
          withCreatedPane fixture client name $ do
            verifyCreated fixture client name receipt
            P.abort ticket
            try @P.OwnerError (P.await ticket) >>= \case
              Left P.Aborted -> pure ()
              Right completed -> completed.exit @?= Just (N.Signaled 9 False)
              Left other -> fail (show other)
            prefix <- atomically (P.stdoutPrefix ticket)
            C.decodeSessionCreation nonce Nothing prefix "" @?=
              C.SessionCreationUnknown (Just receipt) C.UnexpectedReply
  ]

createSessionProbe :: Fixture.Fixture -> R.ServerHandle -> Frame.Nonce -> Bytes.ByteString -> IO P.Completion
createSessionProbe fixture client nonce name = invokeWithInput fixture client
  ["-C", "new-session", "-d", "-P", "-F", C.sessionCreationFormat nonce,
   "-s", name, "-n", "created-window", "--", "/bin/cat", "-"] P.KeepInputOpen

creationReply :: Frame.Nonce -> P.Completion -> C.SessionCreationReply
creationReply nonce completed = C.decodeSessionCreation nonce exited completed.output completed.errors
  where
    exited = case completed.exit of
      Just (N.Exited status) -> Just (fromIntegral status)
      _ -> Nothing

prepareCreation :: Fixture.Fixture -> R.ServerHandle -> [Bytes.ByteString] -> IO ()
prepareCreation fixture client arguments = do
  completed <- invoke fixture client arguments
  (completed.exit, completed.output, completed.errors) @?= (Just (N.Exited 0), "", "")

withCreatedPane :: Fixture.Fixture -> R.ServerHandle -> Bytes.ByteString -> IO a -> IO a
withCreatedPane fixture client name action = do
  process <- invoke fixture client ["display-message", "-p", "-t", "=" <> name <> ":", "-F", "#{pane_pid}"]
  (process.exit, process.errors) @?= (Just (N.Exited 0), "")
  Fixture.withTrackedPane (Lazy.fromStrict process.output)
    (void (invoke fixture client ["kill-session", "-t", "=" <> name])) action

verifyCreated :: Fixture.Fixture -> R.ServerHandle -> Bytes.ByteString -> C.SessionReceipt -> IO ()
verifyCreated fixture client name receipt = do
  let session = Utf8.encodeUtf8 (Id.renderSessionId receipt.sessionId)
      expected = Bytes.intercalate "|"
        [name, session, Utf8.encodeUtf8 (Id.renderWindowId receipt.windowId),
         Utf8.encodeUtf8 (Id.renderPaneId receipt.paneId),
         Ascii.pack (show (Value.windowIndexValue receipt.windowIndex)), Ascii.pack (show receipt.serverPid)] <> "\n"
  observed <- invoke fixture client ["display-message", "-p", "-t", session <> ":", "-F",
    "#{session_name}|#{session_id}|#{window_id}|#{pane_id}|#{window_index}|#{pid}"]
  (observed.exit, observed.output, observed.errors) @?= (Just (N.Exited 0), expected, "")

invoke :: Fixture.Fixture -> R.ServerHandle -> [Bytes.ByteString] -> IO P.Completion
invoke fixture client arguments = invokeWithInput fixture client arguments (P.BytesInput "")

invokeWithInput :: Fixture.Fixture -> R.ServerHandle -> [Bytes.ByteString] -> P.Input -> IO P.Completion
invokeWithInput fixture client arguments input = do
  ticket <- submitWithInput fixture client arguments input
  timeout 1000000 (P.await ticket) >>= maybe (fail "native mutation probe did not complete") pure

submitWithInput :: Fixture.Fixture -> R.ServerHandle -> [Bytes.ByteString] -> P.Input -> IO P.Ticket
submitWithInput fixture client arguments input = do
  let executable = Ascii.pack fixture.executable
      spec = N.spec executable ([executable, "-u", "-N", "-S", pinPath (R.serverPin client)] <> arguments)
  P.submitInputRegistered (const (pure ())) B.Ordinary P.defaultHooks (R.serverPool client) spec input

require :: Show problem => Either problem value -> IO value
require = either (fail . show) pure
