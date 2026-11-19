-- | Captured fields and relationships for "LibTmux.Query".
--
-- Import this module qualified, for example as @F@. Row prefixes identify
-- the source row in @F.paneActive@ and @F.linkActive@.
-- Tokens describe the tmux 3.3a baseline and never contact tmux. Byte-bearing
-- names and paths, optional values and contextual relationships keep the
-- meanings of "LibTmux.Snapshot".
--
-- >>> LibTmux.Query.requirements (LibTmux.Query.matching (LibTmux.Query.eq paneActive True) LibTmux.Query.panes)
-- QueryRequirements {sourceName = "panes", fieldNames = ["pane.active"], relationshipNames = [], orderingFields = [], rowLimit = Nothing}
module LibTmux.Query.Fields
  ( -- * Sessions
    sessionId, sessionName, sessionAttached, sessionGroup, sessionWindowLinks,
    sessionClients
    -- * Physical windows
  , windowId, windowName, windowWidth, windowHeight, windowLayout, windowZoomed,
    windowPanes, windowLinks
    -- * Physical panes
  , paneId, paneWindowId, paneIndex, paneWidth, paneHeight, paneActive, paneDead,
    paneTitle, paneCurrentCommand, paneCurrentPath, paneCursorX, paneCursorY,
    paneModeCount, paneMode, paneWindow
    -- * Window links
  , linkSessionId, linkWindowId, linkIndex, linkActive, linkFlags, linkSession,
    linkWindow, linkPanes
    -- * Pane occurrences
  , occurrencePane, occurrenceLink
    -- * Clients
  , clientName, clientPid, clientTty, clientWidth, clientHeight, clientAttachment
    -- * Client attachments
  , clientAttachmentSessionId, clientAttachmentWindowId, clientAttachmentWindowIndex,
    clientAttachmentPaneId, clientAttachmentSession, clientAttachmentWindow,
    clientAttachmentPane
    -- * Daemon metadata
  , serverInfoPid, serverInfoStartedAt, serverInfoVersion, serverInfoSocketPath
  ) where

import Data.Text (Text)
import LibTmux.Id (SessionId, WindowId, PaneId)
import LibTmux.Internal.Field qualified as F
import LibTmux.Internal.Query qualified as Q
import LibTmux.Query (Field, ToMany, ToOne, ToOptional)
import LibTmux.Snapshot
  ( Session, Window, Pane, WindowLink, PaneOccurrence, Client, ClientAttachment
  , ServerInfo, TmuxText
  )
import LibTmux.Value (Dimension, PaneIndex, WindowIndex)
import LibTmux.Version (TmuxVersion)
import System.OsPath.Posix (PosixPath)
import System.OsString.Posix (PosixString)

-- | Native session ID without a connection-generation guarantee.
sessionId :: Field Session SessionId
sessionId = F.SessionId

-- | Captured UTF-8 session name. Equality does not normalize Unicode.
sessionName :: Field Session Text
sessionName = F.SessionName

-- | Nonnegative count of attached clients as observed by tmux.
sessionAttached :: Field Session Integer
sessionAttached = F.SessionAttached

-- | Lossless reported group label, or 'Nothing' for an ungrouped session.
sessionGroup :: Field Session (Maybe TmuxText)
sessionGroup = F.SessionGroup

-- | Every window link owned by this session, retaining index and multiplicity.
sessionWindowLinks :: ToMany Session WindowLink
sessionWindowLinks = Q.SessionLinks

-- | Captured clients attached to this session; an empty list is known absence.
sessionClients :: ToMany Session Client
sessionClients = Q.SessionClients

-- | Native physical window ID, independent of a session's link index.
windowId :: Field Window WindowId
windowId = F.WindowId

-- | Lossless window label. Equality and ordering compare its retained bytes.
windowName :: Field Window TmuxText
windowName = F.WindowName

-- | Positive physical window width in cells.
windowWidth :: Field Window Dimension
windowWidth = F.WindowWidth

-- | Positive physical window height in cells.
windowHeight :: Field Window Dimension
windowHeight = F.WindowHeight

-- | Native unzoomed layout encoding, possibly including pane selections.
-- Treat it as opaque, release-dependent text.
windowLayout :: Field Window Text
windowLayout = F.WindowLayout

-- | Whether a pane currently occupies the window through zoom.
windowZoomed :: Field Window Bool
windowZoomed = F.WindowZoomed

-- | Physical panes in this window, ordered by pane index.
windowPanes :: ToMany Window Pane
windowPanes = Q.WindowPanes

-- | All contextual appearances of this window across captured sessions.
windowLinks :: ToMany Window WindowLink
windowLinks = Q.WindowLinks

-- | Native pane ID. Equality alone does not establish Server identity.
paneId :: Field Pane PaneId
paneId = F.PaneId

-- | Native ID of the pane's physical window; use 'paneWindow' to navigate it.
paneWindowId :: Field Pane WindowId
paneWindowId = F.PaneWindow

-- | Pane index within its window, distinct from a window-link index.
paneIndex :: Field Pane PaneIndex
paneIndex = F.PaneIndex

-- | Positive width in cells. Use 'LibTmux.Query.dimensionAtLeast' for an integer threshold.
paneWidth :: Field Pane Dimension
paneWidth = F.PaneWidth

-- | Positive height in cells, independent of window-link context.
paneHeight :: Field Pane Dimension
paneHeight = F.PaneHeight

-- | Whether this is the active pane of its physical window.
paneActive :: Field Pane Bool
paneActive = F.PaneActive

-- | Whether tmux observed the pane's process as dead.
paneDead :: Field Pane Bool
paneDead = F.PaneDead

-- | UTF-8 pane title. 'LibTmux.Query.contains' performs exact Text substring matching.
paneTitle :: Field Pane Text
paneTitle = F.PaneTitle

-- | Foreground command name as lossless POSIX bytes, not a shell command line.
paneCurrentCommand :: Field Pane PosixString
paneCurrentCommand = F.PaneCommand

-- | Observed current directory on the tmux endpoint, preserving POSIX bytes.
paneCurrentPath :: Field Pane PosixPath
paneCurrentPath = F.PanePath

-- | Zero-based base-screen column; may equal width when a wrap is pending.
paneCursorX :: Field Pane Integer
paneCursorX = F.PaneCursorX

-- | Zero-based base-screen row, independent of the current mode's cursor.
paneCursorY :: Field Pane Integer
paneCursorY = F.PaneCursorY

-- | Native pane mode-stack depth, including zero.
paneModeCount :: Field Pane Integer
paneModeCount = F.PaneModeCount

-- | Current mode name, or 'Nothing' when no mode is active.
paneMode :: Field Pane (Maybe Text)
paneMode = F.PaneMode

-- | Resolve the pane's physical window in the supplied snapshot with 'LibTmux.Query.related'.
paneWindow :: ToOne Pane Window
paneWindow = Q.PaneWindow

-- | Native ID of the session that owns this observed link.
linkSessionId :: Field WindowLink SessionId
linkSessionId = F.LinkSession

-- | Native ID of the shared physical window.
linkWindowId :: Field WindowLink WindowId
linkWindowId = F.LinkWindow

-- | Window-link index within the session; reindexing can change it.
linkIndex :: Field WindowLink WindowIndex
linkIndex = F.LinkIndex

-- | Whether this link is selected in its session.
linkActive :: Field WindowLink Bool
linkActive = F.LinkActive

-- | Native window_flags for this appearance. Retains tmux's doubled @#@ escaping.
linkFlags :: Field WindowLink Text
linkFlags = F.LinkFlags

-- | Resolve the session in the supplied snapshot with 'LibTmux.Query.related'.
linkSession :: ToOne WindowLink Session
linkSession = Q.LinkSession

-- | Resolve the shared physical window in the supplied snapshot.
linkWindow :: ToOne WindowLink Window
linkWindow = Q.LinkWindow

-- | Physical panes reached through this link, ordered by pane index.
linkPanes :: ToMany WindowLink Pane
linkPanes = Q.LinkPanes

-- | The physical pane observed through this occurrence, used with 'LibTmux.Query.related'.
occurrencePane :: ToOne PaneOccurrence Pane
occurrencePane = Q.OccurrencePane

-- | The observed session and window-index context of this appearance.
occurrenceLink :: ToOne PaneOccurrence WindowLink
occurrenceLink = Q.OccurrenceLink

-- | Lossless client name supplied by tmux.
clientName :: Field Client PosixString
clientName = F.ClientName

-- | Positive operating-system process ID, for observation rather than signalling.
clientPid :: Field Client Integer
clientPid = F.ClientPid

-- | Observed client tty, or 'Nothing' when tmux reports no tty.
clientTty :: Field Client (Maybe PosixPath)
clientTty = F.ClientTty

-- | Reported unsigned tty width in cells. Control clients can report zero.
clientWidth :: Field Client Integer
clientWidth = F.ClientWidth

-- | Tty height when tmux has started the terminal; absent for control clients.
clientHeight :: Field Client (Maybe Integer)
clientHeight = F.ClientHeight

-- | Optional captured selection, used with 'LibTmux.Query.optionalRelated'. Absence fails
-- that positive predicate and satisfies its negation.
clientAttachment :: ToOptional Client ClientAttachment
clientAttachment = Q.ClientAttachment

-- | Native ID of the selected session.
clientAttachmentSessionId :: Field ClientAttachment SessionId
clientAttachmentSessionId = F.ClientSession

-- | Native ID of the selected physical window.
clientAttachmentWindowId :: Field ClientAttachment WindowId
clientAttachmentWindowId = F.ClientWindow

-- | Selected link index in the client's session.
clientAttachmentWindowIndex :: Field ClientAttachment WindowIndex
clientAttachmentWindowIndex = F.ClientWindowIndex

-- | Native ID of the selected physical pane.
clientAttachmentPaneId :: Field ClientAttachment PaneId
clientAttachmentPaneId = F.ClientPane

-- | Selected session observation, used with 'LibTmux.Query.related'.
clientAttachmentSession :: ToOne ClientAttachment Session
clientAttachmentSession = Q.AttachmentSession

-- | Selected physical window observation.
clientAttachmentWindow :: ToOne ClientAttachment Window
clientAttachmentWindow = Q.AttachmentWindow

-- | Selected pane in its actual session/index context.
clientAttachmentPane :: ToOne ClientAttachment PaneOccurrence
clientAttachmentPane = Q.AttachmentPane

-- | Observed daemon process ID.
serverInfoPid :: Field ServerInfo Integer
serverInfoPid = F.ServerPid

-- | Daemon start time in epoch seconds, as reported by tmux.
serverInfoStartedAt :: Field ServerInfo Integer
serverInfoStartedAt = F.ServerStartedAt

-- | Parsed tmux release, compared using the library's version ordering.
serverInfoVersion :: Field ServerInfo TmuxVersion
serverInfoVersion = F.ServerVersion

-- | Reported socket path on the tmux endpoint, retaining POSIX bytes.
serverInfoSocketPath :: Field ServerInfo PosixPath
serverInfoSocketPath = F.ServerSocketPath
