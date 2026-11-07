module LibTmux.Internal.Frame
  ( Nonce
  , FrameError (..)
  , parseNonce
  , scalarFormat
  , decodeScalar
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes

newtype Nonce = Nonce ByteString
  deriving stock (Eq, Show)

data FrameError
  = InvalidNonce
  | InvalidScalarLimit
  | ScalarLimitExceeded !Int !Int
  | UnexpectedScalarFrame
  | AmbiguousScalarFrame
  | NulInScalar
  deriving stock (Eq, Show)

parseNonce :: ByteString -> Either FrameError Nonce
parseNonce bytes
  | Bytes.length bytes == 64 && Bytes.all hex bytes = Right (Nonce (Bytes.copy bytes))
  | otherwise = Left InvalidNonce
  where
    hex byte = (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)

scalarFormat :: Nonce -> ByteString -> ByteString
scalarFormat (Nonce token) field = token <> ":" <> field <> ":" <> token

decodeScalar :: Nonce -> Int -> ByteString -> Either FrameError ByteString
decodeScalar (Nonce token) limit output
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
          else Right (Bytes.copy payload)
  where
    prefix = token <> ":"
    suffix = ":" <> token <> "\n"
    payloadLength = Bytes.length output - Bytes.length prefix - Bytes.length suffix
