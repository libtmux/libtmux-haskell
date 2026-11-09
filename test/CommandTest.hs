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
        Right ["rename-window", "-t", "@7", "--", "##{pid}\\;"]
      C.compileMutation (C.RenameWindow window "#(not-a-command)") @?=
        Right ["rename-window", "-t", "@7", "--", "##(not-a-command)"]
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
  , testCase "the encoded limit counts terminators, doubled hashes and the final escape" $ do
      window <- require (Id.parseWindowId "@7")
      let compile bytes = C.compileMutation (C.RenameWindow window (Label.fromBytes bytes))
      fmap (map Bytes.length) (compile (Bytes.replicate 65512 120)) @?= Right [13, 2, 2, 2, 65512]
      compile (Bytes.replicate 65513 120) @?= Left (C.EncodedCommandTooLarge "window.name")
      fmap (map Bytes.length) (compile (Bytes.replicate 32756 35)) @?= Right [13, 2, 2, 2, 65512]
      compile (Bytes.replicate 32757 35) @?= Left (C.EncodedCommandTooLarge "window.name")
      compile (Bytes.replicate 65511 120 <> ";") @?= Left (C.EncodedCommandTooLarge "window.name")
  ]

require :: Show e => Either e a -> IO a
require = either (fail . show) pure
