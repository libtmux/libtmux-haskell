module VersionProbeTest (tests) where

import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad (forM_)
import Data.ByteString qualified as Bytes
import Data.Either (isLeft)
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
  , testCase "the daemon's PID uses the same channel and only a valid positive PID is evidence" $ do
      nonce <- require (F.parseNonce token)
      P.pidArguments nonce @?= ["run-shell", "-C", F.scalarFormat nonce "#{pid}"]
      let reply pid = "unknown command: " <> F.scalarFormat nonce pid <> "\n"
      P.decodePidProbe nonce (Just 1) "" (reply "4242") @?= Right 4242
      forM_ ["0", "-1", "4294967296", "12x", ""] $ \invalid ->
        assertBool "an invalid PID became evidence" (isLeft (P.decodePidProbe nonce (Just 1) "" (reply invalid)))
      assertBool "a successful run supplied evidence" (isLeft (P.decodePidProbe nonce (Just 0) "" (reply "4242")))
  , testCase "the daemon's failed parse supplies a bounded version without stdout" $ do
      nonce <- require (F.parseNonce token)
      forM_ ["3.2", "3.3a", "3.8"] $ \release -> do
        expected <- require (V.parseVersion release)
        P.decodeVersionProbe nonce (Just 1) ""
          ("unknown command: " <> F.scalarFormat nonce (encode release) <> "\n") @?= Right expected
  , testCase "every native token spelling survives the decoder's exact round trip" $ do
      nonce <- require (F.parseNonce token)
      forM_ ["3.3a", "3.8", "3.8a", "3.9", "3.10", "next-3.9", "3.8-rc", "3.8-rc1", "3.8-rc2", "3.8-rc3"] $ \release -> do
        expected <- require (V.parseVersion release)
        V.renderVersion expected @?= release
        P.decodeVersionProbe nonce (Just 1) "" (daemonReply nonce release) @?= Right expected
        evaluate (force expected) >>= (@?= expected)
  , testCase "the decoder neither guesses a release nor accepts a respelled one" $ do
      nonce <- require (F.parseNonce token)
      forM_ ["master", "3.8-dev", "3.8-rc0", "next-3.8a", "openbsd-7.4"] $ \unknown ->
        P.decodeVersionProbe nonce (Just 1) "" (daemonReply nonce unknown)
          @?= Left (P.InvalidProbeVersion (V.MalformedVersion unknown))
      P.decodeVersionProbe nonce (Just 1) "" (daemonReply nonce "tmux 3.8") @?= Left P.UnexpectedProbeReply
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
    daemonReply nonce release = "unknown command: " <> F.scalarFormat nonce (encode release) <> "\n"

require :: Show problem => Either problem a -> IO a
require = either (fail . show) pure
