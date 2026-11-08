-- | One bounded format expansion for the private physical/link graph.
--
-- Typed layouts drive both 'graphFormat' and 'decodeGraph'. Each field is
-- evaluated once in its tagged unit, decoded through the catalogue and copied
-- into owned values. Context, repeated observations and graph laws are checked
-- before return. ServerInfo and attached clients are outside this profile.
module LibTmux.Internal.Record (RecordError (..), graphFormat, decodeGraph) where

import Control.Exception (Exception)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text.Encoding qualified as Utf8
import LibTmux.Internal.Field qualified as Field
import LibTmux.Internal.Frame qualified as Frame
import LibTmux.Internal.Graph qualified as G
import LibTmux.Value qualified as Value

data RecordError
  = RecordWireLimit !Int
  | RecordEntityLimit !Int
  | MalformedRecord
  | InvalidRecordContext
  | InvalidRecordScalar !Frame.FrameError
  | InvalidRecordField !Field.FieldError
  | InvalidRecordGraph !G.GraphError
  deriving stock (Eq, Show)
instance Exception RecordError

-- The constructor's argument list has exactly the layout's field types.
data Layout row constructor where
  End :: Layout row row
  (:>) :: !(Field.Field row value) -> !(Layout row constructor) -> Layout row (value -> constructor)
infixr 5 :>

data Row row where
  Row :: !(Layout row constructor) -> constructor -> Row row

sessionRow :: G.Generation -> Row G.Session
sessionRow generation = Row
  (Field.SessionId :> Field.SessionName :> Field.SessionAttached :> End)
  (\ident name attached -> G.Session (G.SessionRef generation ident) name attached)

windowRow :: G.Generation -> Row G.Window
windowRow generation = Row
  (Field.WindowId :> Field.WindowName :> Field.WindowWidth :> Field.WindowHeight :> End)
  (\ident -> G.Window (G.WindowRef generation ident))

linkRow :: G.Generation -> Row G.WindowLink
linkRow generation = Row
  (Field.LinkSession :> Field.LinkWindow :> Field.LinkIndex :> Field.LinkActive :> End)
  (\session window index active -> G.WindowLink (G.SessionRef generation session)
    index (G.WindowRef generation window) active)

paneRow :: G.Generation -> Row G.Pane
paneRow generation = Row
  (Field.PaneId :> Field.PaneWindow :> Field.PaneIndex :> Field.PaneWidth
    :> Field.PaneHeight :> Field.PaneActive :> Field.PaneDead :> Field.PaneTitle
    :> Field.PaneCommand :> Field.PanePath :> End)
  (\pane window -> G.Pane (G.PaneRef generation pane) (G.WindowRef generation window))

-- | Generate S/W/P loops present in tmux 3.3. Physical rows repeat through
-- linked windows; the decoder admits them only when every value agrees.
graphFormat :: G.Generation -> Frame.Nonce -> ByteString
graphFormat generation nonce = marker <> ":G:1\n"
  <> "#{S:" <> rowFormat "S" (sessionRow generation)
  <> "#{W:" <> rowFormat "W" (windowRow generation) <> rowFormat "L" (linkRow generation)
  <> "#{P:" <> rowFormat "P" (paneRow generation) <> "}}}"
  <> marker <> ":Z"
  where
    marker = Frame.recordMarker nonce
    rowFormat :: ByteString -> Row row -> ByteString
    rowFormat tag (Row layout _) = marker <> ":" <> tag <> "\n"
      <> fields layout <> marker <> ":E\n"
    fields :: Layout row constructor -> ByteString
    fields End = ""
    fields (selected :> rest) = marker <> ":F:" <> Utf8.encodeUtf8 (Field.fieldKey selected)
      <> ":" <> Frame.escapedRecordFieldFormat (Field.formatVariable selected)
      <> ":" <> marker <> "\n" <> fields rest

data Rows = Rows
  { sessions :: !(Map G.SessionRef G.Session)
  , windows :: !(Map G.WindowRef G.Window)
  , panes :: !(Map G.PaneRef G.Pane)
  , links :: !(Map (G.SessionRef, Value.WindowIndex) G.WindowLink)
  , sessionContext :: !(Maybe G.SessionRef)
  , windowContext :: !(Maybe G.WindowRef)
  , pendingLink :: !(Maybe G.WindowRef)
  }

-- | Decode the entire response, including its command-added LF. Unknown tags,
-- wrong field order, extra output and inconsistent context are errors.
decodeGraph :: G.Generation -> Frame.Nonce -> ByteString -> Either RecordError G.EntityGraph
decodeGraph generation nonce bytes = do
  when (Bytes.length bytes > 1048576) (Left (RecordWireLimit (Bytes.length bytes)))
  body <- consume (marker <> ":G:1\n") bytes
  rows <- records (Rows Map.empty Map.empty Map.empty Map.empty Nothing Nothing Nothing) body
  graphError (G.assembleEntityGraph generation (Map.elems rows.sessions)
    (Map.elems rows.windows) (Map.elems rows.panes) (Map.elems rows.links))
  where
    marker = Frame.recordMarker nonce
    records rows input
      | input == marker <> ":Z\n" = do
          unless (rows.pendingLink == Nothing) (Left InvalidRecordContext)
          pure rows
      | otherwise = do
          rest <- consume (marker <> ":") input
          case Bytes.break (== 10) rest of
            ("S", tailBytes) -> do
              unless (rows.pendingLink == Nothing) (Left InvalidRecordContext)
              (row, after) <- parseRow (sessionRow generation) =<< consume "\n" tailBytes
              when (Map.member row.ref rows.sessions) (Left InvalidRecordContext)
              next rows {sessions = Map.insert row.ref row rows.sessions,
                sessionContext = Just row.ref, windowContext = Nothing} after
            ("W", tailBytes) -> do
              unless (rows.sessionContext /= Nothing && rows.pendingLink == Nothing) (Left InvalidRecordContext)
              (row, after) <- parseRow (windowRow generation) =<< consume "\n" tailBytes
              values <- insert row.ref row G.ConflictingWindow rows.windows
              next rows {windows = values, windowContext = Nothing, pendingLink = Just row.ref} after
            ("L", tailBytes) -> do
              (row, after) <- parseRow (linkRow generation) =<< consume "\n" tailBytes
              unless (Just row.session == rows.sessionContext && Just row.window == rows.pendingLink)
                (Left InvalidRecordContext)
              when (Map.member (row.session, row.index) rows.links)
                (Left (InvalidRecordGraph (G.DuplicateWindowSlot row.session row.index)))
              next rows {links = Map.insert (row.session, row.index) row rows.links,
                windowContext = Just row.window, pendingLink = Nothing} after
            ("P", tailBytes) -> do
              (row, after) <- parseRow (paneRow generation) =<< consume "\n" tailBytes
              unless (Just row.window == rows.windowContext && rows.pendingLink == Nothing)
                (Left InvalidRecordContext)
              values <- insert row.ref row G.ConflictingPane rows.panes
              next rows {panes = values} after
            _ -> Left MalformedRecord
    next rows rest = do
      let count = Map.size rows.sessions + Map.size rows.windows + Map.size rows.panes + Map.size rows.links
      when (count > 10000) (Left (RecordEntityLimit count))
      records rows rest
    parseRow :: Row row -> ByteString -> Either RecordError (row, ByteString)
    parseRow (Row layout build) input = do
      (row, rest) <- parseFields layout build input
      after <- consume (marker <> ":E\n") rest
      pure (row, after)
    parseFields :: Layout row constructor -> constructor -> ByteString -> Either RecordError (row, ByteString)
    parseFields End row input = Right (row, input)
    parseFields (selected :> rest) build input = do
      body <- consume (marker <> ":F:" <> Utf8.encodeUtf8 (Field.fieldKey selected) <> ":") input
      let (valueAndColon, tailBytes) = Bytes.breakSubstring marker body
      encoded <- maybe (Left MalformedRecord) Right (Bytes.stripSuffix ":" valueAndColon)
      after <- consume (marker <> "\n") tailBytes
      decoded <- either (Left . InvalidRecordScalar) Right
        (Frame.decodeEscapedRecordField nonce 1048576 encoded)
      value <- either (Left . InvalidRecordField) Right (Field.decodeField selected decoded)
      parseFields rest (build value) after

consume :: ByteString -> ByteString -> Either RecordError ByteString
consume prefix = maybe (Left MalformedRecord) Right . Bytes.stripPrefix prefix

graphError :: Either G.GraphError value -> Either RecordError value
graphError = either (Left . InvalidRecordGraph) Right

insert :: (Ord key, Eq row) => key -> row -> (key -> G.GraphError)
  -> Map key row -> Either RecordError (Map key row)
insert key row conflict rows = case Map.lookup key rows of
  Nothing -> Right (Map.insert key row rows)
  Just previous | row == previous -> Right rows
  Just _ -> Left (InvalidRecordGraph (conflict key))
