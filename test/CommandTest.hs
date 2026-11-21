module CommandTest (tests) where

import Control.Monad (forM_)
import Data.ByteString qualified as Bytes
import LibTmux.Id qualified as Id
import LibTmux.Internal.Command qualified as C
import LibTmux.Internal.Frame qualified as Frame
import LibTmux.Internal.TmuxText qualified as Label
import LibTmux.Pane qualified as Pane
import LibTmux.Value qualified as Value
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests = testGroup "typed mutation arguments"
  [ testCase "absolute resizes retain exact targets and requested axes" $ do
      pane <- require (Id.parsePaneId "%3")
      window <- require (Id.parseWindowId "@7")
      width <- require (Value.mkDimension 100)
      height <- require (Value.mkDimension 40)
      forM_ [(Value.ResizeWidth width, ["-x", "100"]),
             (Value.ResizeHeight height, ["-y", "40"]),
             (Value.ResizeBoth width height, ["-x", "100", "-y", "40"])] $ \(size, arguments) -> do
        C.compileMutation (C.ResizePane pane size) @?= Right (["resize-pane", "-t", "%3"] <> arguments)
        C.compileMutation (C.ResizeWindow window size) @?= Right (["resize-window", "-t", "@7"] <> arguments)
  , testCase "resize validates every axis against the shared native bound" $ do
      pane <- require (Id.parsePaneId "%3")
      window <- require (Id.parseWindowId "@7")
      small <- require (Value.mkDimension 50)
      largest <- require (Value.mkDimension 10000)
      forM_ [10001, 2147483648, 10 ^ (100 :: Int)] $ \number -> do
        large <- require (Value.mkDimension number)
        forM_ [(C.ResizePane pane (Value.ResizeWidth large), "pane.width"),
               (C.ResizePane pane (Value.ResizeHeight large), "pane.height"),
               (C.ResizePane pane (Value.ResizeBoth small large), "pane.height"),
               (C.ResizeWindow window (Value.ResizeWidth large), "window.width"),
               (C.ResizeWindow window (Value.ResizeHeight large), "window.height"),
               (C.ResizeWindow window (Value.ResizeBoth large small), "window.width")] $ \(request, field) ->
          C.compileMutation request @?= Left (C.InvalidOperand field "dimension exceeds 10000 cells")
      C.compileMutation (C.ResizeWindow window (Value.ResizeBoth largest largest)) @?=
        Right ["resize-window", "-t", "@7", "-x", "10000", "-y", "10000"]
  , testCase "literal formats and final separators stay inside one operand" $ do
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
      let compile bytes = map Bytes.length <$> C.compileMutation (C.RenameWindow window (Label.fromBytes bytes))
      compile (Bytes.replicate 16340 120) @?= Right [13, 2, 2, 2, 16340]
      compile (Bytes.replicate 16341 120) @?= Left (C.EncodedCommandTooLarge "window.name")
      compile (Bytes.replicate 2334 35) @?= Right [13, 2, 2, 2, 16338]
      compile (Bytes.replicate 2335 35) @?= Left (C.EncodedCommandTooLarge "window.name")
      compile (Bytes.replicate 2334 35 <> ";") @?= Right [13, 2, 2, 2, 16340]
      compile (Bytes.replicate 2334 35 <> "x;") @?= Left (C.EncodedCommandTooLarge "window.name")
      compile (Bytes.replicate 16339 120 <> ";") @?= Left (C.EncodedCommandTooLarge "window.name")

  , testCase "pane capture refuses offsets tmux cannot represent safely" $ do
      pane <- require (Id.parsePaneId "%5")
      let compile first lastRow = C.compilePaneCapture pane
            Pane.defaultPaneCapture {Pane.rows = Pane.RowsBetween first lastRow}
          refused = Left (C.InvalidOperand "pane.capture.rows" "expected ordered offsets from -2147483647 through 32767")
      compile (-2147483648) 0 @?= refused
      compile 0 32768 @?= refused
      compile 1 0 @?= refused
      compile (-2147483647) 32767 @?=
        Right ["capture-pane", "-p", "-t", "%5", "-S", "-2147483647", "-E", "32767"]
  , testCase "pane capture keeps its primary bytes and refuses ambiguous boundaries" $ do
      let begin = "%begin 1794000000 27 0\n"
          ended = "%end 1794000000 27 0\n"
          failed = "%error 1794000000 27 0\n"
          footer = "%exit\n"
          payload = "caf\ESC[31m" <> Bytes.pack [195, 169] <> "\n\n%end 12 34 0\n\n"
          hook = "%begin 1794000000 28 0\nhook output\n%end 1794000000 28 0\n"
          decode limit body = C.decodeControlData limit (Just 0) (begin <> body <> footer) ""
      decode 64 (payload <> ended <> hook) @?= Right (C.ControlData payload)
      decode 4 (payload <> ended) @?= Right C.ControlDataExceedsLimit
      decode 128 (ended <> payload <> ended) @?= Left C.UnexpectedReply
      decode 128 (failed <> payload <> ended) @?= Left C.UnexpectedReply
      C.decodeControlData 64 (Just 1) (begin <> "can't find pane: %5\n" <> failed <> footer) ""
        @?= Right (C.ControlDataRejected "can't find pane: %5\n")
      C.decodeControlData 64 (Just 0) (begin <> payload <> ended) ""
        @?= Left C.UnexpectedReply

  , testCase "a failed capture hook leaves a known native outcome" $ do
      let primary = "%begin 1794000000 27 0\nREADY\n%end 1794000000 27 0\n"
          failedHook = "%begin 1794000000 28 0\ndelay invalid\n%error 1794000000 28 0\n"
      C.decodeControlData 64 (Just 1) (primary <> failedHook <> "%exit\n") ""
        @?= Right (C.ControlDataHookFailed failedHook)
      C.decodeControlData 64 (Just 1) (primary <> "%exit\n") "" @?= Left C.UnexpectedReply
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
  , testCase "legacy client retire messages can follow the native exit" $ do
      let begin = "%begin 1794000000 27 0\n"
          ended = "%end 1794000000 27 0\n"
          tailNotice = "%exit\n%client-detached client-446254\n"
      C.decodeControlReply (Just 0) (begin <> ended <> tailNotice) "" @?= Right C.Applied
      C.decodeControlData 128 (Just 0) (begin <> tailNotice <> ended <> tailNotice) ""
        @?= Right (C.ControlData tailNotice)
      C.decodeControlReply (Just 0) (begin <> ended <> tailNotice <> "%error 42 1 0\n") ""
        @?= Left C.UnexpectedReply
      C.decodeControlReply (Just 0) (begin <> ended <> "%exit\n%client-detached \n") ""
        @?= Left C.UnexpectedReply
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
  , testCase "pane relocation never treats following output as primary evidence" $ do
      nonce <- require (Frame.parseNonce (Bytes.replicate 64 97))
      let guards = "%begin 1 1 0\n%end 1 1 0\n%begin 1 2 0\n%end 1 2 0\n"
          begin = "%begin 1 3 0\n"
          rejected = "%error 1 3 0\n"
          ended = "%end 1 3 0\n"
          printed = Frame.scalarFormat nonce "123 $1 @9 %5 7" <> "\n"
          following = "%begin 1 4 0\n" <> printed <> "%end 1 4 0\n"
          wire = C.BreakWire False
          prefix = guards <> begin
          decode status bytes = C.decodeRelocationReply wire nonce (Just status) (bytes <> "%exit\n") ""
          evidence = C.relocationEvidence wire nonce
      decode 0 guards @?= Right C.RelocationRefused
      decode 1 (prefix <> "index in use\n" <> rejected <> following) @?=
        Right (C.RelocationRejected "index in use\n")
      evidence (prefix <> "index in use\n" <> rejected <> following) @?= Nothing
      evidence (prefix <> ended <> following) @?= Just (C.RelocationAccepted Nothing)
      case evidence (prefix <> printed) of
        Just (C.RelocationPrinted receipt) ->
          decode 0 (prefix <> printed <> ended) @?=
            Right (C.RelocationCompleted (C.RelocationAccepted (Just receipt)))
        other -> assertFailure ("expected the unclosed printed receipt, got " <> show other)
  ]

require :: Show e => Either e a -> IO a
require = either (fail . show) pure
