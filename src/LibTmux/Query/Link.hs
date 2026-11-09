-- | Fields and navigation for an observed session/index/window binding.
--
-- Use with "LibTmux.Query". All tokens belong to the tmux 3.3a baseline.
-- The same physical window can occur at several indices in one session;
-- t'WindowLink' retains each appearance. 'active' is contextual to the session.
module LibTmux.Query.Link (sessionId, windowId, index, active, session, window, panes) where

import LibTmux.Id (SessionId, WindowId)
import LibTmux.Internal.Field qualified as F
import LibTmux.Internal.Query qualified as Q
import LibTmux.Query (Field, ToMany, ToOne)
import LibTmux.Snapshot (WindowLink, Session, Window, Pane)
import LibTmux.Value (WindowIndex)

-- | Native ID of the session that owns this observed link.
sessionId :: Field WindowLink SessionId
sessionId = F.LinkSession

-- | Native ID of the shared physical window.
windowId :: Field WindowLink WindowId
windowId = F.LinkWindow

-- | Window-link index within the session; reindexing can change it.
index :: Field WindowLink WindowIndex
index = F.LinkIndex

-- | Whether this link is selected in its session.
active :: Field WindowLink Bool
active = F.LinkActive

-- | Resolve the session in the supplied snapshot with 'LibTmux.Query.related'.
session :: ToOne WindowLink Session
session = Q.LinkSession

-- | Resolve the shared physical window in the supplied snapshot.
window :: ToOne WindowLink Window
window = Q.LinkWindow

-- | Follow this link to its physical panes. One quantifier tests one child.
panes :: ToMany WindowLink Pane
panes = Q.LinkPanes
