-- | Closed field identities for the private observation profile.
--
-- Each 'Field' fixes its row and value types. Its descriptor supplies the
-- tmux variable, 'WireType' and pure 'project' operation together; transport
-- and local evaluation must not define independent field mappings.
-- 'decodeField' consumes already unescaped bytes, without trimming or IO.
module LibTmux.Internal.Field
  ( Field (..), WireType (..), FieldError (..), FieldFailure (..)
  , fieldKey, formatVariable, wireType, minimumTmux, project, decodeField
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Utf8
import LibTmux.Id qualified as Id
import LibTmux.Internal.Graph qualified as G
import LibTmux.Internal.TmuxText qualified as Label
import LibTmux.Value qualified as V
import System.OsPath.Posix (PosixPath)
import System.OsString.Posix (PosixString)
import System.OsString.Posix qualified as Os

-- | Fields belong to physical rows or contextual links, never both implicitly.
data Field row value where
  SessionId :: Field G.Session Id.SessionId
  SessionName :: Field G.Session Text
  SessionAttached :: Field G.Session Integer
  WindowId :: Field G.Window Id.WindowId
  WindowName :: Field G.Window Label.TmuxText
  WindowWidth :: Field G.Window V.Dimension
  WindowHeight :: Field G.Window V.Dimension
  PaneId :: Field G.Pane Id.PaneId
  PaneWindow :: Field G.Pane Id.WindowId
  PaneIndex :: Field G.Pane V.PaneIndex
  PaneWidth :: Field G.Pane V.Dimension
  PaneHeight :: Field G.Pane V.Dimension
  PaneActive :: Field G.Pane Bool
  PaneDead :: Field G.Pane Bool
  PaneTitle :: Field G.Pane Text
  PaneCommand :: Field G.Pane PosixString
  PanePath :: Field G.Pane PosixPath
  LinkSession :: Field G.WindowLink Id.SessionId
  LinkWindow :: Field G.WindowLink Id.WindowId
  LinkIndex :: Field G.WindowLink V.WindowIndex
  LinkActive :: Field G.WindowLink Bool

-- | Checked wire domains. POSIX path and string share a representation but
-- retain different descriptors; neither promises local filesystem semantics.
data WireType value where
  SessionIdValue :: WireType Id.SessionId
  WindowIdValue :: WireType Id.WindowId
  PaneIdValue :: WireType Id.PaneId
  TextValue :: WireType Text
  LabelValue :: WireType Label.TmuxText
  PosixStringValue :: WireType PosixString
  PosixPathValue :: WireType PosixPath
  DimensionValue :: WireType V.Dimension
  PaneIndexValue :: WireType V.PaneIndex
  WindowIndexValue :: WireType V.WindowIndex
  AttachedCountValue :: WireType Integer
  BooleanValue :: WireType Bool

data Descriptor row value = Descriptor !Text !ByteString !(WireType value) !(row -> value)

descriptor :: Field row value -> Descriptor row value
descriptor = \case
  SessionId -> Descriptor "session.id" "session_id" SessionIdValue (sessionId . (.ref))
  SessionName -> Descriptor "session.name" "session_name" TextValue (.name)
  SessionAttached -> Descriptor "session.attached" "session_attached" AttachedCountValue (.attached)
  WindowId -> Descriptor "window.id" "window_id" WindowIdValue (windowId . (.ref))
  WindowName -> Descriptor "window.name" "window_name" LabelValue (.name)
  WindowWidth -> Descriptor "window.width" "window_width" DimensionValue (.width)
  WindowHeight -> Descriptor "window.height" "window_height" DimensionValue (.height)
  PaneId -> Descriptor "pane.id" "pane_id" PaneIdValue (paneId . (.ref))
  PaneWindow -> Descriptor "pane.window" "window_id" WindowIdValue (windowId . (.window))
  PaneIndex -> Descriptor "pane.index" "pane_index" PaneIndexValue (.index)
  PaneWidth -> Descriptor "pane.width" "pane_width" DimensionValue (.width)
  PaneHeight -> Descriptor "pane.height" "pane_height" DimensionValue (.height)
  PaneActive -> Descriptor "pane.active" "pane_active" BooleanValue (.active)
  PaneDead -> Descriptor "pane.dead" "pane_dead" BooleanValue (.dead)
  PaneTitle -> Descriptor "pane.title" "pane_title" TextValue (.title)
  PaneCommand -> Descriptor "pane.currentCommand" "pane_current_command" PosixStringValue (.currentCommand)
  PanePath -> Descriptor "pane.currentPath" "pane_current_path" PosixPathValue (.currentPath)
  LinkSession -> Descriptor "windowLink.session" "session_id" SessionIdValue (sessionId . (.session))
  LinkWindow -> Descriptor "windowLink.window" "window_id" WindowIdValue (windowId . (.window))
  LinkIndex -> Descriptor "windowLink.index" "window_index" WindowIndexValue (.index)
  LinkActive -> Descriptor "windowLink.active" "window_active" BooleanValue (.active)

sessionId :: G.SessionRef -> Id.SessionId
sessionId (G.SessionRef _ ident) = ident

windowId :: G.WindowRef -> Id.WindowId
windowId (G.WindowRef _ ident) = ident

paneId :: G.PaneRef -> Id.PaneId
paneId (G.PaneRef _ ident) = ident

-- | Stable model-qualified key; independent of the Haskell constructor name.
fieldKey :: Field row value -> Text
fieldKey field = case descriptor field of Descriptor key _ _ _ -> key

-- | Trusted tmux variable name, without format delimiters or caller input.
formatVariable :: Field row value -> ByteString
formatVariable field = case descriptor field of Descriptor _ variable _ _ -> variable

-- | Type evidence for decoding and future typed query interpretation.
wireType :: Field row value -> WireType value
wireType field = case descriptor field of Descriptor _ _ valueType _ -> valueType

-- | Minimum qualified profile, not the release that introduced each variable.
-- Every field in this finite profile is available at the tmux 3.3 floor.
minimumTmux :: Field row value -> Text
minimumTmux _ = "3.3"

-- | Read an owned observation. This never navigates a graph or contacts tmux.
project :: Field row value -> row -> value
project field = case descriptor field of Descriptor _ _ _ get -> get

-- | A bounded diagnostic identifies the field without retaining its input.
data FieldError = FieldError !Text !FieldFailure
  deriving stock (Eq, Show)

data FieldFailure = InvalidSyntax | InvalidEncoding | UnexpectedNul | ValueTooLarge !Int
  deriving stock (Eq, Show)

-- | Validate decoded scalar bytes, retaining exact byte-bearing values.
-- One MiB is the current scalar payload ceiling. Numeric ranges follow tmux
-- storage domains; the public mathematical newtypes have separate constructors.
decodeField :: Field row value -> ByteString -> Either FieldError value
decodeField field bytes
  | Bytes.length bytes > 1048576 = failure (ValueTooLarge (Bytes.length bytes))
  | Bytes.elem 0 bytes = failure UnexpectedNul
  | otherwise = either failure Right (decodeValue (wireType field) bytes)
  where
    failure = Left . FieldError (fieldKey field)

decodeValue :: WireType value -> ByteString -> Either FieldFailure value
decodeValue valueType bytes = case valueType of
  SessionIdValue -> ident Id.parseSessionId
  WindowIdValue -> ident Id.parseWindowId
  PaneIdValue -> ident Id.parsePaneId
  TextValue -> either (const (Left InvalidEncoding)) (Right . Text.copy) (Utf8.decodeUtf8' bytes)
  LabelValue -> Right (Label.fromBytes bytes)
  PosixStringValue -> Right (Os.fromBytestring bytes)
  PosixPathValue -> Right (Os.fromBytestring bytes)
  DimensionValue -> natural 4294967295 >>= checked V.mkDimension
  PaneIndexValue -> natural 4294967295 >>= checked V.mkPaneIndex
  WindowIndexValue -> natural 2147483647 >>= checked V.mkWindowIndex
  AttachedCountValue -> natural 4294967295
  BooleanValue -> case bytes of
    "0" -> Right False
    "1" -> Right True
    _ -> Left InvalidSyntax
  where
    ident :: (Text -> Either error value) -> Either FieldFailure value
    ident parse
      | Bytes.length bytes > 11 = Left InvalidSyntax
      | otherwise = either (const (Left InvalidSyntax)) Right (parse (Utf8.decodeLatin1 bytes))
    natural :: Integer -> Either FieldFailure Integer
    natural upper
      | Bytes.null bytes || Bytes.length bytes > 10
        || not (Bytes.all (\byte -> byte >= 48 && byte <= 57) bytes) = Left InvalidSyntax
      | otherwise = case Ascii.readInteger bytes of
          Just (value, "") | value <= upper -> Right value
          _ -> Left InvalidSyntax
    checked :: (Integer -> Either error value) -> Integer -> Either FieldFailure value
    checked build = either (const (Left InvalidSyntax)) Right . build
