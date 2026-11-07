-- | tmux release identity and the minimum supported release.
module LibTmux.Version
  ( TmuxVersion
  , VersionError (..)
  , parseVersion
  , renderVersion
  , requireSupported
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Text.Read (readMaybe)

-- | A stable release. Ordering compares numeric components before the patch letter.
data TmuxVersion = TmuxVersion !Integer !Integer !(Maybe Char)
  deriving stock (Eq, Ord, Show)

-- | Invalid release syntax or a release below the supported floor.
data VersionError
  = MalformedVersion !Text
  | UnsupportedVersion !TmuxVersion
  deriving stock (Eq, Show)

-- | Parse a stable release or the output of @tmux -V@, allowing one final LF.
-- Development builds and trailing data are rejected rather than assigned
-- capabilities from a guessed stable version. Diagnostics retain at most 64 chars.
parseVersion :: Text -> Either VersionError TmuxVersion
parseVersion input
  | Text.length input > 64 = invalid
  | otherwise = maybe invalid Right parsed
  where
    invalid = Left (MalformedVersion (Text.copy (Text.take 64 input)))
    line = fromMaybe input (Text.stripSuffix "\n" input)
    body = fromMaybe line (Text.stripPrefix "tmux " line)
    parsed = do
      let (majorText, rest) = Text.breakOn "." body
      afterDot <- Text.stripPrefix "." rest
      let (minorText, suffixText) = Text.span asciiDigit afterDot
      major <- number majorText
      minor <- number minorText
      suffix <- case Text.unpack suffixText of
        [] -> Just Nothing
        [c] | c >= 'a' && c <= 'z' -> Just (Just c)
        _ -> Nothing
      pure (TmuxVersion major minor suffix)

    number value = case Text.uncons value of
      Nothing -> Nothing
      Just ('0', remaining) | not (Text.null remaining) -> Nothing
      Just _ | Text.all asciiDigit value -> readMaybe (Text.unpack value)
      _ -> Nothing

    asciiDigit c = c >= '0' && c <= '9'

-- | Render the canonical release without the executable name or newline.
renderVersion :: TmuxVersion -> Text
renderVersion (TmuxVersion major minor suffix) =
  Text.pack (show major <> "." <> show minor <> maybe "" (: []) suffix)

-- | Reject releases older than plain 3.3. Individual features need their own
-- capability checks; passing this check does not qualify an entire release.
requireSupported :: TmuxVersion -> Either VersionError TmuxVersion
requireSupported version
  | version < TmuxVersion 3 3 Nothing = Left (UnsupportedVersion version)
  | otherwise = Right version
