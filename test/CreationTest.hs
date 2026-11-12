module CreationTest (tests) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import LibTmux.Id qualified as Id
import LibTmux.Internal.Command qualified as C
import LibTmux.Internal.Frame qualified as F
import LibTmux.Value qualified as Value
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests = testGroup "session creation receipts"
  [ testCase "creation prints only nonce-qualified native identities" $ do
      nonce <- require (F.parseNonce token)
      C.sessionCreationFormat nonce @?= F.scalarFormat nonce
        "#{pid} #{session_id} #{window_id} #{pane_id} #{window_index}"
  , testCase "native completion retains every created identity" $ do
      nonce <- require (F.parseNonce token)
      expected <- receipt
      C.decodeSessionCreation nonce (Just 0) (packet line "") "" @?= C.SessionCreated expected
  , testCase "a rejected command cannot acquire receipts from its diagnostic" $ do
      nonce <- require (F.parseNonce token)
      let diagnostic = "duplicate session: bad\n" <> line
      C.decodeSessionCreation nonce (Just 1) (begin <> diagnostic <> failed <> footer) "" @?=
        C.SessionCreationRejected diagnostic
  , testCase "following hooks cannot replace the primary receipt" $ do
      nonce <- require (F.parseNonce token)
      expected <- receipt
      let hook = "%begin 1794000000 28 0\n" <> framed "200 $9 @8 %7 6" <>
            "%error 1794000000 28 0\n"
      C.decodeSessionCreation nonce (Just 0) (packet line hook) "" @?= C.SessionCreated expected
      C.decodeSessionCreation nonce (Just 1) (packet line hook) "" @?=
        C.SessionCreatedWithErrors expected hook
  , testCase "incomplete native completion preserves a proved historical receipt" $ do
      nonce <- require (F.parseNonce token)
      expected <- receipt
      let unknown = C.SessionCreationUnknown (Just expected) C.UnexpectedReply
      forM_ [begin <> line, begin <> line <> ended,
             begin <> line <> "%end 1794000000 28 0\n" <> footer,
             begin <> line <> ended <> "%exit terminated\n"] $ \output ->
        C.decodeSessionCreation nonce (Just 0) output "" @?= unknown
      forM_ [Nothing, Just 1, Just 2] $ \status ->
        C.decodeSessionCreation nonce status (packet line "") "" @?= unknown
      C.decodeSessionCreation nonce (Just 0) (packet line "") "unexpected stderr" @?= unknown
  , testCase "native fields require canonical bounded domains and the matching nonce" $ do
      nonce <- require (F.parseNonce token)
      let unknown = C.SessionCreationUnknown Nothing C.UnexpectedReply
      forM_ ["0 $1 @2 %3 4", "01 $1 @2 %3 4", "2147483648 $1 @2 %3 4",
             "100 $01 @2 %3 4", "100 $4294967296 @2 %3 4", "100 @1 @2 %3 4",
             "100 $1 @2 %3 -1", "100 $1 @2 %3 04", "100 $1 @2 %3 2147483648",
             "100  $1 @2 %3 4", "100\t$1 @2 %3 4", "100 $1 @2 %3 4 extra",
             "100 $1 @2 %3 4\NUL"] $ \payload ->
        C.decodeSessionCreation nonce (Just 0) (packet (framed payload) "") "" @?= unknown
      let wrong = Bytes.replicate 64 98 <> ":100 $1 @2 %3 4:" <> Bytes.replicate 64 98 <> "\n"
      C.decodeSessionCreation nonce (Just 0) (packet wrong "") "" @?= unknown
      C.decodeSessionCreation nonce (Just 0) ("%begin 1794000000 27 1\n" <> line <> ended <> footer) "" @?= unknown
  , testCase "oversized tails cannot erase a bounded receipt or become success" $ do
      nonce <- require (F.parseNonce token)
      expected <- receipt
      let large = Bytes.replicate 1048577 120
          unknown = C.SessionCreationUnknown (Just expected) C.ReplyTooLarge
      C.decodeSessionCreation nonce (Just 0) (packet line large) "" @?= unknown
      C.decodeSessionCreation nonce (Just 0) (packet line "") large @?= unknown
      C.decodeSessionCreation nonce (Just 0) large "" @?=
        C.SessionCreationUnknown Nothing C.ReplyTooLarge
  ]

token, begin, ended, failed, footer, line :: ByteString
token = Bytes.replicate 64 97
begin = "%begin 1794000000 27 0\n"
ended = "%end 1794000000 27 0\n"
failed = "%error 1794000000 27 0\n"
footer = "%exit\n"
line = framed "100 $1 @2 %3 4"

framed :: ByteString -> ByteString
framed value = token <> ":" <> value <> ":" <> token <> "\n"

packet :: ByteString -> ByteString -> ByteString
packet value following = begin <> value <> ended <> following <> footer

receipt :: IO C.SessionReceipt
receipt = C.SessionReceipt 100
  <$> require (Id.parseSessionId "$1")
  <*> require (Id.parseWindowId "@2")
  <*> require (Id.parsePaneId "%3")
  <*> require (Value.mkWindowIndex 4)

require :: Show problem => Either problem value -> IO value
require = either (fail . show) pure
