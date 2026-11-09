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
  ]

invoke :: Fixture.Fixture -> R.ServerHandle -> [Bytes.ByteString] -> IO P.Completion
invoke fixture client arguments = do
  let executable = Ascii.pack fixture.executable
      spec = N.spec executable ([executable, "-u", "-N", "-S", pinPath (R.serverPin client)] <> arguments)
  ticket <- P.submit B.Ordinary P.defaultHooks (R.serverPool client) spec ""
  timeout 1000000 (P.await ticket) >>= maybe (fail "native mutation probe did not complete") pure

require :: Show problem => Either problem value -> IO value
require = either (fail . show) pure
