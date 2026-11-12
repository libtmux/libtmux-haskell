module CreationTest (tests) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import LibTmux.Id qualified as Id
import LibTmux.Internal.Command qualified as C
import LibTmux.Internal.Frame qualified as F
import LibTmux.Internal.TmuxText qualified as Label
import LibTmux.Value qualified as Value
import System.OsString.Posix qualified as Os
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests = testGroup "session creation receipts"
  [ testCase "default creation keeps tmux process defaults and requests detached receipts" $ do
      nonce <- require (F.parseNonce token)
      C.compileSessionCreation nonce C.defaultSessionOptions @?=
        Right ["new-session", "-d", "-P", "-F", C.sessionCreationFormat nonce, "--"]
  , testCase "creation distinguishes format operands from literal process and environment bytes" $ do
      nonce <- require (F.parseNonce token)
      width <- require (Value.mkDimension 120)
      let options = C.defaultSessionOptions
            { C.name = Just "#{pid};"
            , C.windowName = Just (Label.fromBytes "#[red]")
            , C.workingDirectory = Just (Os.fromBytestring "/tmp/#{pid};")
            , C.environment = [(Os.fromBytestring "KEY", Os.fromBytestring "#{pid};")]
            , C.width = Just width
            , C.updateEnvironment = False
            , C.process = C.ShellCommand "printf '%s' '#{pid}';"
            }
      C.compileSessionCreation nonce options @?= Right
        ["new-session", "-d", "-P", "-F", C.sessionCreationFormat nonce
        , "-s", "#{a:35}{pid}\\;", "-n", "#{a:35}[red]"
        , "-c", "/tmp/#{a:35}{pid}\\;", "-x", "120", "-E"
        , "-e", "KEY=#{pid}\\;", "--", "printf '%s' '#{pid}'\\;"]
  , testCase "native argv and an empty pane remain distinct from a shell command" $ do
      nonce <- require (F.parseNonce token)
      let compile process = C.compileSessionCreation nonce
            C.defaultSessionOptions {C.process = process}
          base = ["new-session", "-d", "-P", "-F", C.sessionCreationFormat nonce, "--"]
      compile (C.DirectCommand (Os.fromBytestring "/bin/printf")
        [Os.fromBytestring "%s", Os.fromBytestring "#{pid};"]) @?=
        Right (base <> ["/bin/printf", "%s", "#{pid}\\;"])
      compile C.EmptyPane @?= Right (base <> [""])
      compile (C.DirectCommand (Os.fromBytestring "/bin/true") []) @?=
        Left (C.InvalidOperand "initialProcess" "direct execution requires at least one argument")
      compile (C.ShellCommand "") @?=
        Left (C.InvalidOperand "initialProcess" "empty shell command; use EmptyPane")
  , testCase "creation rejects invalid domains and bounded vectors before expansion" $ do
      nonce <- require (F.parseNonce token)
      large <- require (Value.mkDimension 65536)
      let compile = C.compileSessionCreation nonce
      compile C.defaultSessionOptions {C.name = Just "bad\NULname"} @?=
        Left (C.NulOperand "session.name")
      compile C.defaultSessionOptions {C.environment = [(Os.fromBytestring "A=B", Os.fromBytestring "x")]} @?=
        Left (C.InvalidOperand "environment" "invalid variable name")
      compile C.defaultSessionOptions {C.environment = [(Os.fromBytestring "", Os.fromBytestring "x")]} @?=
        Left (C.InvalidOperand "environment" "invalid variable name")
      compile C.defaultSessionOptions {C.width = Just large} @?=
        Left (C.InvalidOperand "width" "dimension exceeds 65535 cells")
      compile C.defaultSessionOptions {C.process = C.DirectCommand (Os.fromBytestring "/bin/echo")
        (repeat (Os.fromBytestring "x"))} @?=
        Left (C.InvalidOperand "initialProcess" "argument count exceeds 4096")
      compile C.defaultSessionOptions {C.environment = repeat (Os.fromBytestring "A", Os.fromBytestring "x")} @?=
        Left (C.InvalidOperand "environment" "variable count exceeds 4096")
      compile C.defaultSessionOptions {C.windowName = Just (Label.fromBytes (Bytes.replicate 10000 35))} @?=
        Left (C.EncodedCommandTooLarge "session.creation")
  , testCase "creation prints only nonce-qualified native identities" $ do
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
  , testCase "creation success requires a standalone exit footer" $ do
      nonce <- require (F.parseNonce token)
      expected <- receipt
      C.decodeSessionCreation nonce (Just 0) (packet line "junk") "" @?=
        C.SessionCreationUnknown (Just expected) C.UnexpectedReply
  , testCase "creation hook errors require a standalone exit footer" $ do
      nonce <- require (F.parseNonce token)
      expected <- receipt
      C.decodeSessionCreation nonce (Just 1) (packet line "junk") "" @?=
        C.SessionCreationUnknown (Just expected) C.UnexpectedReply
  , testCase "creation rejection requires a standalone exit footer" $ do
      nonce <- require (F.parseNonce token)
      C.decodeSessionCreation nonce (Just 1) (begin <> "rejected\n" <> failed <> "junk" <> footer) "" @?=
        C.SessionCreationUnknown Nothing C.UnexpectedReply
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
