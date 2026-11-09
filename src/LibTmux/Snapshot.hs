-- | Detached tmux observations and pure navigation.
--
-- "LibTmux.Server" acquires a t'Snapshot' in IO. Every operation in this
-- module reads owned Haskell values, including after the Server closes.
-- Use ordinary lists, comprehensions and folds for application predicates.
--
-- t'Window' and t'Pane' are physical entities. A t'WindowLink' identifies an
-- observed session/index/window binding; t'PaneOccurrence' retains that
-- context. 'paneOccurrences' therefore preserves repeated appearances while
-- 'panes' lists each physical pane once.
--
-- References compare identity within one Server generation. A lookup reads
-- the supplied snapshot, including a newer snapshot from that same Server.
-- Independent Server scopes have different generations. Resolve an ID again
-- with 'lookupPaneId' when deliberately selecting a newly observed entity.
--
-- Observation fields are exported for record dot and local updates. Editing
-- a record does not change a snapshot's indexes or establish provenance.
module LibTmux.Snapshot
  ( -- * Complete observations
    Snapshot, ServerInfo (..)
  , serverInfo, captureInterval, CaptureInterval (..)
    -- * Physical and contextual values
  , Session (..), Window (..), Pane (..), WindowLink (..), PaneOccurrence (..)
  , Client (..), ClientAttachment (..)
    -- * Target identity
  , Generation, SessionRef, WindowRef, PaneRef
  , sessionId, windowId, paneId
    -- * Ordered sources
  , sessions, windows, panes, windowLinks, paneOccurrences, clients
    -- * Indexed navigation
  , LookupError (..), lookupSession, lookupWindow, lookupPane
  , linksForSession, panesForWindow
  , lookupSessionId, lookupWindowId, lookupPaneId
    -- * Lossless labels
  , TmuxText, labelFromBytes, labelBytes, labelText
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text.Encoding.Error (UnicodeException)
import LibTmux.Id (PaneId, SessionId, WindowId)
import LibTmux.Internal.Graph
  ( Snapshot, ServerInfo (..), CaptureInterval (..), captureInterval, serverInfo, clients
  , Session (..), Window (..), Pane (..), WindowLink (..), PaneOccurrence (..)
  , Client (..), ClientAttachment (..)
  , Generation, SessionRef, WindowRef, PaneRef, LookupError (..)
  )
import LibTmux.Internal.Graph qualified as G
import LibTmux.Internal.TmuxText (TmuxText)
import LibTmux.Internal.TmuxText qualified as Label

-- | Native session ID, without the reference's generation guarantee.
sessionId :: SessionRef -> SessionId
sessionId (G.SessionRef _ ident) = ident

-- | Native physical window ID. Window-link indices are separate values.
windowId :: WindowRef -> WindowId
windowId (G.WindowRef _ ident) = ident

-- | Native pane ID. Comparing IDs alone does not compare Server identity.
paneId :: PaneRef -> PaneId
paneId (G.PaneRef _ ident) = ident

-- | Physical sessions in numeric ID order.
sessions :: Snapshot -> [Session]
sessions = G.graphSessions . G.entities

-- | Physical windows in numeric ID order, independent of their links.
windows :: Snapshot -> [Window]
windows = G.graphWindows . G.entities

-- | Physical panes in numeric ID order. Use 'paneOccurrences' for link context.
panes :: Snapshot -> [Pane]
panes = G.graphPanes . G.entities

-- | Window appearances in session ID and window-index order.
windowLinks :: Snapshot -> [WindowLink]
windowLinks = G.graphLinks . G.entities

-- | Every pane appearance, ordered by link and then pane index.
paneOccurrences :: Snapshot -> [PaneOccurrence]
paneOccurrences = G.graphOccurrences . G.entities

-- | Resolve a session in this snapshot. Missing and foreign refs are errors.
lookupSession :: Snapshot -> SessionRef -> Either LookupError Session
lookupSession snapshot = G.lookupSession (G.entities snapshot)

-- | Resolve the supplied generation's physical window in this snapshot.
lookupWindow :: Snapshot -> WindowRef -> Either LookupError Window
lookupWindow snapshot = G.lookupWindow (G.entities snapshot)

-- | Resolve the supplied generation's physical pane in this snapshot.
lookupPane :: Snapshot -> PaneRef -> Either LookupError Pane
lookupPane snapshot = G.lookupPane (G.entities snapshot)

-- | A session's window links in window-index order, preserving repeated windows.
linksForSession :: Snapshot -> SessionRef -> Either LookupError [WindowLink]
linksForSession snapshot = G.linksForSession (G.entities snapshot)

-- | A physical window's panes in pane-index order, then numeric ID order.
panesForWindow :: Snapshot -> WindowRef -> Either LookupError [Pane]
panesForWindow snapshot = G.panesForWindow (G.entities snapshot)

-- | Select the session currently observed under an ID in this snapshot.
-- This creates no continuity guarantee with a previously opened Server.
lookupSessionId :: Snapshot -> SessionId -> Either LookupError Session
lookupSessionId snapshot ident = lookupSession snapshot (G.SessionRef (serverInfo snapshot).generation ident)

-- | Select the physical window observed under an ID in this snapshot.
lookupWindowId :: Snapshot -> WindowId -> Either LookupError Window
lookupWindowId snapshot ident = lookupWindow snapshot (G.WindowRef (serverInfo snapshot).generation ident)

-- | Select the pane observed under an ID in this snapshot.
lookupPaneId :: Snapshot -> PaneId -> Either LookupError Pane
lookupPaneId snapshot ident = lookupPane snapshot (G.PaneRef (serverInfo snapshot).generation ident)

-- | Copy bytes into an owned label. This performs no encoding replacement.
labelFromBytes :: ByteString -> TmuxText
labelFromBytes = Label.fromBytes

-- | Exact bytes reported by tmux, after transport decoding.
labelBytes :: TmuxText -> ByteString
labelBytes = Label.toBytes

-- | Decode a label as UTF-8, retaining byte access on failure.
labelText :: TmuxText -> Either UnicodeException Text
labelText = Label.decodeUtf8
