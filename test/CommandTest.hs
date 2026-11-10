module CommandTest (tests) where

import Control.Monad (forM_)
import Data.ByteString qualified as Bytes
import LibTmux.Id qualified as Id
import LibTmux.Internal.Command qualified as C
import LibTmux.Internal.TmuxText qualified as Label
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests = testGroup "typed mutation arguments"
  [ testCase "literal formats and final separators stay inside one operand" $ do
      window <- require (Id.parseWindowId "@7")
      C.compileMutation (C.RenameWindow window "#{pid};") @?=
        Right ["rename-window", "-t", "@7", "--", "#{a:35}{pid}\\;"]
      C.compileMutation (C.RenameWindow window "#(not-a-command)") @?=
        Right ["rename-window", "-t", "@7", "--", "#{a:35}(not-a-command)"]
      C.compileMutation (C.RenameWindow window "#[#{pid}];") @?=
        Right ["rename-window", "-t", "@7", "--", "#{a:35}[#{a:35}{pid}]\\;"]
      C.compileMutation (C.RenameWindow window "###[") @?=
        Right ["rename-window", "-t", "@7", "--", "#{a:35}#{a:35}#{a:35}["]
  , testCase "a trailing semicolon preserves every preceding backslash" $ do
      window <- require (Id.parseWindowId "@7")
      forM_ [(";", "\\;"), ("\\;", "\\\\;"), ("\\\\;", "\\\\\\;")] $ \(input, expected) ->
        C.compileMutation (C.RenameWindow window (Label.fromBytes input)) @?=
          Right ["rename-window", "-t", "@7", "--", expected]
  , testCase "exact entity targets and leading dashes retain their argument roles" $ do
      session <- require (Id.parseSessionId "$9")
      pane <- require (Id.parsePaneId "%3")
      C.compileMutation (C.RenameSession session "-t") @?=
        Right ["rename-session", "-t", "$9", "--", "-t"]
      C.compileMutation (C.SetPaneTitle pane "-t") @?=
        Right ["select-pane", "-t", "%3", "-T", "-t"]
  , testCase "text uses UTF8 while window labels retain non-text bytes" $ do
      session <- require (Id.parseSessionId "$9")
      window <- require (Id.parseWindowId "@7")
      C.compileMutation (C.RenameSession session "λ") @?=
        Right ["rename-session", "-t", "$9", "--", Bytes.pack [206, 187]]
      let raw = Bytes.pack [120, 255, 128]
      C.compileMutation (C.RenameWindow window (Label.fromBytes raw)) @?=
        Right ["rename-window", "-t", "@7", "--", raw]
  , testCase "empty values and native normalization remain native policy" $ do
      session <- require (Id.parseSessionId "$9")
      C.compileMutation (C.RenameSession session "") @?=
        Right ["rename-session", "-t", "$9", "--", ""]
      C.compileMutation (C.RenameSession session "name.with:punctuation") @?=
        Right ["rename-session", "-t", "$9", "--", "name.with:punctuation"]
  , testCase "NUL refusals retain the authoritative field identity" $ do
      session <- require (Id.parseSessionId "$9")
      window <- require (Id.parseWindowId "@7")
      pane <- require (Id.parsePaneId "%3")
      C.compileMutation (C.RenameSession session "x\NULy") @?= Left (C.NulOperand "session.name")
      C.compileMutation (C.RenameWindow window (Label.fromBytes "x\NULy")) @?= Left (C.NulOperand "window.name")
      C.compileMutation (C.SetPaneTitle pane "x\NULy") @?= Left (C.NulOperand "pane.title")
  , testCase "the encoded limit counts terminators, hash expansions and the final escape" $ do
      window <- require (Id.parseWindowId "@7")
      let compile bytes = C.compileMutation (C.RenameWindow window (Label.fromBytes bytes))
      fmap (map Bytes.length) (compile (Bytes.replicate 65512 120)) @?= Right [13, 2, 2, 2, 65512]
      compile (Bytes.replicate 65513 120) @?= Left (C.EncodedCommandTooLarge "window.name")
      fmap (map Bytes.length) (compile (Bytes.replicate 9358 35)) @?= Right [13, 2, 2, 2, 65506]
      compile (Bytes.replicate 9359 35) @?= Left (C.EncodedCommandTooLarge "window.name")
      fmap (map Bytes.length) (compile (Bytes.replicate 9358 35 <> "xxxx;")) @?= Right [13, 2, 2, 2, 65512]
      compile (Bytes.replicate 9358 35 <> "xxxxx;") @?= Left (C.EncodedCommandTooLarge "window.name")
      compile (Bytes.replicate 65511 120 <> ";") @?= Left (C.EncodedCommandTooLarge "window.name")

  , testCase "closed control replies separate primary and following failures" $ do
      let begin = "%begin 1794000000 27 0\n"
          ended = "%end 1794000000 27 0\n"
          failed = "%error 1794000000 27 0\n"
          footer = "%exit\n"
          diagnostic = Bytes.pack [255, 10]
          hook = "%begin 1794000000 28 0\nhook failure\n%error 1794000000 28 0\n"
      C.decodeControlReply (Just 0) (begin <> ended <> footer) "" @?= Right C.Applied
      C.decodeControlReply (Just 1) (begin <> diagnostic <> failed <> footer) "" @?= Right (C.Rejected diagnostic)
      C.decodeControlReply (Just 1) (begin <> ended <> hook <> footer) "" @?= Right (C.AppliedWithErrors hook)
  , testCase "control-shaped hook and error bytes remain data" $ do
      let begin = "%begin 1794000000 27 0\n"
          ended = "%end 1794000000 27 0\n"
          failed = "%error 1794000000 27 0\n"
          noise = "%begin 0 0 1\n%error 0 0 1\n%exit\n"
          diagnostic = "invalid name:\n" <> ended
      C.decodeControlReply (Just 0) (begin <> ended <> noise <> "%exit\n") "" @?= Right C.Applied
      C.decodeControlReply (Just 1) (begin <> diagnostic <> failed <> "%exit\n") "" @?= Right (C.Rejected diagnostic)
  , testCase "truncated, mismatched and abnormal control replies stay uncertain" $ do
      let begin = "%begin 1794000000 27 0\n"
          ended = "%end 1794000000 27 0\n"
          valid = begin <> ended <> "%exit\n"
          reject = Left C.UnexpectedReply
      forM_ ["", "%exit\n", begin, begin <> ended, valid <> "\n", "noise\n" <> valid,
             begin <> "%end 1794000000 28 0\n%exit\n",
             begin <> ended <> "%exit terminated\n",
             begin <> "invalid\n%error 1794000000 28 0\n%exit\n"] $ \output ->
        C.decodeControlReply (Just 0) output "" @?= reject
      C.decodeControlReply Nothing valid "" @?= reject
      C.decodeControlReply (Just 2) valid "" @?= reject
      C.decodeControlReply (Just 1) valid "" @?= reject
      C.decodeControlReply (Just 0) valid "unexpected stderr" @?= reject
  , testCase "native guard numbers have canonical bounded domains" $ do
      forM_ ["0 0 0", "9223372036854775807 4294967295 0"] $ \guard ->
        C.decodeControlReply (Just 0) ("%begin " <> guard <> "\n%end " <> guard <> "\n%exit\n") "" @?= Right C.Applied
      forM_ ["01 1 0", "1 01 0", "-1 1 0", "1 1 1", "1  1 0", "1\t1 0",
             "9223372036854775808 1 0", "1 4294967296 0"] $ \guard ->
        C.decodeControlReply (Just 0) ("%begin " <> guard <> "\n%end " <> guard <> "\n%exit\n") "" @?= Left C.UnexpectedReply
  , testCase "the control decoder enforces both native stream bounds" $ do
      let oversized = Bytes.replicate (1048576 + 1) 120
      C.decodeControlReply (Just 0) oversized "" @?= Left C.ReplyTooLarge
      C.decodeControlReply (Just 1) "" oversized @?= Left C.ReplyTooLarge
  ]

require :: Show e => Either e a -> IO a
require = either (fail . show) pure
