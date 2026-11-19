-- | Incremental decoder for control replies and unsolicited lines.
-- Reply bodies are consumed without retaining them. A line from inside a
-- reply cannot become a notification just because it starts with a percent.
module LibTmux.Internal.ControlFrames
  ( Decoder, newDecoder, feed, endOfInput, maxLineBytes
  , ControlFrame (..), ReplyDisposition (..), DecodeError (..)
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import LibTmux.Internal.Frame (isControlStamp)

data ReplyDisposition = ReplySucceeded | ReplyRejected
  deriving stock (Eq, Show)

data ControlFrame
  = Reply !ReplyDisposition !ByteString
  | Notification !ByteString
  | Unframed !ByteString
  | Exit !ByteString
  deriving stock (Eq, Show)

data DecodeError
  = InvalidGuard
  | UnexpectedGuard
  | IncompleteLine
  | IncompleteReply
  | LineTooLong
  | DataAfterExit
  deriving stock (Eq, Show)

data Phase = Between | InReply !ByteString | Ended

data Decoder = Decoder !Phase !Int ![ByteString]

maxLineBytes :: Int
maxLineBytes = 65536

newDecoder :: Decoder
newDecoder = Decoder Between 0 []

feed :: Decoder -> ByteString -> Either DecodeError (Decoder, [ControlFrame])
feed decoder = scan decoder []
  where
    scan current result input | Bytes.null input = Right (current, reverse result)
    scan (Decoder Ended _ _) _ _ = Left DataAfterExit
    scan (Decoder phase count parts) result input =
      let (fragment, following) = Bytes.break (== 10) input
          lengthSoFar = count + Bytes.length fragment
      in if lengthSoFar > maxLineBytes
        then Left LineTooLong
        else case Bytes.uncons following of
          Nothing -> Right (Decoder phase lengthSoFar (Bytes.copy fragment : parts), reverse result)
          Just (_, rest) -> do
            let line = if null parts then fragment else Bytes.concat (reverse (fragment : parts))
            (next, event) <- processLine phase line
            scan (Decoder next 0 []) (maybe result (: result) event) rest

processLine :: Phase -> ByteString -> Either DecodeError (Phase, Maybe ControlFrame)
processLine (InReply stamp) line
  | line == "%end " <> stamp = Right (Between, Just (Reply ReplySucceeded stamp))
  | line == "%error " <> stamp = Right (Between, Just (Reply ReplyRejected stamp))
  | otherwise = Right (InReply stamp, Nothing)
processLine Between line
  | Just stamp <- Bytes.stripPrefix "%begin " line =
      if isControlStamp stamp then Right (InReply (Bytes.copy stamp), Nothing) else Left InvalidGuard
  | line == "%begin" = Left InvalidGuard
  | controlWord "%end" line || controlWord "%error" line = Left UnexpectedGuard
  | line == "%exit" = Right (Ended, Just (Exit ""))
  | Just reason <- Bytes.stripPrefix "%exit " line = Right (Ended, Just (Exit (Bytes.copy reason)))
  | "%" `Bytes.isPrefixOf` line = Right (Between, Just (Notification (Bytes.copy line)))
  | otherwise = Right (Between, Just (Unframed (Bytes.copy line)))
processLine Ended _ = Left DataAfterExit

controlWord :: ByteString -> ByteString -> Bool
controlWord token line = line == token || (token <> " ") `Bytes.isPrefixOf` line

endOfInput :: Decoder -> Either DecodeError ()
endOfInput (Decoder _ count _) | count /= 0 = Left IncompleteLine
endOfInput (Decoder (InReply _) _ _) = Left IncompleteReply
endOfInput _ = Right ()
