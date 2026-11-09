module CommandTest (tests) where

import Control.Monad (forM_)
import Data.ByteString qualified as Bytes
import LibTmux.Id qualified as Id
import LibTmux.Internal.Command qualified as C
import LibTmux.Internal.Frame qualified as F
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
  , testCase "command files quote operand bytes and keep receipts in two groups" $ do
      window <- require (Id.parseWindowId "@7")
      nonce <- require (F.parseNonce (Bytes.replicate 64 97))
      source <- require (C.compileScript nonce (C.RenameWindow window "x\"$;\n#[#{pid}]"))
      Bytes.count 10 source @?= 2
      Bytes.elem 0 source @?= False
      Bytes.isInfixOf "\\170\\042\\044\\073\\012" source @?= True
      Bytes.isInfixOf "#{pid}" source @?= False
      Bytes.isSuffixOf ("display-message -p -F " <> F.scalarFormat nonce "finished" <> "\n") source @?= True
  , testCase "command-file limits include quoting, format expansion and both receipts" $ do
      window <- require (Id.parseWindowId "@7")
      nonce <- require (F.parseNonce (Bytes.replicate 64 97))
      let compile bytes = C.compileScript nonce (C.RenameWindow window (Label.fromBytes bytes))
      baseline <- Bytes.length <$> require (compile "")
      let maximumPlain = (65536 - baseline) `div` 4
          maximumHash = (65536 - baseline) `div` 28
      fmap Bytes.length (compile (Bytes.replicate maximumPlain 120)) @?= Right (baseline + 4 * maximumPlain)
      compile (Bytes.replicate (maximumPlain + 1) 120) @?= Left (C.EncodedCommandTooLarge "window.name")
      fmap Bytes.length (compile (Bytes.replicate maximumHash 35)) @?= Right (baseline + 28 * maximumHash)
      compile (Bytes.replicate (maximumHash + 1) 35) @?= Left (C.EncodedCommandTooLarge "window.name")
      compile "x\NULy" @?= Left (C.NulOperand "window.name")
  , testCase "mutation replies distinguish primary rejection from failure after effects" $ do
      nonce <- require (F.parseNonce (Bytes.replicate 64 97))
      let applied = F.scalarFormat nonce "applied" <> "\n"
          finished = F.scalarFormat nonce "finished" <> "\n"
          diagnostic = Bytes.pack [255, 10]
      C.decodeReply nonce (Just 0) (applied <> finished) "" @?= Right C.Applied
      C.decodeReply nonce (Just 1) finished diagnostic @?= Right (C.Rejected diagnostic)
      C.decodeReply nonce (Just 1) (applied <> finished) diagnostic @?= Right (C.AppliedWithErrors diagnostic)
  , testCase "extra, truncated, foreign and inconsistent replies remain unknown" $ do
      nonce <- require (F.parseNonce (Bytes.replicate 64 97))
      other <- require (F.parseNonce (Bytes.replicate 64 98))
      let applied = F.scalarFormat nonce "applied" <> "\n"
          finished = F.scalarFormat nonce "finished" <> "\n"
          valid = applied <> finished
          reject = Left C.UnexpectedReply
      forM_ ["", applied, finished, valid <> "\n", "noise\n" <> valid,
             valid <> valid, "%end 1 2 0\n" <> valid,
             F.scalarFormat other "applied" <> "\n" <> finished] $ \output ->
        C.decodeReply nonce (Just 0) output "" @?= reject
      C.decodeReply nonce Nothing valid "" @?= reject
      C.decodeReply nonce (Just 2) valid "" @?= reject
      C.decodeReply nonce (Just 0) valid "unexpected diagnostic" @?= reject
      C.decodeReply nonce (Just 1) finished "" @?= reject
      C.decodeReply nonce (Just 1) applied "rejected" @?= reject
  , testCase "the pure reply decoder enforces both native stream bounds" $ do
      nonce <- require (F.parseNonce (Bytes.replicate 64 97))
      let oversized = Bytes.replicate (1048576 + 1) 120
          finished = F.scalarFormat nonce "finished" <> "\n"
      C.decodeReply nonce (Just 0) oversized "" @?= Left C.ReplyTooLarge
      C.decodeReply nonce (Just 1) finished oversized @?= Left C.ReplyTooLarge
  ]

require :: Show e => Either e a -> IO a
require = either (fail . show) pure
