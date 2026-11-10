-- | Owned tmux label bytes with explicit, fallible UTF-8 conversion.
--
-- 'fromBytes' copies its input, so retaining a label cannot retain a larger
-- transport buffer. 'decodeUtf8' reports invalid encoding without discarding
-- the bytes available through 'toBytes'. These operations perform no IO.
module LibTmux.Internal.TmuxText (TmuxText, fromBytes, toBytes, decodeUtf8) where

import Control.DeepSeq (NFData (rnf))
import Data.ByteString (ByteString)
import Data.ByteString.Short (ShortByteString)
import Data.ByteString.Short qualified as Short
import Data.String (IsString (fromString))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Utf8
import Data.Text.Encoding.Error (UnicodeException)

-- | A lossless reported label. Equality and ordering compare bytes.
-- String literals use UTF-8; byte constructors also admit non-text data.
-- Conversion functions are exposed in "LibTmux.Snapshot".
newtype TmuxText = TmuxText ShortByteString
  deriving stock (Eq, Ord, Show)

instance NFData TmuxText where
  rnf (TmuxText bytes) = rnf bytes

instance IsString TmuxText where
  fromString = fromBytes . Utf8.encodeUtf8 . Text.pack

-- | Copy reported bytes into an independently owned label without decoding.
fromBytes :: ByteString -> TmuxText
fromBytes = TmuxText . Short.toShort

-- | Return the exact reported bytes in a strict buffer.
toBytes :: TmuxText -> ByteString
toBytes (TmuxText bytes) = Short.fromShort bytes

-- | Decode as UTF-8; invalid bytes return 'UnicodeException' without replacement.
decodeUtf8 :: TmuxText -> Either UnicodeException Text
decodeUtf8 = Utf8.decodeUtf8' . toBytes
