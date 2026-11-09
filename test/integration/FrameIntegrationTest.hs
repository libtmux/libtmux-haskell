module FrameIntegrationTest (tests) where

import Control.Exception (bracket, bracket_)
import Control.Monad (forM_)
import Data.ByteString qualified as Raw
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Text.Encoding qualified as Utf8
import Fixture (Fixture (..), command, withFixture, withTrackedPane)
import LibTmux.Id (parsePaneId)
import LibTmux.Internal.Budget qualified as B
import LibTmux.Internal.Frame
import LibTmux.Internal.Process qualified as P
import LibTmux.Internal.Process.Native qualified as N
import LibTmux.Internal.Runtime qualified as R
import LibTmux.Internal.SocketPin (pinPath)
import System.Exit (ExitCode (..))
import System.Posix.Directory.ByteString qualified as Posix
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase, (@?=))
import Test.QuickCheck qualified as Q
import Test.QuickCheck.Gen (unGen)
import Test.QuickCheck.Random (mkQCGen)

tests :: TestTree
tests = testGroup "real scalar framing"
  [ testCase "decodes one value and rejects successful after-hook output" $
      withFixture $ \fixture -> do
        nonce <- either (fail . show) pure (parseNonce (Bytes.replicate 64 '0'))
        let value = "first\n\t'quotes' \\ #{syntax},; last\n\n"
            format = Bytes.unpack (scalarFormat nonce (escapedFieldFormat "@libtmux-test-value"))
            display = ["-u", "display-message", "-p", "-t", "fixture:0.0", "-F", format]
        (setCode, _, setErrors) <- command fixture
          ["set-option", "-g", "@libtmux-test-value", Bytes.unpack value]
        (setCode, setErrors) @?= (ExitSuccess, "")
        (code, output, errors) <- command fixture display
        (code, errors) @?= (ExitSuccess, "")
        decodeEscapedScalar nonce 1024 (Lazy.toStrict output) @?= Right value
        (hookCode, _, hookErrors) <- command fixture
          ["set-hook", "-g", "after-display-message", "display-message -p hook-output"]
        (hookCode, hookErrors) @?= (ExitSuccess, "")
        (hookedCode, hookedOutput, hookedErrors) <- command fixture display
        (hookedCode, hookedErrors) @?= (ExitSuccess, "")
        decodeEscapedScalar nonce 1024 (Lazy.toStrict hookedOutput) @?= Left UnexpectedScalarFrame
  , testCase "round trips non-text bytes, literal escapes and generated scalar values" $
      withFixture $ \fixture -> bracket (R.newRuntime P.normalFork) R.awaitCleanup $ \runtime -> do
        client <- R.adopt runtime (Bytes.pack fixture.socket) (Bytes.pack fixture.directory)
        nonce <- either (fail . show) pure (parseNonce (Bytes.replicate 64 '0'))
        let executable = Bytes.pack fixture.executable
            raw args = do
              let spec = N.spec executable
                    ([executable, "-u", "-N", "-S", pinPath (R.serverPin client)] <> args)
              result <- P.submit B.Ordinary P.defaultHooks (R.serverPool client) spec "" >>= P.await
              (result.exit, result.errors) @?= (Just (N.Exited 0), "")
              pure result.output
            generated = map Raw.pack $ unGen
              (Q.vectorOf 64 (Q.resize 128 (Q.listOf (Q.chooseEnum (1, 255))))) (mkQCGen 20261108) 128
            values = [Raw.singleton 255, "\\377", "a\\b\254\rc", "", "\\", "$x ${x} $(x) $1",
              "\r\n\t\SOH\n", "#{syntax},;", Raw.pack [1 .. 255]] <> map ("x" <>) generated
            display = ["display-message", "-p", "-t", "fixture:0.0", "-F",
              scalarFormat nonce (escapedFieldFormat "@libtmux-test-value")]
        forM_ values $ \value -> do
          -- tmux's argv parser consumes a terminal semicolon unless escaped.
          let argument = maybe value (<> "\\;") (Raw.stripSuffix ";" value)
          _ <- raw ["set-option", "-g", "@libtmux-test-value", argument]
          output <- raw display
          assertEqual ("scalar input " <> show value) (Right value)
            (decodeEscapedScalar nonce (Raw.length value) output)
        forM_ [Raw.singleton 255, "\\377", "a\\b\254\rc"] $ \leaf -> do
          let path = Bytes.pack fixture.directory <> "/" <> leaf
          bracket_ (Posix.createDirectory path 0o700) (Posix.removeDirectory path) $ do
            receipt <- raw ["new-window", "-d", "-P", "-F", "#{window_id} #{pane_id} #{pane_pid}",
              "-c", path, "/bin/cat", "-"]
            case Bytes.words receipt of
              [windowId, paneId, pid] -> withTrackedPane (Lazy.fromStrict (pid <> "\n"))
                (raw ["kill-window", "-t", windowId] >> pure ()) $
                (do
                  pane <- either (fail . show) pure (parsePaneId (Utf8.decodeUtf8 paneId))
                  request <- R.readEntityFieldWith (R.PanePath pane) P.defaultHooks 1000000
                    runtime client executable R.ScalarRead
                  R.awaitRead request >>= \case
                    R.ReadValue value -> value @?= path
                    other -> assertFailure (show other))
              other -> assertFailure ("invalid creation receipt: " <> show other)
  ]
