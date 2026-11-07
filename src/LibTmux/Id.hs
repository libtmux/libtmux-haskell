-- | Distinct session, physical-window and physical-pane IDs.
--
-- Parsing and rendering are pure. An ID carries no endpoint, server lifetime
-- or liveness evidence. Render an ID for external text; use its numeric
-- accessor when an application needs the mathematical value.
--
-- Start with 'parseSessionId', 'parseWindowId' or 'parsePaneId'. Each type's
-- documentation links its parser and renderer. Contextual numeric indices
-- belong to "LibTmux.Value".
--
-- >>> :set -XOverloadedStrings
-- >>> fmap renderWindowId (parseWindowId "@17")
-- Right "@17"
-- >>> either (const "rejected") renderPaneId (parsePaneId "@17")
-- "rejected"
module LibTmux.Id
  ( -- * Entity identities
    SessionId
  , WindowId
  , PaneId
    -- * Parse external values
  , IdError (..)
  , parseSessionId
  , parseWindowId
  , parsePaneId
    -- * Render target text
  , renderSessionId
  , renderWindowId
  , renderPaneId
    -- * Read numeric values
  , sessionIdValue
  , windowIdValue
  , paneIdValue
  ) where

import Control.DeepSeq (NFData)
import Control.Monad (guard)
import Data.Char (ord)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word32)

-- | A session's unsigned 32-bit tmux identifier, written with a @$@ prefix.
-- Parse with 'parseSessionId'; render with 'renderSessionId'.
newtype SessionId = SessionId Word32
  deriving stock (Eq, Ord, Show)
  deriving newtype (NFData)

-- | A physical window's identifier, independent of its session links.
-- Parse with 'parseWindowId'; render with 'renderWindowId'.
newtype WindowId = WindowId Word32
  deriving stock (Eq, Ord, Show)
  deriving newtype (NFData)

-- | A physical pane's identifier, written with a @%@ prefix.
-- Parse with 'parsePaneId'; render with 'renderPaneId'.
newtype PaneId = PaneId Word32
  deriving stock (Eq, Ord, Show)
  deriving newtype (NFData)

-- | Invalid canonical syntax, entity prefix or native unsigned range.
-- Diagnostics retain at most 64 characters of input.
data IdError = InvalidId
  { expectedPrefix :: !Char -- ^ Required entity prefix.
  , input :: !Text -- ^ Bounded copy of the invalid input.
  }
  deriving stock (Eq, Show)

-- | Parse @$0@ through @$4294967295@. No whitespace or leading zeroes.
parseSessionId :: Text -> Either IdError SessionId
parseSessionId = fmap SessionId . parseId '$'

-- | Parse a canonical @\@number@ identifying a physical window.
parseWindowId :: Text -> Either IdError WindowId
parseWindowId = fmap WindowId . parseId '@'

-- | Parse a canonical @%number@ identifying a physical pane.
parsePaneId :: Text -> Either IdError PaneId
parsePaneId = fmap PaneId . parseId '%'

-- | Render the session prefix and decimal ID.
renderSessionId :: SessionId -> Text
renderSessionId (SessionId value) = "$" <> Text.pack (show value)

-- | Render the physical window prefix and decimal ID.
renderWindowId :: WindowId -> Text
renderWindowId (WindowId value) = "@" <> Text.pack (show value)

-- | Render the physical pane prefix and decimal ID.
renderPaneId :: PaneId -> Text
renderPaneId (PaneId value) = "%" <> Text.pack (show value)

-- | Read the numeric session ID without narrowing conversion.
sessionIdValue :: SessionId -> Integer
sessionIdValue (SessionId value) = toInteger value

-- | Read the numeric physical window ID.
windowIdValue :: WindowId -> Integer
windowIdValue (WindowId value) = toInteger value

-- | Read the numeric physical pane ID.
paneIdValue :: PaneId -> Integer
paneIdValue (PaneId value) = toInteger value

parseId :: Char -> Text -> Either IdError Word32
parseId prefix input = maybe invalid Right parsed
  where
    invalid = Left (InvalidId prefix (Text.copy (Text.take 64 input)))
    parsed = do
      guard (Text.length input <= 11)
      (actual, digits) <- Text.uncons input
      guard (actual == prefix)
      (first, rest) <- Text.uncons digits
      guard (first /= '0' || Text.null rest)
      guard (Text.all (\c -> c >= '0' && c <= '9') digits)
      let value = Text.foldl' (\n c -> n * 10 + toInteger (ord c - ord '0')) 0 digits
      guard (value <= toInteger (maxBound @Word32))
      pure (fromInteger value)
