-- | Positive dimensions and nonnegative contextual indices.
--
-- Construction and access are pure. Window-link indices and pane indices
-- have distinct types; neither substitutes for an entity ID. A constructor
-- checks the mathematical domain, while command-specific limits belong at
-- the operation boundary. Use 'mkDimension', 'mkWindowIndex' and 'mkPaneIndex'
-- to validate input; their accessors return mathematical integers. Entity
-- identifiers belong to "LibTmux.Id".
--
-- >>> fmap dimensionValue (mkDimension 120)
-- Right 120
-- >>> mkDimension 0
-- Left (NonPositiveDimension 0)
module LibTmux.Value
  ( -- * Checked types
    Dimension
  , WindowIndex
  , PaneIndex
    -- * Validate input
  , ValueError (..)
  , mkDimension
  , mkWindowIndex
  , mkPaneIndex
    -- * Read numeric values
  , dimensionValue
  , windowIndexValue
  , paneIndexValue
  ) where

import Control.DeepSeq (NFData)

-- | Positive cells, constructed with 'mkDimension'. Command and field limits
-- are checked separately. Compare dimensions directly or use 'dimensionValue'
-- with an integer literal.
newtype Dimension = Dimension Integer
  deriving stock (Eq, Ord, Show)
  deriving newtype (NFData)

-- | Nonnegative index of a window link within a session, not a physical window ID.
-- Construct with 'mkWindowIndex'; read with 'windowIndexValue'.
newtype WindowIndex = WindowIndex Integer
  deriving stock (Eq, Ord, Show)
  deriving newtype (NFData)

-- | Nonnegative pane index within a window, not a pane ID.
-- Construct with 'mkPaneIndex'; read with 'paneIndexValue'.
newtype PaneIndex = PaneIndex Integer
  deriving stock (Eq, Ord, Show)
  deriving newtype (NFData)

-- | A scalar outside its mathematical domain.
data ValueError
  = NonPositiveDimension !Integer -- ^ The supplied dimension was zero or negative.
  | NegativeIndex !Integer -- ^ The supplied contextual index was negative.
  deriving stock (Eq, Show)

-- | Construct a positive dimension without applying a command-specific maximum.
mkDimension :: Integer -> Either ValueError Dimension
mkDimension value
  | value > 0 = Right (Dimension value)
  | otherwise = Left (NonPositiveDimension value)

-- | Construct a nonnegative window-link index.
mkWindowIndex :: Integer -> Either ValueError WindowIndex
mkWindowIndex value
  | value >= 0 = Right (WindowIndex value)
  | otherwise = Left (NegativeIndex value)

-- | Construct a nonnegative pane index.
mkPaneIndex :: Integer -> Either ValueError PaneIndex
mkPaneIndex value
  | value >= 0 = Right (PaneIndex value)
  | otherwise = Left (NegativeIndex value)

-- | Read a dimension as a mathematical integer, without narrowing conversion.
dimensionValue :: Dimension -> Integer
dimensionValue (Dimension value) = value

-- | Read a window-link index as a mathematical integer.
windowIndexValue :: WindowIndex -> Integer
windowIndexValue (WindowIndex value) = value

-- | Read a pane index as a mathematical integer.
paneIndexValue :: PaneIndex -> Integer
paneIndexValue (PaneIndex value) = value
