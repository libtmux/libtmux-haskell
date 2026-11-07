module FrameTest (tests) where

import Data.ByteString qualified as Bytes
import Data.Either (isLeft)
import LibTmux.Internal.Frame
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests = testGroup "scalar framing"
  [ testCase "rejects appended hook output instead of treating it as value bytes" $
      withNonce $ \nonce token -> do
        let frame = token <> ":value:" <> token <> "\n"
        decodeScalar nonce 1024 (frame <> "hook-output\n") @?= Left UnexpectedScalarFrame
        decodeScalar nonce 1024 ("hook-output\n" <> frame) @?= Left UnexpectedScalarFrame
  , testCase "preserves empty and arbitrary non-NUL byte payloads" $
      withNonce $ \nonce token -> do
        let payload = Bytes.pack [1 .. 255] <> "\n\n"
        decodeScalar nonce 1024 (token <> ":" <> payload <> ":" <> token <> "\n") @?= Right payload
        decodeScalar nonce 0 (token <> "::" <> token <> "\n") @?= Right ""
        scalarFormat nonce "#{pane_title}" @?= token <> ":#{pane_title}:" <> token
  , testCase "rejects missing boundaries, nonce collisions and impossible scalar NUL" $
      withNonce $ \nonce token -> do
        mapM_ (\output -> assertBool "malformed frame admitted" (isLeft (decodeScalar nonce 1024 output)))
          ["value\n", token <> ":value:" <> token, "", token <> ":value\n", token <> ":" <> token <> "\n"]
        decodeScalar nonce 1024 (token <> ":" <> token <> ":" <> token <> "\n") @?= Left AmbiguousScalarFrame
        decodeScalar nonce 1024 (token <> ":\NUL:" <> token <> "\n") @?= Left NulInScalar
  , testCase "checks payload limits without integer overflow or truncation" $
      withNonce $ \nonce token -> do
        let frame = token <> ":abc:" <> token <> "\n"
        decodeScalar nonce 3 frame @?= Right "abc"
        decodeScalar nonce 2 frame @?= Left (ScalarLimitExceeded 2 3)
        decodeScalar nonce (-1) frame @?= Left InvalidScalarLimit
        decodeScalar nonce maxBound frame @?= Right "abc"
  , testCase "requires a complete lower-case hexadecimal nonce" $ do
      mapM_ (\value -> assertBool "invalid nonce admitted" (isLeft (parseNonce value)))
        [Bytes.replicate 63 97, Bytes.replicate 65 97, Bytes.replicate 64 65, Bytes.replicate 64 103]
  ]
  where
    withNonce action = case parseNonce (Bytes.replicate 64 97) of
      Left problem -> fail (show problem)
      Right nonce -> action nonce (Bytes.replicate 64 97)
