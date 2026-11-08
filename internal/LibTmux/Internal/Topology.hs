-- | The numeric-only entity topology protocol, before text-field hydration.
module LibTmux.Internal.Topology (TopologyError (..), topologyFormat, decodeTopology) where

import Control.Exception (Exception)
import Control.Monad (foldM, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import LibTmux.Internal.Field qualified as Field
import LibTmux.Internal.Graph qualified as G
import LibTmux.Value qualified as Value
import System.OsString.Posix qualified as Os

data TopologyError
  = MalformedTopology
  | TopologyByteLimit !Int
  | TopologyEntityLimit !Int
  | TopologyGraphError !G.GraphError
  deriving stock (Eq, Show)
instance Exception TopologyError

-- S/W/P loops are present in plain tmux 3.3. Only numeric fields enter rows;
-- arbitrary strings are acquired separately inside fresh scalar envelopes.
topologyFormat :: ByteString
topologyFormat = "#{S:" <> row "S" [variable Field.SessionId, variable Field.SessionAttached]
  <> "#{W:" <> row "W" [variable Field.LinkSession, variable Field.WindowId,
    variable Field.LinkIndex, variable Field.LinkActive,
    variable Field.WindowWidth, variable Field.WindowHeight]
  <> "#{P:" <> row "P" [variable Field.PaneWindow, variable Field.PaneId,
    variable Field.PaneIndex, variable Field.PaneWidth, variable Field.PaneHeight,
    variable Field.PaneActive, variable Field.PaneDead] <> "}}}"
  where
    variable :: Field.Field row value -> ByteString
    variable selected = "#{" <> Field.formatVariable selected <> "}"
    row tag fields = tag <> "\t" <> Bytes.intercalate "\t" fields <> "\n"

data Rows = Rows
  { sessions :: !(Map G.SessionRef G.Session)
  , windows :: !(Map G.WindowRef G.Window)
  , panes :: !(Map G.PaneRef G.Pane)
  , links :: !(Map (G.SessionRef, Value.WindowIndex) G.WindowLink)
  }

decodeTopology :: G.Generation -> ByteString -> Either TopologyError G.EntityGraph
decodeTopology generation bytes = do
  when (Bytes.length bytes > 1048576) (Left (TopologyByteLimit (Bytes.length bytes)))
  unless (Bytes.null bytes || Bytes.last bytes == 10) (Left MalformedTopology)
  rows <- foldM step (Rows Map.empty Map.empty Map.empty Map.empty)
    (if Bytes.null bytes then [] else Ascii.split '\n' (Bytes.init bytes))
  graphResult (G.assembleEntityGraph generation (Map.elems rows.sessions)
    (Map.elems rows.windows) (Map.elems rows.panes) (Map.elems rows.links))
  where
    sessionId = fmap (G.SessionRef generation) . field Field.SessionId
    windowId = fmap (G.WindowRef generation) . field Field.WindowId
    paneId = fmap (G.PaneRef generation) . field Field.PaneId
    step rows line = do
      result <- case Ascii.split '\t' line of
        ["S", sid, attached] -> do
          ref <- sessionId sid
          count <- field Field.SessionAttached attached
          values <- insert ref (G.Session ref "" count) G.ConflictingSession rows.sessions
          pure rows {sessions = values}
        ["W", sid, wid, index, active, width, height] -> do
          session <- sessionId sid
          window <- windowId wid
          position <- field Field.LinkIndex index
          selected <- field Field.LinkActive active
          w <- field Field.WindowWidth width
          h <- field Field.WindowHeight height
          values <- insert window (G.Window window "" w h) G.ConflictingWindow rows.windows
          when (Map.member (session, position) rows.links)
            (Left (TopologyGraphError (G.DuplicateWindowSlot session position)))
          pure rows {windows = values, links = Map.insert (session, position)
            (G.WindowLink session position window selected) rows.links}
        ["P", wid, pid, index, width, height, active, dead] -> do
          window <- windowId wid
          pane <- paneId pid
          position <- field Field.PaneIndex index
          w <- field Field.PaneWidth width
          h <- field Field.PaneHeight height
          selected <- field Field.PaneActive active
          exited <- field Field.PaneDead dead
          values <- insert pane (G.Pane pane window position w h selected exited "" Os.empty Os.empty)
            G.ConflictingPane rows.panes
          pure rows {panes = values}
        _ -> Left MalformedTopology
      let count = Map.size result.sessions + Map.size result.windows
            + Map.size result.panes + Map.size result.links
      when (count > 10000) (Left (TopologyEntityLimit count))
      pure result

field :: Field.Field row value -> ByteString -> Either TopologyError value
field selected = either (const (Left MalformedTopology)) Right . Field.decodeField selected

graphResult :: Either G.GraphError a -> Either TopologyError a
graphResult = either (Left . TopologyGraphError) Right

insert :: (Ord key, Eq row) => key -> row -> (key -> G.GraphError)
  -> Map key row -> Either TopologyError (Map key row)
insert key row conflict rows = case Map.lookup key rows of
  Nothing -> Right (Map.insert key row rows)
  Just previous | row == previous -> Right rows
  Just _ -> Left (TopologyGraphError (conflict key))
