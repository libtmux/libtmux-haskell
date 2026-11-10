module CommandIntegrationTest (tests) where

import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.Text.Encoding qualified as Utf8
import Fixture qualified
import LibTmux.Id qualified as Id
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.Command qualified as C
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Native qualified as N
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.SocketPin (pinPath)
import LibTmux.Internal.TmuxText qualified as Label
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase, (@?=))

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
  ]

invoke :: Fixture.Fixture -> R.ServerHandle -> [Bytes.ByteString] -> IO P.Completion
invoke fixture client arguments = invokeWithInput fixture client arguments (P.BytesInput "")

invokeWithInput :: Fixture.Fixture -> R.ServerHandle -> [Bytes.ByteString] -> P.Input -> IO P.Completion
invokeWithInput fixture client arguments input = do
  let executable = Ascii.pack fixture.executable
      spec = N.spec executable ([executable, "-u", "-N", "-S", pinPath (R.serverPin client)] <> arguments)
  ticket <- P.submitInputRegistered (const (pure ())) B.Ordinary P.defaultHooks (R.serverPool client) spec input
  timeout 1000000 (P.await ticket) >>= maybe (fail "native mutation probe did not complete") pure

require :: Show problem => Either problem value -> IO value
require = either (fail . show) pure
