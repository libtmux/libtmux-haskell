module VersionProbeTest (tests) where

import Control.Monad (forM_)
import Data.ByteString qualified as Bytes
import Data.Text.Encoding qualified as Utf8
import LibTmux.Internal.Frame qualified as F
import LibTmux.Internal.VersionProbe qualified as P
import LibTmux.Version qualified as V
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "hook-free version probe"
  [ testCase "only a closed nonce-qualified non-command reaches run-shell -C" $ do
      nonce <- require (F.parseNonce token)
      P.versionArguments nonce @?= ["run-shell", "-C", F.scalarFormat nonce "#{version}"]
  , testCase "the daemon's failed parse supplies a bounded version without stdout" $ do
      nonce <- require (F.parseNonce token)
      forM_ ["3.2", "3.3a", "3.8"] $ \release -> do
        expected <- require (V.parseVersion release)
        P.decodeVersionProbe nonce (Just 1) ""
          ("unknown command: " <> F.scalarFormat nonce (encode release) <> "\n") @?= Right expected
  , testCase "unrelated status, stdout and diagnostic data cannot become version evidence" $ do
      nonce <- require (F.parseNonce token)
      let reply = "unknown command: " <> F.scalarFormat nonce "3.8" <> "\n"
          cases = [(Nothing, "", reply), (Just 0, "", reply), (Just 1, "stdout", reply),
                   (Just 1, "", "prefix\n" <> reply), (Just 1, "", reply <> "extra\n"),
                   (Just 1, "", "unknown command: " <> Bytes.replicate 64 98 <> ":3.8:" <> token <> "\n")]
      forM_ cases $ \(status, output, diagnostic) ->
        case P.decodeVersionProbe nonce status output diagnostic of
          Left _ -> pure ()
          Right _ -> assertFailure "invalid probe response became a version"
  ]
  where
    token = Bytes.replicate 64 97
    encode = Utf8.encodeUtf8

require :: Show problem => Either problem a -> IO a
require = either (fail . show) pure
