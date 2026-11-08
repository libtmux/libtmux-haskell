-- | Detached physical entities, contextual links and validated graph indexes.
--
-- Window labels use 'TmuxText'; process names and paths preserve POSIX bytes.
-- Reading an observation or navigating the graph performs no IO.
module LibTmux.Internal.Graph
  ( EndpointIdentity (..), Generation (..)
  , SessionRef (..), WindowRef (..), PaneRef (..)
  , Session (..), Window (..), Pane (..), WindowLink (..), PaneOccurrence (..)
  , EntityGraph, GraphError (..), assembleEntityGraph
  , graphSessions, graphWindows, graphPanes, graphLinks, graphOccurrences
  , lookupSession, lookupWindow, lookupPane, linksForSession, panesForWindow
  ) where

import Control.DeepSeq (NFData (rnf), deepseq)
import Control.Monad (foldM, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.Generics (Generic)
import LibTmux.Id (PaneId, SessionId, WindowId)
import LibTmux.Internal.TmuxText (TmuxText)
import LibTmux.Value (Dimension, PaneIndex, WindowIndex)
import System.OsPath.Posix (PosixPath)
import System.OsString.Posix (PosixString)

data EndpointIdentity = EndpointIdentity !Integer !Integer
  deriving stock (Eq, Ord, Show)
instance NFData EndpointIdentity where
  rnf (EndpointIdentity device inode) = rnf device `seq` rnf inode

data Generation = Generation !EndpointIdentity !ByteString
  deriving stock (Eq, Ord, Show)
instance NFData Generation where
  rnf (Generation endpoint token) = rnf endpoint `seq` rnf token

data SessionRef = SessionRef !Generation !SessionId
  deriving stock (Eq, Ord, Show)
instance NFData SessionRef where
  rnf (SessionRef generation ident) = rnf generation `seq` rnf ident

data WindowRef = WindowRef !Generation !WindowId
  deriving stock (Eq, Ord, Show)
instance NFData WindowRef where
  rnf (WindowRef generation ident) = rnf generation `seq` rnf ident

data PaneRef = PaneRef !Generation !PaneId
  deriving stock (Eq, Ord, Show)
instance NFData PaneRef where
  rnf (PaneRef generation ident) = rnf generation `seq` rnf ident

data Session = Session
  { ref :: !SessionRef
  , name :: !Text
  , attached :: !Integer
  }
  deriving stock (Eq, Show, Generic)
instance NFData Session

data Window = Window
  { ref :: !WindowRef
  , name :: !TmuxText -- ^ Reported bytes, including non-text names on older tmux.
  , width :: !Dimension
  , height :: !Dimension
  }
  deriving stock (Eq, Show, Generic)
instance NFData Window

data Pane = Pane
  { ref :: !PaneRef
  , window :: !WindowRef
  , index :: !PaneIndex
  , width :: !Dimension
  , height :: !Dimension
  , active :: !Bool
  , dead :: !Bool
  , title :: !Text
  , currentCommand :: !PosixString -- ^ Reported process name; tmux may normalize it.
  , currentPath :: !PosixPath -- ^ Endpoint data, without local path interpretation.
  }
  deriving stock (Eq, Show, Generic)
instance NFData Pane

data WindowLink = WindowLink
  { session :: !SessionRef
  , index :: !WindowIndex
  , window :: !WindowRef
  , active :: !Bool
  }
  deriving stock (Eq, Show, Generic)
instance NFData WindowLink

data PaneOccurrence = PaneOccurrence
  { pane :: !Pane
  , link :: !WindowLink
  }
  deriving stock (Eq, Show, Generic)
instance NFData PaneOccurrence

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

data GraphError
  = InvalidGeneration
  | ForeignGeneration
  | MissingSession !SessionRef
  | MissingWindow !WindowRef
  | MissingPane !PaneRef
  | ConflictingSession !SessionRef
  | ConflictingWindow !WindowRef
  | ConflictingPane !PaneRef
  | DuplicateWindowSlot !SessionRef !WindowIndex
  | DuplicatePaneIndex !WindowRef !PaneIndex
  | InvalidAttachedCount !SessionRef !Integer
  | InvalidSessionSelection !SessionRef !Int
  | InvalidPaneSelection !WindowRef !Int
  | UnlinkedWindow !WindowRef
  deriving stock (Eq, Show)

assembleEntityGraph
  :: Generation -> [Session] -> [Window] -> [Pane] -> [WindowLink]
  -> Either GraphError EntityGraph
assembleEntityGraph generation sessionRows windowRows paneRows linkRows = do
  let Generation (EndpointIdentity device inode) token = generation
  unless (device >= 0 && inode >= 0 && Bytes.length token == 32) (Left InvalidGeneration)
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
  mapM_ (\row -> lookupSession graph row.session >> lookupWindow graph row.window) (Map.elems links)
  mapM_ (lookupWindow graph . (.window)) (Map.elems panes)
  void (foldM checkPaneIndex Set.empty (Map.elems panes))
  mapM_ (checkSessionSelection sessionLinks) (Map.keys sessions)
  mapM_ (checkWindowSelection linkedWindows windowPanes) (Map.keys windows)
  graph `deepseq` Right graph
  where
    checkGeneration actual = unless (actual == generation) (Left ForeignGeneration)
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

lookupSession :: EntityGraph -> SessionRef -> Either GraphError Session
lookupSession graph ref@(SessionRef generation _)
  | generation /= graph.generation = Left ForeignGeneration
  | otherwise = maybe (Left (MissingSession ref)) Right (Map.lookup ref graph.sessions)

lookupWindow :: EntityGraph -> WindowRef -> Either GraphError Window
lookupWindow graph ref@(WindowRef generation _)
  | generation /= graph.generation = Left ForeignGeneration
  | otherwise = maybe (Left (MissingWindow ref)) Right (Map.lookup ref graph.windows)

lookupPane :: EntityGraph -> PaneRef -> Either GraphError Pane
lookupPane graph ref@(PaneRef generation _)
  | generation /= graph.generation = Left ForeignGeneration
  | otherwise = maybe (Left (MissingPane ref)) Right (Map.lookup ref graph.panes)

linksForSession :: EntityGraph -> SessionRef -> Either GraphError [WindowLink]
linksForSession graph ref = do
  _ <- lookupSession graph ref
  pure (Map.findWithDefault [] ref graph.sessionLinks)

panesForWindow :: EntityGraph -> WindowRef -> Either GraphError [Pane]
panesForWindow graph ref = do
  _ <- lookupWindow graph ref
  pure (Map.findWithDefault [] ref graph.windowPanes)
