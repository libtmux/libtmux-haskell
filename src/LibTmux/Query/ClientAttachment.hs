-- | Selected session, window and pane of a captured client.
--
-- Use with "LibTmux.Query" and "LibTmux.Query.Client". All tokens describe
-- the tmux 3.3a baseline. The selected t'PaneOccurrence' keeps the client's
-- actual window-link index rather than choosing another link to that window.
module LibTmux.Query.ClientAttachment
  ( sessionId, windowId, windowIndex, paneId, session, window, pane
  ) where

import LibTmux.Id (SessionId, WindowId, PaneId)
import LibTmux.Internal.Field qualified as F
import LibTmux.Internal.Query qualified as Q
import LibTmux.Query (Field, ToOne)
import LibTmux.Snapshot (ClientAttachment, Session, Window, PaneOccurrence)
import LibTmux.Value (WindowIndex)

-- | Native ID of the selected session.
sessionId :: Field ClientAttachment SessionId
sessionId = F.ClientSession

-- | Native ID of the selected physical window.
windowId :: Field ClientAttachment WindowId
windowId = F.ClientWindow

-- | Selected link index in the client's session.
windowIndex :: Field ClientAttachment WindowIndex
windowIndex = F.ClientWindowIndex

-- | Native ID of the selected physical pane.
paneId :: Field ClientAttachment PaneId
paneId = F.ClientPane

-- | Selected session observation, used with 'LibTmux.Query.related'.
session :: ToOne ClientAttachment Session
session = Q.AttachmentSession

-- | Selected physical window observation.
window :: ToOne ClientAttachment Window
window = Q.AttachmentWindow

-- | Selected pane in its actual session/index context.
pane :: ToOne ClientAttachment PaneOccurrence
pane = Q.AttachmentPane
