-- | Parse and order tmux release identities, and check the minimum release.
--
-- These functions consume supplied text. They neither execute @tmux -V@
-- nor contact a server. Admission is a floor: every release at or above
-- 3.3a passes, with no upper bound. Admission says nothing about which
-- releases the project has tested, and individual features still need
-- capability and conformance checks.
--
-- Use 'parseVersion' for input, 'requireSupported' for minimum-version
-- admission and 'renderVersion' for the spelling tmux reports.
--
-- >>> :set -XOverloadedStrings
-- >>> fmap renderVersion (parseVersion "tmux 3.3a\n" >>= requireSupported)
-- Right "3.3a"
--
-- Numeric components compare as numbers, and a patch letter follows its
-- release:
--
-- >>> (<) <$> parseVersion "3.9" <*> parseVersion "3.10"
-- Right True
-- >>> (<) <$> parseVersion "3.10" <*> parseVersion "3.10a"
-- Right True
--
-- A development build or release candidate ranks below the release it
-- precedes:
--
-- >>> (<) <$> parseVersion "next-3.10" <*> parseVersion "3.10-rc"
-- Right True
-- >>> (<) <$> parseVersion "3.10-rc2" <*> parseVersion "3.10"
-- Right True
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

import Control.DeepSeq (NFData (rnf))
import Control.Monad (guard)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Text.Read (readMaybe)

-- | A tmux release, release candidate or development build, constructed by
-- 'parseVersion' and rendered by 'renderVersion'. Ordering compares the numeric
-- components, then @next-X.Y < X.Y-rc < X.Y-rcN < X.Y < X.Ya@. Rendering
-- reproduces the accepted spelling, so @X.Y-rc@ and @X.Y-rc1@ are distinct.
data TmuxVersion = TmuxVersion !Integer !Integer !Stage
  deriving stock (Eq, Ord, Show)

instance NFData TmuxVersion where
  rnf (TmuxVersion major minor stage) = rnf major `seq` rnf minor `seq` rnf stage

-- | Position within one numeric release. Constructor order is ascending rank.
data Stage
  = Development -- ^ @next-X.Y@, the development line before @X.Y@.
  | Candidate !(Maybe Integer) -- ^ @X.Y-rc@ (the first candidate) or @X.Y-rcN@.
  | Release -- ^ @X.Y@.
  | Patch !Char -- ^ @X.Ya@, a lowercase patch letter.
  deriving stock (Eq, Ord, Show)

instance NFData Stage where
  rnf Development = ()
  rnf (Candidate number) = rnf number
  rnf Release = ()
  rnf (Patch letter) = rnf letter

-- | Invalid release syntax or a release below the supported minimum.
data VersionError
  = MalformedVersion !Text -- ^ Bounded copy of input that is not a tmux release identity.
  | UnsupportedVersion !TmuxVersion -- ^ A release older than 3.3a.
  deriving stock (Eq, Show)

-- | Parse a release identity or the output of @tmux -V@, allowing a leading
-- @tmux @ and one final LF. The accepted forms are @X.Y@, @X.Ya@, @X.Y-rc@,
-- @X.Y-rcN@ and @next-X.Y@. Unknown suffixes, including a bare @master@, are
-- rejected rather than assigned a guessed release. Diagnostics retain at most
-- 64 chars.
parseVersion :: Text -> Either VersionError TmuxVersion
parseVersion input
  | Text.length input > 64 = invalid
  | otherwise = maybe invalid Right parsed
  where
    invalid = Left (MalformedVersion (Text.copy (Text.take 64 input)))
    line = fromMaybe input (Text.stripSuffix "\n" input)
    body = fromMaybe line (Text.stripPrefix "tmux " line)
    parsed = case Text.stripPrefix "next-" body of
      Just core -> do
        (major, minor, rest) <- components core
        guard (Text.null rest)
        pure (TmuxVersion major minor Development)
      Nothing -> do
        (major, minor, rest) <- components body
        TmuxVersion major minor <$> stage rest

    components value = do
      let (majorText, rest) = Text.breakOn "." value
      afterDot <- Text.stripPrefix "." rest
      let (minorText, suffixText) = Text.span asciiDigit afterDot
      major <- number majorText
      minor <- number minorText
      pure (major, minor, suffixText)

    stage suffix = case Text.unpack suffix of
      [] -> Just Release
      [c] | c >= 'a' && c <= 'z' -> Just (Patch c)
      _ | Just digits <- Text.stripPrefix "-rc" suffix -> candidate digits
      _ -> Nothing

    candidate digits
      | Text.null digits = Just (Candidate Nothing)
      | otherwise = do
          count <- number digits
          guard (count > 0)
          pure (Candidate (Just count))

    number value = case Text.uncons value of
      Nothing -> Nothing
      Just ('0', remaining) | not (Text.null remaining) -> Nothing
      Just _ | Text.all asciiDigit value -> readMaybe (Text.unpack value)
      _ -> Nothing

    asciiDigit c = c >= '0' && c <= '9'

-- | Render the release as tmux spells it, without the executable name or
-- newline. Parsing the result returns an equal value.
renderVersion :: TmuxVersion -> Text
renderVersion (TmuxVersion major minor stage) = case stage of
  Development -> "next-" <> numbers
  Candidate count -> numbers <> "-rc" <> maybe "" (Text.pack . show) count
  Release -> numbers
  Patch letter -> numbers <> Text.singleton letter
  where
    numbers = Text.pack (show major <> "." <> show minor)

-- | Admit every release at or above 3.3a, including intermediate releases,
-- newer releases and the development builds and candidates ranked above it.
-- Plain 3.3 and older releases fail. The check has no upper bound, so passing
-- it does not mean the project tested that release. Individual features need
-- their own capability checks; passing this check does not qualify an entire
-- release.
requireSupported :: TmuxVersion -> Either VersionError TmuxVersion
requireSupported version
  | version < TmuxVersion 3 3 (Patch 'a') = Left (UnsupportedVersion version)
  | otherwise = Right version
