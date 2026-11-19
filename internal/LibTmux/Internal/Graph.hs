-- | Detached physical entities, contextual links and validated graph indexes.
--
-- Window labels use 'TmuxText'; process names and paths preserve POSIX bytes.
-- Reading an observation or navigating the graph performs no IO.
-- 'assembleEntityGraph' validates references, unique positions and selections
-- for its ordered views and lookup indexes. 'assembleSnapshot' joins
-- metadata and attached clients, then forces the complete detached value.
module LibTmux.Internal.Graph
  ( EndpointIdentity (..), Generation (..)
  , SessionRef (..), WindowRef (..), PaneRef (..), CreatedEntities (..), CreatedSession
  , Session (..), Window (..), Pane (..), WindowLink (..), PaneOccurrence (..)
  , EntityGraph, GraphError (..), LookupError (..), assembleEntityGraph
  , graphSessions, graphWindows, graphPanes, graphLinks, graphOccurrences
  , lookupSession, lookupWindow, lookupPane, linksForSession, panesForWindow
  , ServerInfo (..), Client (..), ClientAttachment (..), ClientInput (..)
  , Snapshot, serverInfo, entities, clients, assembleSnapshot
  , CaptureInterval (..), captureInterval, stampSnapshot
  ) where

import Control.DeepSeq (NFData (rnf), deepseq)
import Control.Monad (foldM, unless, void, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Word (Word64)
import Foreign.C.Types (CInt)
import LibTmux.Id (PaneId, SessionId, WindowId)
import LibTmux.Internal.TmuxText (TmuxText)
import LibTmux.Value (Dimension, PaneIndex, WindowIndex)
import LibTmux.Version qualified as Version
import System.OsPath.Posix (PosixPath)
import System.OsString.Posix (PosixString)
import System.OsString.Posix qualified as Os

data EndpointIdentity = EndpointIdentity !Integer !Integer
  deriving stock (Eq, Ord, Show)
instance NFData EndpointIdentity where
  rnf (EndpointIdentity device inode) = rnf device `seq` rnf inode

-- | Opaque connection or offline-fixture identity. Independent Server handles
-- receive distinct tokens; named fixtures never equal an adopted endpoint.
data Generation = Generation !EndpointIdentity !ByteString
  | FixtureGeneration !Text
  deriving stock (Eq, Ord, Show)
instance NFData Generation where
  rnf (Generation endpoint token) = rnf endpoint `seq` rnf token
  rnf (FixtureGeneration name) = rnf name

-- | Session targeting identity within a t'Generation'. Compare observations
-- separately when their captured field values matter.
data SessionRef = SessionRef !Generation !SessionId
  deriving stock (Eq, Ord, Show)
instance NFData SessionRef where
  rnf (SessionRef generation ident) = rnf generation `seq` rnf ident

-- | Physical window targeting identity within a t'Generation'. A window can
-- have several t'WindowLink' appearances.
data WindowRef = WindowRef !Generation !WindowId
  deriving stock (Eq, Ord, Show)
instance NFData WindowRef where
  rnf (WindowRef generation ident) = rnf generation `seq` rnf ident

-- | Physical pane targeting identity within a t'Generation'. This carries
-- identity, while the supplied t'Snapshot' determines the observed values.
data PaneRef = PaneRef !Generation !PaneId
  deriving stock (Eq, Ord, Show)
instance NFData PaneRef where
  rnf (PaneRef generation ident) = rnf generation `seq` rnf ident

-- | Historical identities printed during session, window or pane creation. A later hook
-- may already have removed them. Resolve through a fresh captured snapshot;
-- these references do not constitute hydrated observations or prove liveness.
-- Read these fields with record dot; construction remains private.
--
-- [#v:serverPid# @serverPid@ :: 'Integer'] Daemon PID printed with the receipt.
-- [#v:session# @session@ :: t'SessionRef'] Session containing the creation.
-- [#v:window# @window@ :: t'WindowRef'] Physical window containing the new pane.
-- [#v:pane# @pane@ :: t'PaneRef'] Created physical pane.
-- [#v:windowIndex# @windowIndex@ :: t'WindowIndex'] Link index printed by tmux.
data CreatedEntities = CreatedEntities
  { serverPid :: !Integer -- ^ Daemon PID printed with the creation receipt.
  , session :: !SessionRef -- ^ Session containing the new pane in the originating generation.
  , window :: !WindowRef -- ^ Physical window containing the new pane.
  , pane :: !PaneRef -- ^ Actual created physical pane.
  , windowIndex :: !WindowIndex -- ^ Link index printed by tmux before after-hooks.
  } deriving stock (Eq, Show)
instance NFData CreatedEntities where
  rnf (CreatedEntities pid session window pane index) =
    rnf pid `seq` rnf session `seq` rnf window `seq` rnf pane `seq` rnf index

-- | A 'CreatedEntities' receipt from new-session: all three entities are new.
type CreatedSession = CreatedEntities

-- | Detached physical session. Navigate its appearances through t'WindowLink'.
--
-- == What is on here
--
-- Calls that find, read or change a session, by job. The calls that take a
-- @Server@ contact tmux; the rest read values you already hold.
--
-- __Get the sessions in a snapshot.__ Capture a snapshot through a Server,
-- then list its sessions in ID order or start a query from them.
--
-- * From a Server: 'LibTmux.Server.capture'
-- * From a snapshot: 'LibTmux.Snapshot.sessions'
-- * As a query source: 'LibTmux.Query.sessions'
--
-- __Find a session by reference or ID.__ A lookup reads the snapshot you pass
-- and returns a lookup error for a missing or foreign reference. An ID selects
-- whichever session holds it in that snapshot, with no continuity with an
-- earlier Server.
--
-- 'LibTmux.Snapshot.lookupSession', 'LibTmux.Snapshot.lookupSessionId',
-- t'SessionRef', t'LookupError'
--
-- __Parse and print session IDs.__ Parsing and rendering are pure. An ID
-- carries no endpoint or liveness evidence.
--
-- 'LibTmux.Id.parseSessionId', 'LibTmux.Id.renderSessionId',
-- 'LibTmux.Id.sessionIdValue', 'LibTmux.Snapshot.sessionId', t'SessionId'
--
-- __Read a session's fields.__ Use record dot on the value, or a field token
-- in a query. Field tokens describe captured values and never contact tmux.
--
-- 'LibTmux.Query.Session.id', 'LibTmux.Query.Session.name',
-- 'LibTmux.Query.Session.attached'
--
-- __Follow a session to its windows and clients, or back.__ A session reaches
-- its windows through links, and one window can be linked more than once. A
-- window link and a client attachment each name a session; resolve it in a
-- query.
--
-- * From a snapshot: 'LibTmux.Snapshot.linksForSession'
-- * From a session in a query: 'LibTmux.Query.Session.windowLinks',
--   'LibTmux.Query.Session.clients'
-- * Test its links or clients: 'LibTmux.Query.some', 'LibTmux.Query.every',
--   'LibTmux.Query.none'
-- * From a window link: 'LibTmux.Query.Link.sessionId',
--   'LibTmux.Query.Link.session'
-- * From a client attachment: 'LibTmux.Query.ClientAttachment.sessionId',
--   'LibTmux.Query.ClientAttachment.session'
-- * Resolve the session: 'LibTmux.Query.related'
--
-- __Select sessions with a query.__ Match the name by equality or an exact
-- substring and the attached count by a threshold, then run the query on a
-- snapshot you hold or fetch a fresh one. @exactlyOne@ turns a result into one
-- session or an error.
--
-- 'LibTmux.Query.sessions', 'LibTmux.Query.matching', 'LibTmux.Query.eq',
-- 'LibTmux.Query.contains', 'LibTmux.Query.ge', 'LibTmux.Query.runQuery',
-- 'LibTmux.Query.fetch', 'LibTmux.Query.exactlyOne'
--
-- __Create a session.__ Creation returns the references tmux printed, not an
-- observed session. Capture again to see the new session. A failed creation
-- can leave a receipt in its recovery, and a missing receipt does not mean no
-- session exists.
--
-- * Create: 'LibTmux.Server.createSession', 'LibTmux.Server.createSessionWith'
-- * Describe: 'LibTmux.Creation.defaultSessionOptions',
--   t'LibTmux.Creation.SessionOptions', t'LibTmux.Creation.CreatedSession'
-- * After a failure: 'LibTmux.Server.creationReceipt'
--
-- __Rename a session.__ The name is literal text, and snapshots you already
-- hold keep the old name. A reference from another Server or an offline
-- fixture is refused before the command runs. The @With@ variant takes a
-- deadline.
--
-- 'LibTmux.Server.renameSession', 'LibTmux.Server.renameSessionWith'
--
-- __Add a window to a session.__ A placement names the session and where the
-- window goes: the next free index or a slot. The result holds the references
-- tmux printed, so capture again to observe the window.
--
-- * Create: 'LibTmux.Server.createWindow', 'LibTmux.Server.createWindowWith'
-- * Place: t'LibTmux.Creation.WindowPlacement', t'LibTmux.Creation.WindowSlot'
--
-- __Remove a session.__ A window that another session links survives. tmux may
-- exit when its last session closes, so observe the daemon separately.
--
-- 'LibTmux.Server.killSession', 'LibTmux.Server.killSessionWith'
--
-- __Change which windows a session links.__ A slot names the session and the
-- index of one link. Select a link, link a window into a vacant slot, or remove
-- one link; tmux refuses to remove a window's last link, and session groups can
-- propagate links.
--
-- * Select: 'LibTmux.Server.selectWindowLink',
--   'LibTmux.Server.selectWindowLinkWith'
-- * Link: 'LibTmux.Server.linkWindow', 'LibTmux.Server.linkWindowWith'
-- * Unlink: 'LibTmux.Server.unlinkWindow', 'LibTmux.Server.unlinkWindowWith'
-- * Slot: t'LibTmux.Creation.WindowSlot'
--
-- __Build a session offline.__ Fixture references belong to a named offline
-- origin, never to a live Server. Validation checks a fixture before it
-- becomes a snapshot.
--
-- 'LibTmux.Snapshot.Fixture.sessionRef',
-- 'LibTmux.Snapshot.Fixture.validateFixture',
-- t'LibTmux.Snapshot.Fixture.Fixture'
data Session = Session
  { ref :: !SessionRef -- ^ Target identity in the observation's generation.
  , name :: !Text -- ^ Session name as reported and decoded by tmux.
  , attached :: !Integer -- ^ Nonnegative reported count, independent of the captured client listing.
  }
  deriving stock (Eq, Show)
instance NFData Session where
  rnf (Session ref name attached) = rnf (ref, name, attached)

-- | Detached physical window, independent of its session and index appearances.
--
-- == What is on here
--
-- Calls that find, read or change a window, by job. The calls that take a
-- @Server@ contact tmux; the rest read values you already hold.
--
-- __Get the windows in a snapshot.__ A physical window is listed once, however
-- many sessions link it; the link lists show every appearance instead.
--
-- * From a Server: 'LibTmux.Server.capture'
-- * From a snapshot: 'LibTmux.Snapshot.windows',
--   'LibTmux.Snapshot.windowLinks'
-- * As a query source: 'LibTmux.Query.windows', 'LibTmux.Query.windowLinks'
--
-- __Find a window by reference or ID.__ A lookup reads the snapshot you pass
-- and returns a lookup error for a missing or foreign reference. An ID selects
-- whichever window holds it in that snapshot.
--
-- 'LibTmux.Snapshot.lookupWindow', 'LibTmux.Snapshot.lookupWindowId',
-- t'WindowRef', t'LookupError'
--
-- __Parse and print window IDs.__ Parsing and rendering are pure. An ID is
-- independent of a session's link index.
--
-- 'LibTmux.Id.parseWindowId', 'LibTmux.Id.renderWindowId',
-- 'LibTmux.Id.windowIdValue', 'LibTmux.Snapshot.windowId', t'WindowId'
--
-- __Read a window's fields.__ Use record dot on the value, or a field token in
-- a query. The name keeps the bytes tmux reports, because older supported
-- releases can retain names that are not valid UTF-8; decode it as UTF-8 when
-- you need text.
--
-- * Field tokens: 'LibTmux.Query.Window.id', 'LibTmux.Query.Window.name',
--   'LibTmux.Query.Window.width', 'LibTmux.Query.Window.height'
-- * The name as bytes: t'TmuxText', 'LibTmux.Snapshot.labelText',
--   'LibTmux.Snapshot.labelBytes', 'LibTmux.Snapshot.labelFromBytes'
--
-- __Follow a window to its panes and links.__ Panes come in pane-index order.
-- One window can have several links, and its name and pane set are shared
-- across them.
--
-- * From a snapshot: 'LibTmux.Snapshot.panesForWindow'
-- * From a window in a query: 'LibTmux.Query.Window.panes',
--   'LibTmux.Query.Window.windowLinks'
-- * Test its panes or links: 'LibTmux.Query.some', 'LibTmux.Query.every',
--   'LibTmux.Query.none'
-- * From a window link: 'LibTmux.Query.Link.panes'
--
-- __Reach a window from a link, a pane or a client.__ Each names one window;
-- resolve it in a query.
--
-- * From a window link: 'LibTmux.Query.Link.windowId',
--   'LibTmux.Query.Link.window'
-- * From a pane: 'LibTmux.Query.Pane.windowId', 'LibTmux.Query.Pane.window'
-- * From a client attachment: 'LibTmux.Query.ClientAttachment.windowId',
--   'LibTmux.Query.ClientAttachment.window'
-- * Resolve the window: 'LibTmux.Query.related'
--
-- __Read where a window sits in a session.__ A window's index belongs to a
-- link in one session, not to the window, and reindexing can change it.
--
-- * Index type: t'WindowIndex', 'LibTmux.Value.mkWindowIndex',
--   'LibTmux.Value.windowIndexValue'
-- * Field tokens: 'LibTmux.Query.Link.index',
--   'LibTmux.Query.ClientAttachment.windowIndex'
-- * Thresholds: 'LibTmux.Query.windowIndexAtLeast',
--   'LibTmux.Query.windowIndexAtMost'
--
-- __Select windows with a query.__ Compare sizes with a dimension threshold.
-- Names are bytes, so match them with exact equality rather than a substring.
--
-- 'LibTmux.Query.windows', 'LibTmux.Query.matching', 'LibTmux.Query.eq',
-- 'LibTmux.Query.dimensionAtLeast', 'LibTmux.Query.dimensionAtMost',
-- 'LibTmux.Query.runQuery', 'LibTmux.Query.fetch'
--
-- __Create a window.__ A placement says where it goes, and the options set a
-- label, a directory, an environment, whether to select it and what to do with
-- an occupied slot, which is refused by default. The result holds the
-- references tmux printed, so capture again to observe the window.
--
-- * Create: 'LibTmux.Server.createWindow', 'LibTmux.Server.createWindowWith'
-- * Place: t'LibTmux.Creation.WindowPlacement', t'LibTmux.Creation.WindowSlot',
--   t'LibTmux.Creation.WindowCollision'
-- * Options: t'LibTmux.Creation.WindowOptions',
--   'LibTmux.Creation.defaultWindowOptions'
-- * Result: t'LibTmux.Creation.CreatedWindow'
--
-- __Get the window a new session starts with.__ Creating a session returns
-- the reference and link index of its first window. Capture again to observe
-- the window.
--
-- 'LibTmux.Server.createSession', 'LibTmux.Server.createSessionWith',
-- t'LibTmux.Creation.CreatedSession'
--
-- __Rename a window.__ One rename changes the physical window across all its
-- session links. The label keeps its bytes, and tmux may reject names its
-- release does not accept. A reference from another Server or an offline
-- fixture is refused before the command runs.
--
-- 'LibTmux.Server.renameWindow', 'LibTmux.Server.renameWindowWith'
--
-- __Link a window into another slot, or remove a link.__ A slot names a session
-- and a link index. Linking puts the window in a vacant slot; existing links
-- remain and the new link starts unselected. tmux refuses to remove a window's
-- last link, and session groups can propagate either change.
--
-- * Link: 'LibTmux.Server.linkWindow', 'LibTmux.Server.linkWindowWith'
-- * Unlink: 'LibTmux.Server.unlinkWindow', 'LibTmux.Server.unlinkWindowWith'
-- * Slot: t'LibTmux.Creation.WindowSlot'
--
-- __Select a window link.__ Selection works on a link, so it can pick one of
-- several links to the same physical window. Capture again to observe it.
--
-- 'LibTmux.Server.selectWindowLink', 'LibTmux.Server.selectWindowLinkWith',
-- t'LibTmux.Creation.WindowSlot'
--
-- __Arrange a window's panes with a named layout.__ Every link to the window
-- sees the new layout, and tmux can unzoom the window. Capture again to observe
-- the pane geometry.
--
-- 'LibTmux.Server.selectLayout', 'LibTmux.Server.selectLayoutWith',
-- t'LibTmux.Server.NamedLayout'
--
-- __Remove a window.__ One removal closes the physical window across all its
-- links, and tmux closes a session left without windows.
--
-- 'LibTmux.Server.killWindow', 'LibTmux.Server.killWindowWith'
--
-- __Build a window offline.__ Fixture references belong to a named offline
-- origin, never to a live Server. Validation checks a fixture before it
-- becomes a snapshot.
--
-- 'LibTmux.Snapshot.Fixture.windowRef',
-- 'LibTmux.Snapshot.Fixture.validateFixture',
-- t'LibTmux.Snapshot.Fixture.Fixture'
data Window = Window
  { ref :: !WindowRef -- ^ Shared identity across this snapshot's window links.
  , name :: !TmuxText -- ^ Reported bytes, including non-text names on older tmux.
  , width :: !Dimension -- ^ Positive terminal width in cells.
  , height :: !Dimension -- ^ Positive terminal height in cells.
  }
  deriving stock (Eq, Show)
instance NFData Window where
  rnf (Window ref name width height) = rnf (ref, name, width, height)

-- | Detached physical pane. Its window can appear in several session contexts;
-- t'PaneOccurrence' preserves an appearance without duplicating physical identity.
data Pane = Pane
  { ref :: !PaneRef -- ^ Pane identity in the observation's generation.
  , window :: !WindowRef -- ^ Containing physical window, resolved against a snapshot.
  , index :: !PaneIndex -- ^ Nonnegative pane index within that window.
  , width :: !Dimension -- ^ Positive terminal width in cells.
  , height :: !Dimension -- ^ Positive terminal height in cells.
  , active :: !Bool -- ^ The window's active pane, rather than a separate client focus.
  , dead :: !Bool -- ^ Whether tmux reports the pane process as dead.
  , title :: !Text -- ^ Valid UTF-8 pane title reported by tmux.
  , currentCommand :: !PosixString -- ^ Reported process name; tmux may normalize it.
  , currentPath :: !PosixPath -- ^ Endpoint data, without local path interpretation.
  }
  deriving stock (Eq, Show)
instance NFData Pane where
  rnf (Pane ref window index width height active dead title command path) =
    rnf ((ref, window, index, width, height), (active, dead, title, command, path))

-- | One observed session/index/window binding. Indices are reusable positions;
-- this value describes captured context. The same window may appear repeatedly.
data WindowLink = WindowLink
  { session :: !SessionRef -- ^ Session containing this appearance.
  , index :: !WindowIndex -- ^ Position of this link within the session.
  , window :: !WindowRef -- ^ Physical window shared by its appearances.
  , active :: !Bool -- ^ Whether this is the session's selected window link.
  }
  deriving stock (Eq, Show)
instance NFData WindowLink where
  rnf (WindowLink session index window active) = rnf (session, index, window, active)

-- | A physical pane together with one contextual window appearance.
data PaneOccurrence = PaneOccurrence
  { pane :: !Pane -- ^ Captured physical pane value.
  , link :: !WindowLink -- ^ Session and index context through which it appears.
  }
  deriving stock (Eq, Show)
instance NFData PaneOccurrence where
  rnf (PaneOccurrence pane link) = rnf (pane, link)

-- | Reported daemon metadata within one adopted generation. PID and start
-- time are observations; they do not grant signal authority or durable identity.
data ServerInfo = ServerInfo
  { generation :: !Generation -- ^ Connection identity shared by all references in this snapshot.
  , pid :: !Integer -- ^ Positive daemon process ID reported by tmux.
  , startedAt :: !Integer -- ^ Daemon start time in whole seconds since the Unix epoch.
  , version :: !Version.TmuxVersion -- ^ Release admitted by "LibTmux.Version".
  , socketPath :: !PosixPath -- ^ Reported endpoint path, preserved as POSIX bytes.
  }
  deriving stock (Eq, Show)
instance NFData ServerInfo where
  rnf (ServerInfo generation pid startedAt version socketPath) = rnf generation
    `seq` rnf pid `seq` rnf startedAt `seq` rnf (Version.renderVersion version) `seq` rnf socketPath

-- | An attachment contains this capture's values. It never resolves a retained
-- client name against a later capture. The pane is the session window's global
-- active pane, not an independent client focus; its link retains session context.
data ClientAttachment = ClientAttachment
  { session :: !Session -- ^ Captured attachment session.
  , window :: !Window -- ^ Captured physical selected window.
  , pane :: !PaneOccurrence -- ^ Selected pane with its session/window-link context.
  }
  deriving stock (Eq, Show)
instance NFData ClientAttachment where
  rnf (ClientAttachment session window pane) = rnf (session, window, pane)

-- | A detached client observation, not an operational connection or live ref.
-- The live profile lists attached clients; an offline value may be unattached.
data Client = Client
  { name :: !PosixString -- ^ Reported client-name bytes; names may be reused.
  , pid :: !Integer -- ^ Reported positive client process ID.
  , tty :: !(Maybe PosixPath) -- ^ Reported terminal path, when present.
  , attachment :: !(Maybe ClientAttachment) -- ^ Attachment values resolved within this capture.
  }
  deriving stock (Eq, Show)
instance NFData Client where
  rnf (Client name pid tty attachment) = rnf (name, pid, tty, attachment)

-- Required native context from the attached-only listing, before graph lookup.
data ClientInput = ClientInput
  { name :: !PosixString
  , pid :: !Integer
  , tty :: !(Maybe PosixPath)
  , session :: !SessionId
  , window :: !WindowId
  , index :: !WindowIndex
  , pane :: !PaneId
  }

-- | Validated metadata, physical graph and attached-client observations.
-- Construction checks every join and forces owned values. List processing
-- and indexed lookup remain pure after the operational Server closes.
data Snapshot = Snapshot !ServerInfo !EntityGraph ![Client] !(Maybe CaptureInterval)
  deriving stock (Eq, Show)
instance NFData Snapshot where
  rnf (Snapshot info graph rows interval) = rnf info `seq` rnf graph `seq` rnf rows `seq` rnf interval

-- | Daemon metadata captured with this graph.
serverInfo :: Snapshot -> ServerInfo
serverInfo (Snapshot info _ _ _) = info

entities :: Snapshot -> EntityGraph
entities (Snapshot _ graph _ _) = graph

-- | Captured attached clients in reported-name and PID order. Names may repeat.
clients :: Snapshot -> [Client]
clients (Snapshot _ _ rows _) = rows

-- | Monotonic process-clock bounds around acquisition. These values describe
-- an interval and do not promise an atomic observation or a wall-clock epoch.
data CaptureInterval = CaptureInterval
  { startedNanoseconds :: !Word64 -- ^ Monotonic time sampled before acquisition.
  , finishedNanoseconds :: !Word64 -- ^ Monotonic time after decoding and forcing.
  }
  deriving stock (Eq, Show)
instance NFData CaptureInterval where
  rnf (CaptureInterval started finished) = rnf started `seq` rnf finished

-- | Acquisition bounds attached to a live capture. An unstamped decoded
-- profile stays private; an offline fixture has no external capture interval.
captureInterval :: Snapshot -> Maybe CaptureInterval
captureInterval (Snapshot _ _ _ interval) = interval

stampSnapshot :: Word64 -> Word64 -> Snapshot -> Either GraphError Snapshot
stampSnapshot started finished (Snapshot info graph rows _)
  | started > finished = Left InvalidCaptureInterval
  | otherwise =
      let !interval = CaptureInterval started finished
      in Right (Snapshot info graph rows (Just interval))

data EntityGraph = EntityGraph
  { generation :: !Generation
  , sessions :: !(Map SessionRef Session)
  , windows :: !(Map WindowRef Window)
  , panes :: !(Map PaneRef Pane)
  , links :: !(Map (SessionRef, WindowIndex) WindowLink)
  , sessionLinks :: !(Map SessionRef [WindowLink])
  , windowPanes :: !(Map WindowRef [Pane])
  }
  deriving stock (Eq, Show)
instance NFData EntityGraph where
  rnf graph = rnf graph.generation `seq` rnf graph.sessions `seq`
    rnf graph.windows `seq` rnf graph.panes `seq` rnf graph.links `seq`
    rnf graph.sessionLinks `seq` rnf graph.windowPanes

-- | A reference that cannot resolve in the supplied immutable snapshot.
-- Missing entities are distinct from a successfully observed empty relation.
data LookupError
  = ForeignGeneration -- ^ The reference belongs to another connection generation.
  | MissingSession !SessionRef -- ^ No session with this identity was captured.
  | MissingWindow !WindowRef -- ^ No physical window with this identity was captured.
  | MissingPane !PaneRef -- ^ No physical pane with this identity was captured.
  deriving stock (Eq, Show)

data GraphError
  = InvalidGeneration
  | InvalidReference !LookupError
  | ConflictingSession !SessionRef
  | ConflictingWindow !WindowRef
  | ConflictingPane !PaneRef
  | DuplicateWindowSlot !SessionRef !WindowIndex
  | DuplicatePaneIndex !WindowRef !PaneIndex
  | InvalidAttachedCount !SessionRef !Integer
  | InvalidSessionSelection !SessionRef !Int
  | InvalidPaneSelection !WindowRef !Int
  | UnlinkedWindow !WindowRef
  | InvalidServerInfo
  | InvalidClientMetadata
  | MissingClientLink !SessionRef !WindowIndex
  | ChangedClientAttachment
  | InvalidCaptureInterval
  deriving stock (Eq, Show)

assembleEntityGraph
  :: Generation -> [Session] -> [Window] -> [Pane] -> [WindowLink]
  -> Either GraphError EntityGraph
assembleEntityGraph generation sessionRows windowRows paneRows linkRows = do
  let valid = case generation of
        Generation (EndpointIdentity device inode) token ->
          device >= 0 && inode >= 0 && Bytes.length token == 32
        FixtureGeneration _ -> True
  unless valid (Left InvalidGeneration)
  mapM_ checkSession sessionRows
  mapM_ (checkWindowRef . (.ref)) windowRows
  mapM_ checkPane paneRows
  mapM_ checkLink linkRows
  sessions <- uniqueBy (.ref) ConflictingSession sessionRows
  windows <- uniqueBy (.ref) ConflictingWindow windowRows
  panes <- uniqueBy (.ref) ConflictingPane paneRows
  links <- foldM insertLink Map.empty linkRows
  let sessionLinks = Map.map (sortOn (\row -> (row.index, row.window))) $
        Map.fromListWith (<>) [(row.session, [row]) | row <- Map.elems links]
      windowPanes = Map.map (sortOn (\row -> (row.index, row.ref))) $
        Map.fromListWith (<>) [(row.window, [row]) | row <- Map.elems panes]
      graph = EntityGraph {generation, sessions, windows, panes, links, sessionLinks, windowPanes}
      linkedWindows = Set.fromList [row.window | row <- Map.elems links]
  mapM_ (\row -> first InvalidReference
    (lookupSession graph row.session >> lookupWindow graph row.window)) (Map.elems links)
  mapM_ (\row -> first InvalidReference (lookupWindow graph row.window)) (Map.elems panes)
  void (foldM checkPaneIndex Set.empty (Map.elems panes))
  mapM_ (checkSessionSelection sessionLinks) (Map.keys sessions)
  mapM_ (checkWindowSelection linkedWindows windowPanes) (Map.keys windows)
  graph `deepseq` Right graph
  where
    checkGeneration actual = unless (actual == generation) (Left (InvalidReference ForeignGeneration))
    checkSessionRef (SessionRef actual _) = checkGeneration actual
    checkWindowRef (WindowRef actual _) = checkGeneration actual
    checkSession row = do
      checkSessionRef row.ref
      when (row.attached < 0) (Left (InvalidAttachedCount row.ref row.attached))
    checkPane row = do
      let PaneRef actual _ = row.ref
      checkGeneration actual
      checkWindowRef row.window
    checkLink row = checkSessionRef row.session >> checkWindowRef row.window
    insertLink rows row
      | Map.member (row.session, row.index) rows = Left (DuplicateWindowSlot row.session row.index)
      | otherwise = Right (Map.insert (row.session, row.index) row rows)
    checkPaneIndex seen row
      | Set.member (row.window, row.index) seen = Left (DuplicatePaneIndex row.window row.index)
      | otherwise = Right (Set.insert (row.window, row.index) seen)
    checkSessionSelection rows ref =
      let selected = length (filter (.active) (Map.findWithDefault [] ref rows))
      in unless (selected == 1) (Left (InvalidSessionSelection ref selected))
    checkWindowSelection linked rows ref = do
      unless (Set.member ref linked) (Left (UnlinkedWindow ref))
      let selected = length (filter (.active) (Map.findWithDefault [] ref rows))
      unless (selected == 1) (Left (InvalidPaneSelection ref selected))

uniqueBy :: (Ord key, Eq row) => (row -> key) -> (key -> GraphError) -> [row] -> Either GraphError (Map key row)
uniqueBy key conflict = foldM insert Map.empty
  where
    insert rows row = case Map.lookup (key row) rows of
      Nothing -> Right (Map.insert (key row) row rows)
      Just old | old == row -> Right rows
      Just _ -> Left (conflict (key row))

graphSessions :: EntityGraph -> [Session]
graphSessions graph = Map.elems graph.sessions

graphWindows :: EntityGraph -> [Window]
graphWindows graph = Map.elems graph.windows

graphPanes :: EntityGraph -> [Pane]
graphPanes graph = Map.elems graph.panes

graphLinks :: EntityGraph -> [WindowLink]
graphLinks graph = Map.elems graph.links

graphOccurrences :: EntityGraph -> [PaneOccurrence]
graphOccurrences graph =
  [ PaneOccurrence pane link
  | link <- graphLinks graph
  , pane <- Map.findWithDefault [] link.window graph.windowPanes
  ]

lookupSession :: EntityGraph -> SessionRef -> Either LookupError Session
lookupSession graph ref@(SessionRef generation _)
  | generation /= graph.generation = Left ForeignGeneration
  | otherwise = maybe (Left (MissingSession ref)) Right (Map.lookup ref graph.sessions)

lookupWindow :: EntityGraph -> WindowRef -> Either LookupError Window
lookupWindow graph ref@(WindowRef generation _)
  | generation /= graph.generation = Left ForeignGeneration
  | otherwise = maybe (Left (MissingWindow ref)) Right (Map.lookup ref graph.windows)

lookupPane :: EntityGraph -> PaneRef -> Either LookupError Pane
lookupPane graph ref@(PaneRef generation _)
  | generation /= graph.generation = Left ForeignGeneration
  | otherwise = maybe (Left (MissingPane ref)) Right (Map.lookup ref graph.panes)

linksForSession :: EntityGraph -> SessionRef -> Either LookupError [WindowLink]
linksForSession graph ref = do
  _ <- lookupSession graph ref
  pure (Map.findWithDefault [] ref graph.sessionLinks)

panesForWindow :: EntityGraph -> WindowRef -> Either LookupError [Pane]
panesForWindow graph ref = do
  _ <- lookupWindow graph ref
  pure (Map.findWithDefault [] ref graph.windowPanes)

-- | Resolve the attached listing against its captured graph. A detached Client
-- keeps the resolved observations even after later selection or name reuse.
-- Session attached counts and listing cardinality have different tmux rules;
-- neither is reconstructed from the other.
assembleSnapshot :: ServerInfo -> EntityGraph -> [ClientInput] -> Either GraphError Snapshot
assembleSnapshot info graph inputs = do
  unless (info.generation == graph.generation) (Left (InvalidReference ForeignGeneration))
  unless (positivePid info.pid && info.startedAt >= 0 && info.startedAt <= 9223372036854775807
    && validString info.socketPath && not (Os.null info.socketPath)
    && either (const False) (const True) (Version.requireSupported info.version)) (Left InvalidServerInfo)
  rows <- mapM hydrate inputs
  let snapshot = Snapshot info graph (sortOn (\row -> (row.name, row.pid)) rows) Nothing
  snapshot `deepseq` Right snapshot
  where
    positivePid value = value > 0 && value <= toInteger (maxBound @CInt)
    validString value = Os.length value <= 1048576 && not (any ((== '\NUL') . Os.toChar) (Os.unpack value))
    hydrate input = do
      unless (positivePid input.pid && validString input.name && not (Os.null input.name)
        && maybe True (\path -> validString path && not (Os.null path)) input.tty) (Left InvalidClientMetadata)
      session <- first InvalidReference (lookupSession graph (SessionRef graph.generation input.session))
      window <- first InvalidReference (lookupWindow graph (WindowRef graph.generation input.window))
      pane <- first InvalidReference (lookupPane graph (PaneRef graph.generation input.pane))
      link <- maybe (Left (MissingClientLink session.ref input.index)) Right
        (Map.lookup (session.ref, input.index) graph.links)
      unless (link.window == window.ref && pane.window == window.ref && link.active && pane.active)
        (Left ChangedClientAttachment)
      let attachment = ClientAttachment session window (PaneOccurrence pane link)
      pure (Client input.name input.pid input.tty (Just attachment))
