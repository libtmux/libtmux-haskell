-- | Parse stable tmux releases and check the supported release range.
--
-- These functions consume supplied text. They neither execute @tmux -V@
-- nor contact a server. Admission checks the inclusive 3.3a through 3.8 range;
-- individual features still need capability and conformance checks.
--
-- Use 'parseVersion' for input, 'requireSupported' for supported-range
-- admission and 'renderVersion' for canonical output.
--
-- >>> :set -XOverloadedStrings
-- >>> fmap renderVersion (parseVersion "tmux 3.3a\n" >>= requireSupported)
-- Right "3.3a"
module LibTmux.Version
  ( -- * Release identity and errors
    TmuxVersion
  , VersionError (..)
    -- * Parse and render
  , parseVersion
  , renderVersion
    -- * Admit a release
  , requireSupported
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Text.Read (readMaybe)

-- | A stable release, constructed by 'parseVersion' and rendered by
-- 'renderVersion'. Ordering compares numeric components before the patch letter.
data TmuxVersion = TmuxVersion !Integer !Integer !(Maybe Char)
  deriving stock (Eq, Ord, Show)

-- | Invalid release syntax or a release outside the supported range.
data VersionError
  = MalformedVersion !Text -- ^ Bounded copy of input that is not a stable release.
  | UnsupportedVersion !TmuxVersion -- ^ A stable release outside 3.3a through 3.8.
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

-- | Admit every stable release from 3.3a through 3.8, including intermediate
-- releases. Versions outside that range fail. Individual features need their own
-- capability checks; passing this check does not qualify an entire release.
requireSupported :: TmuxVersion -> Either VersionError TmuxVersion
requireSupported version
  | version < TmuxVersion 3 3 (Just 'a') || version > TmuxVersion 3 8 Nothing = Left (UnsupportedVersion version)
  | otherwise = Right version
