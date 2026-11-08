-- | Nonce boundaries and lossless scalar bytes for tmux format output.
--
-- 'escapedFieldFormat' protects literal backslashes before releases that
-- apply vis escaping print the value. 'decodeEscapedScalar' validates both
-- framing and decoded bounds. Numeric-only formats may use 'decodeScalar'.
module LibTmux.Internal.Frame
  ( Nonce
  , FrameError (..)
  , parseNonce
  , scalarFormat
  , escapedFieldFormat
  , recordMarker
  , escapedRecordFieldFormat
  , decodeEscapedRecordField
  , decodeScalar
  , decodeEscapedScalar
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.Word (Word8)

newtype Nonce = Nonce ByteString
  deriving stock (Eq, Show)

data FrameError
  = InvalidNonce
  | InvalidScalarLimit
  | ScalarLimitExceeded !Int !Int
  | UnexpectedScalarFrame
  | AmbiguousScalarFrame
  | NulInScalar
  | InvalidScalarEscape !Int
  | ReservedRecordByte
  deriving stock (Eq, Show)

parseNonce :: ByteString -> Either FrameError Nonce
parseNonce bytes
  | Bytes.length bytes == 64 && Bytes.all hex bytes = Right (Nonce (Bytes.copy bytes))
  | otherwise = Left InvalidNonce
  where
    hex byte = (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)

scalarFormat :: Nonce -> ByteString -> ByteString
scalarFormat (Nonce token) field = token <> ":" <> field <> ":" <> token

-- | Expand a catalogue variable once, doubling its literal backslashes.
-- The argument is a trusted variable name, without @#{...}@ delimiters.
escapedFieldFormat :: ByteString -> ByteString
escapedFieldFormat field = "#{s/\\\\/\\\\\\\\/:" <> field <> "}"

-- | A record boundary whose initial @g@ is absent from encoded field bytes.
recordMarker :: Nonce -> ByteString
recordMarker (Nonce token) = "g" <> token

-- | Look up a trusted variable once, protecting slashes before escaping @g@.
-- Encoded values contain no literal @g@, so cannot contain a 'recordMarker'.
escapedRecordFieldFormat :: ByteString -> ByteString
escapedRecordFieldFormat field = "#{s/\\\\/\\\\\\\\/;s/g/\\\\147/:" <> field <> "}"

-- | Decode a record field after its exact tagged boundaries were consumed.
-- An unescaped @g@ signals a producer/encoding mismatch, even without a nonce.
decodeEscapedRecordField :: Nonce -> Int -> ByteString -> Either FrameError ByteString
decodeEscapedRecordField nonce@(Nonce token) limit payload
  | limit < 0 = Left InvalidScalarLimit
  | Bytes.elem 103 payload = Left ReservedRecordByte
  | token `Bytes.isInfixOf` payload = Left AmbiguousScalarFrame
  | otherwise = decodeEscapedPayload nonce limit payload

-- | Decode protected backslashes and tmux's octal, C-style and dollar escapes.
-- Limits apply to decoded bytes; the process owner separately bounds stdout.
-- Validate before allocation so an escaped payload needs only its output-sized
-- buffer. The second traversal reads the same immutable validated bytes.
decodeEscapedScalar :: Nonce -> Int -> ByteString -> Either FrameError ByteString
decodeEscapedScalar nonce limit output
  | limit < 0 = Left InvalidScalarLimit
  | otherwise = do
      payload <- framePayload nonce maxBound output
      decodeEscapedPayload nonce limit payload

decodeEscapedPayload :: Nonce -> Int -> ByteString -> Either FrameError ByteString
decodeEscapedPayload (Nonce token) limit payload = do
  let next rest = scalarByte (Bytes.length payload - Bytes.length rest) rest
      measure !count rest = next rest >>= \case
        Nothing -> Right count
        Just (_, remaining) -> measure (count + 1) remaining
  count <- measure 0 payload
  if count > limit then Left (ScalarLimitExceeded limit count) else do
    let (decoded, remaining) = Bytes.unfoldrN count (either (const Nothing) id . next) payload
    if Bytes.length decoded /= count || maybe False (not . Bytes.null) remaining
      then Left UnexpectedScalarFrame
      else if token `Bytes.isInfixOf` decoded
        then Left AmbiguousScalarFrame
        else Right decoded

scalarByte :: Int -> ByteString -> Either FrameError (Maybe (Word8, ByteString))
scalarByte offset input = case Bytes.uncons input of
  Nothing -> Right Nothing
  Just (0, _) -> Left NulInScalar
  Just (92, rest) -> case Bytes.uncons rest of
    Just (digit, tailBytes)
      | digit >= 48 && digit <= 55 -> case Bytes.unpack (Bytes.take 3 rest) of
          [a, b, c] | a <= 51 && octal b && octal c ->
            let value = (a - 48) * 64 + (b - 48) * 8 + (c - 48)
            in if value == 0 then Left NulInScalar else Right (Just (value, Bytes.drop 3 rest))
          _ -> bad
      | otherwise -> case lookup digit escapes of
          Just value -> Right (Just (value, tailBytes))
          Nothing -> bad
    Nothing -> bad
  Just value -> Right (Just value)
  where
    octal byte = byte >= 48 && byte <= 55
    bad = Left (InvalidScalarEscape offset)
    escapes = [(92, 92), (36, 36), (110, 10), (114, 13), (116, 9),
      (97, 7), (98, 8), (118, 11), (102, 12), (115, 32)]

decodeScalar :: Nonce -> Int -> ByteString -> Either FrameError ByteString
decodeScalar nonce limit output = Bytes.copy <$> framePayload nonce limit output

framePayload :: Nonce -> Int -> ByteString -> Either FrameError ByteString
framePayload (Nonce token) limit output
  | limit < 0 = Left InvalidScalarLimit
  | payloadLength > limit = Left (ScalarLimitExceeded limit payloadLength)
  | otherwise = do
      rest <- maybe (Left UnexpectedScalarFrame) Right (Bytes.stripPrefix prefix output)
      -- Consume boundaries sequentially so they cannot overlap on an empty payload.
      payload <- maybe (Left UnexpectedScalarFrame) Right (Bytes.stripSuffix suffix rest)
      if token `Bytes.isInfixOf` payload
        then Left AmbiguousScalarFrame
        else if Bytes.elem 0 payload
          then Left NulInScalar
          else Right payload
  where
    prefix = token <> ":"
    suffix = ":" <> token <> "\n"
    payloadLength = Bytes.length output - Bytes.length prefix - Bytes.length suffix
