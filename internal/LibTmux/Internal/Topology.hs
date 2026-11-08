-- | The numeric-only entity topology protocol, before text-field hydration.
module LibTmux.Internal.Topology (TopologyError (..), topologyFormat, decodeTopology) where

import Control.Exception (Exception)
import Control.Monad (foldM, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding qualified as Utf8
import LibTmux.Id qualified as Id
import LibTmux.Internal.Graph qualified as G
import LibTmux.Value qualified as Value

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
topologyFormat = "#{S:S\t#{session_id}\t#{session_attached}\n"
  <> "#{W:W\t#{session_id}\t#{window_id}\t#{window_index}\t#{window_active}"
  <> "\t#{window_width}\t#{window_height}\n"
  <> "#{P:P\t#{window_id}\t#{pane_id}\t#{pane_index}\t#{pane_width}"
  <> "\t#{pane_height}\t#{pane_active}\t#{pane_dead}\n}}}"

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
    sessionId = fmap (G.SessionRef generation) . ident Id.parseSessionId
    windowId = fmap (G.WindowRef generation) . ident Id.parseWindowId
    paneId = fmap (G.PaneRef generation) . ident Id.parsePaneId
    step rows line = do
      result <- case Ascii.split '\t' line of
        ["S", sid, attached] -> do
          ref <- sessionId sid
          count <- natural 4294967295 attached
          values <- insert ref (G.Session ref "" count) G.ConflictingSession rows.sessions
          pure rows {sessions = values}
        ["W", sid, wid, index, active, width, height] -> do
          session <- sessionId sid
          window <- windowId wid
          position <- checked Value.mkWindowIndex =<< natural 2147483647 index
          selected <- boolean active
          w <- dimension width
          h <- dimension height
          values <- insert window (G.Window window "" w h) G.ConflictingWindow rows.windows
          when (Map.member (session, position) rows.links)
            (Left (TopologyGraphError (G.DuplicateWindowSlot session position)))
          pure rows {windows = values, links = Map.insert (session, position)
            (G.WindowLink session position window selected) rows.links}
        ["P", wid, pid, index, width, height, active, dead] -> do
          window <- windowId wid
          pane <- paneId pid
          position <- checked Value.mkPaneIndex =<< natural 4294967295 index
          w <- dimension width
          h <- dimension height
          selected <- boolean active
          exited <- boolean dead
          values <- insert pane (G.Pane pane window position w h selected exited "" "" "")
            G.ConflictingPane rows.panes
          pure rows {panes = values}
        _ -> Left MalformedTopology
      let count = Map.size result.sessions + Map.size result.windows
            + Map.size result.panes + Map.size result.links
      when (count > 10000) (Left (TopologyEntityLimit count))
      pure result

ident :: (Text -> Either Id.IdError a) -> ByteString -> Either TopologyError a
ident parse bytes
  | Bytes.length bytes > 11 = Left MalformedTopology
  | otherwise = either (const (Left MalformedTopology)) Right (parse (Utf8.decodeLatin1 bytes))

natural :: Integer -> ByteString -> Either TopologyError Integer
natural upper bytes
  | Bytes.null bytes || Bytes.length bytes > 10
    || not (Bytes.all (\byte -> byte >= 48 && byte <= 57) bytes) = Left MalformedTopology
  | otherwise = case Ascii.readInteger bytes of
      Just (value, "") | value <= upper -> Right value
      _ -> Left MalformedTopology

boolean :: ByteString -> Either TopologyError Bool
boolean "0" = Right False
boolean "1" = Right True
boolean _ = Left MalformedTopology

dimension :: ByteString -> Either TopologyError Value.Dimension
dimension bytes = checked Value.mkDimension =<< natural 4294967295 bytes

checked :: (Integer -> Either Value.ValueError a) -> Integer -> Either TopologyError a
checked build = either (const (Left MalformedTopology)) Right . build

graphResult :: Either G.GraphError a -> Either TopologyError a
graphResult = either (Left . TopologyGraphError) Right

insert :: (Ord key, Eq row) => key -> row -> (key -> G.GraphError)
  -> Map key row -> Either TopologyError (Map key row)
insert key row conflict rows = case Map.lookup key rows of
  Nothing -> Right (Map.insert key row rows)
  Just previous | row == previous -> Right rows
  Just _ -> Left (TopologyGraphError (conflict key))
