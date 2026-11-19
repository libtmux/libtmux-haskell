module ControlFramesTest (tests) where

import Control.Monad (foldM, forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import LibTmux.Internal.ControlFrames
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "control reply framing"
  [ testCase "separates both native guard modes and keeps reply text out of notifications" $ do
      let stream = Bytes.concat
            [ "%begin 12 3 0\n%end 12 3 0\n"
            , "%session-changed $0 fixture\n"
            , "%begin 12 9 1\n%window-renamed @0 inside the reply\n%end 12 9 1\n"
            , "%window-renamed @0 from tmux\n%exit detached\n"
            ]
          expected =
            [ Reply ReplySucceeded "12 3 0"
            , Notification "%session-changed $0 fixture"
            , Reply ReplySucceeded "12 9 1"
            , Notification "%window-renamed @0 from tmux"
            , Exit "detached"
            ]
      forM_ [0 .. Bytes.length stream] $ \boundary ->
        let (beginning, end) = Bytes.splitAt boundary stream
        in decode [beginning, end] @?= Right expected
      decode (map Bytes.singleton (Bytes.unpack stream)) @?= Right expected
  , testCase "does not close a reply on a different stamp" $ do
      decode ["%begin 12 3 0\n%end 12 3 1\n%exit in the reply\n%error 12 3 0\n"]
        @?= Right [Reply ReplyRejected "12 3 0"]
  , testCase "reports invalid and unmatched guards" $ do
      decode ["%begin 12 03 0\n"] @?= Left InvalidGuard
      decode ["%end 12 3 0\n"] @?= Left UnexpectedGuard
  , testCase "reports a partial line or unfinished reply at EOF" $ do
      decode ["%window-renamed @0 un", "finished"] @?= Left IncompleteLine
      decode ["%begin 12 3 0\nreply data\n"] @?= Left IncompleteReply
  , testCase "bounds a line before waiting for its separator" $ do
      let line = Bytes.replicate maxLineBytes 97
      decode [line, "x"] @?= Left LineTooLong
      decode [line, "\n"] @?= Right [Unframed line]
  , testCase "a terminal record ends the protocol" $ do
      decode ["%exit\n%window-renamed @0 later\n"] @?= Left DataAfterExit
  ]

decode :: [ByteString] -> Either DecodeError [ControlFrame]
decode chunks = do
  (decoder, result) <- foldM step (newDecoder, []) chunks
  endOfInput decoder
  pure result
  where
    step (decoder, previous) bytes = do
      (next, frames) <- feed decoder bytes
      pure (next, previous <> frames)
