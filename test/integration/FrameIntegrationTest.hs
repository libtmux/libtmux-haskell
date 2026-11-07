module FrameIntegrationTest (tests) where

import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Fixture (command, withFixture)
import LibTmux.Internal.Frame
import System.Exit (ExitCode (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests = testGroup "real scalar framing"
  [ testCase "decodes one value and rejects successful after-hook output" $
      withFixture $ \fixture -> do
        nonce <- either (fail . show) pure (parseNonce (Bytes.replicate 64 '0'))
        let value = "first\n\t'quotes' \\ #{syntax},; last\n\n"
            format = Bytes.unpack (scalarFormat nonce "#{@libtmux-test-value}")
            display = ["-u", "display-message", "-p", "-t", "fixture:0.0", "-F", format]
        (setCode, _, setErrors) <- command fixture
          ["set-option", "-g", "@libtmux-test-value", Bytes.unpack value]
        (setCode, setErrors) @?= (ExitSuccess, "")
        (code, output, errors) <- command fixture display
        (code, errors) @?= (ExitSuccess, "")
        decodeScalar nonce 1024 (Lazy.toStrict output) @?= Right value
        (hookCode, _, hookErrors) <- command fixture
          ["set-hook", "-g", "after-display-message", "display-message -p hook-output"]
        (hookCode, hookErrors) @?= (ExitSuccess, "")
        (hookedCode, hookedOutput, hookedErrors) <- command fixture display
        (hookedCode, hookedErrors) @?= (ExitSuccess, "")
        decodeScalar nonce 1024 (Lazy.toStrict hookedOutput) @?= Left UnexpectedScalarFrame
  ]
