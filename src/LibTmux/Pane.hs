-- | Pane capture settings and paste newline policy.
module LibTmux.Pane
  ( PaneCaptureOptions (..), defaultPaneCapture
  , PaneRows (..), PaneRendering (..), PasteNewlines (..)
  ) where

-- | A visible screen or an inclusive range relative to the first visible row.
-- Negative offsets address history. tmux clamps the endpoints to its retained
-- rows. Offset zero is the first visible row. Use ordered offsets from
-- -2147483647 through 32767.
data PaneRows
  = VisibleRows
  | RowsBetween !Int !Int
  deriving stock (Eq, Show)

-- | Capture plain Unicode or retain tmux's ANSI rendition of the cells.
data PaneRendering = PlainText | AnsiStyled
  deriving stock (Eq, Show)

-- | Limits apply to the UTF-8 bytes before conversion to text. The transport
-- also bounds the complete response, including framing and hook output.
data PaneCaptureOptions = PaneCaptureOptions
  { rows :: !PaneRows
  , rendering :: !PaneRendering
  , byteLimit :: !Int -- ^ Positive byte limit, up to 1 MiB.
  }
  deriving stock (Eq, Show)

-- | The visible rows in plain Unicode with a 64 KiB limit.
defaultPaneCapture :: PaneCaptureOptions
defaultPaneCapture = PaneCaptureOptions VisibleRows PlainText 65536

-- | Choose how a named buffer's line feeds reach the target pane. Other
-- bytes are preserved when tmux delivers the paste to the pane.
data PasteNewlines = PreserveLineFeeds | LineFeedsToCarriageReturns
  deriving stock (Eq, Show)
