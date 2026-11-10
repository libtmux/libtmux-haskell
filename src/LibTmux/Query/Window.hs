-- | Physical window fields and relationships for "LibTmux.Query".
--
-- Fields describe the tmux 3.3a baseline. A physical t'Window' can have
-- several 'windowLinks'; its name and pane set are shared across them.
-- Window names use lossless t'TmuxText' because older supported tmux
-- releases can retain labels that are not valid UTF-8.
module LibTmux.Query.Window (id, name, width, height, panes, windowLinks) where

import Prelude ()
import LibTmux.Id (WindowId)
import LibTmux.Internal.Field qualified as F
import LibTmux.Internal.Query qualified as Q
import LibTmux.Query (Field, ToMany)
import LibTmux.Snapshot (Window, Pane, WindowLink, TmuxText)
import LibTmux.Value (Dimension)

-- | Native physical window ID, independent of a session's link index.
id :: Field Window WindowId
id = F.WindowId

-- | Lossless window label. Equality and ordering compare its retained bytes.
name :: Field Window TmuxText
name = F.WindowName

-- | Positive physical window width in cells.
width :: Field Window Dimension
width = F.WindowWidth

-- | Positive physical window height in cells.
height :: Field Window Dimension
height = F.WindowHeight

-- | Physical panes in this window, ordered by pane index.
panes :: ToMany Window Pane
panes = Q.WindowPanes

-- | All contextual appearances of this window across captured sessions.
windowLinks :: ToMany Window WindowLink
windowLinks = Q.WindowLinks
