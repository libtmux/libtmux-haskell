-- | Private literal mutations and nonce-qualified native creation receipts.
--
-- 'compileMutation' preserves operand bytes through tmux's command and format
-- parsers. 'decodeControlReply' applies only to these synchronous handlers,
-- whose primary success response is empty. The Runtime owns the client until
-- normal exit; later hook output remains opaque to this decoder.
module LibTmux.Internal.Command
  ( Mutation (..), ProgramCommand (..), ProgramIdentity (..), ArgumentError (..), compileMutation
  , compileProgramMutation, decodeProgramReply, NamedLayout (..)
  , compileKeyProbe, decodeKeyProbe
  , ControlDataReply (..), compilePaneCapture, decodeControlData
  , EnvironmentChange (..), compileEnvironmentRead
  , MutationReply (..), ReplyError (..), decodeControlReply
  , SessionReceipt (..), SessionCreationReply (..)
  , SessionOptions (..), InitialProcess (..), defaultSessionOptions
  , compileSessionCreation, sessionCreationFormat, decodeSessionCreation
  , CreationCommand (..), WindowPlacement (..), compileCreation
  ) where

import Control.DeepSeq (NFData (rnf))
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Utf8
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import LibTmux.Creation (SessionOptions (..), InitialProcess (..), defaultSessionOptions)
import LibTmux.Creation qualified as Creation
import LibTmux.Environment (EnvironmentVisibility (..))
import LibTmux.Id qualified as Id
import LibTmux.Internal.Field qualified as Field
import LibTmux.Internal.Frame qualified as Frame
import LibTmux.Internal.TmuxText (TmuxText)
import LibTmux.Internal.TmuxText qualified as Label
import LibTmux.Pane (PaneCaptureOptions (..), PaneRendering (..), PaneRows (..), PasteNewlines (..))
import LibTmux.Snapshot qualified as Snapshot
import LibTmux.Value qualified as Value
import System.OsString.Posix (PosixString)
import System.OsString.Posix qualified as Os

-- | Literal requests with canonical entity targets. Native name validation
-- and normalization remain command outcomes rather than lowering policy.
data Mutation
  = RenameSession !Id.SessionId !Text
  | RenameWindow !Id.WindowId !TmuxText
  | SetPaneTitle !Id.PaneId !Text
  | KillSession !Id.SessionId
  | KillWindow !Id.WindowId
  | KillPane !Id.PaneId
  | SendPaneText !Id.PaneId !Text
  | SendPaneKeys !Id.PaneId !(NonEmpty Text)
  | LinkWindow !Id.SessionId !Value.WindowIndex !Id.SessionId !Value.WindowIndex
  | UnlinkWindow !Id.SessionId !Value.WindowIndex
  | SelectWindowLink !Id.SessionId !Value.WindowIndex
  | SelectExactPane !Id.SessionId !Value.WindowIndex !Id.PaneId
  | SelectLayout !Id.SessionId !Value.WindowIndex !NamedLayout
  | ChangeEnvironment !(Maybe Id.SessionId) !ByteString !EnvironmentChange
  | LoadBuffer !ByteString !ByteString
  | SaveBuffer !ByteString !ByteString
  | PasteBuffer !Id.PaneId !ByteString !PasteNewlines !Bool
  | ResizePane !Id.PaneId !Value.Resize
  | ResizeWindow !Id.WindowId !Value.Resize
  deriving stock (Eq, Show)

data EnvironmentChange
  = SetVariable !EnvironmentVisibility !ByteString
  | MarkVariableRemoved
  | UnsetVariable
  deriving stock (Eq)

instance Show EnvironmentChange where
  show (SetVariable visibility _) = "SetVariable " <> show visibility
  show MarkVariableRemoved = "MarkVariableRemoved"
  show UnsetVariable = "UnsetVariable"

-- | Layout names shared by tmux 3.3a and 3.8.
data NamedLayout = EvenHorizontal | EvenVertical | MainHorizontal | MainVertical | Tiled
  deriving stock (Eq, Show)

-- | Closed application operations. Payload-bearing capture is saved separately
-- so terminal bytes cannot impersonate a control reply or an after-hook.
data ProgramCommand
  = ProgramRemain !Id.PaneId
  | ProgramRemainFormat !Id.PaneId
  | ProgramHistory !Id.SessionId !Int
  | ProgramGeometry !Id.WindowId !Int !Int
  | ProgramCapture !Id.PaneId !ByteString !Int !Int !Int
  | ProgramSave !ByteString !ByteString
  | ProgramDeleteBuffer !ByteString
  | ProgramInputBytes !Id.PaneId !ByteString
  | ProgramKillSession !Id.SessionId
  | ProgramGuarded !ProgramIdentity !ByteString !Bool !ProgramCommand
  deriving stock Eq

data ProgramIdentity = ProgramIdentity !Id.SessionId !Id.WindowId !Id.PaneId !Integer
  deriving stock (Eq, Show)

instance Show ProgramCommand where
  show _ = "ProgramCommand"

-- | Refusal before a command tail exists, carrying its catalogue field key.
data ArgumentError
  = NulOperand !Text | EncodedCommandTooLarge !Text | InvalidOperand !Text !Text
  deriving stock (Eq, Show)

-- | Closed creation requests. The public facade checks every generation;
-- the compiler retains exact contextual targets without observing the daemon.
data CreationCommand
  = NewSession !SessionOptions
  | NewWindow !WindowPlacement !Creation.WindowOptions
  | SplitPane !Id.SessionId !Value.WindowIndex !Id.PaneId !Creation.SplitOptions
  deriving stock (Eq)

data WindowPlacement
  = NextFree !Id.SessionId
  | At !Id.SessionId !Value.WindowIndex
  | Before !Id.SessionId !Value.WindowIndex
  | After !Id.SessionId !Value.WindowIndex
  deriving stock (Eq)

compileCreation :: Frame.Nonce -> CreationCommand -> Either ArgumentError [ByteString]
compileCreation nonce (NewSession options) = compileSessionCreation nonce options
compileCreation nonce (NewWindow placement options) = do
  (target, insertion) <- case placement of
    NextFree session -> Right (creationSessionTarget session <> ":", [])
    At session index -> (, []) <$> slotBytes session index
    Before session index -> (, ["-b"]) <$> slotBytes session index
    After session index -> do
      when (Value.windowIndexValue index == 2147483647)
        (Left (InvalidOperand "window.index" "cannot insert after 2147483647"))
      (, ["-a"]) <$> slotBytes session index
  compileSpawn "window.creation"
    (map (literal "window.creation")
       (["new-window"] <> ["-d" | not options.selectWindow]
        <> ["-P", "-F", sessionCreationFormat nonce, "-t", target]
        <> insertion <> ["-k" | options.collision == Creation.ReplaceOccupied])
     <> optional "window.name" "-n" Snapshot.labelBytes options.windowLabel
     <> optional "workingDirectory" "-c" osBytes options.windowDirectory)
    options.windowEnvironment options.windowProcess
compileCreation nonce (SplitPane session index pane options) = do
  target <- paneSlotBytes session index pane
  size <- case options.size of
    Creation.DefaultSplitSize -> Right []
    Creation.SplitCells cells
      | Value.dimensionValue cells > 2147483647 ->
          Left (InvalidOperand "split.size" "size exceeds 2147483647 cells")
      | otherwise -> Right ["-l", Ascii.pack (show (Value.dimensionValue cells))]
    Creation.SplitPercent percentage
      | percentage < 1 || percentage > 100 ->
          Left (InvalidOperand "split.size" "percentage must be between 1 and 100")
      | otherwise -> Right ["-l", Ascii.pack (show percentage) <> "%"]
  compileSpawn "pane.creation"
    (map (literal "pane.creation")
       (["split-window"] <> ["-d" | not options.selectPane]
        <> ["-P", "-F", sessionCreationFormat nonce,
            "-t", target]
        <> ["-h" | options.direction == Creation.LeftRight]
        <> ["-b" | options.before] <> ["-f" | options.fullWindow]
        <> ["-Z" | options.zoom] <> size)
     <> optional "workingDirectory" "-c" osBytes options.splitDirectory)
    options.splitEnvironment options.splitProcess

creationSessionTarget :: Id.SessionId -> ByteString
creationSessionTarget = Utf8.encodeUtf8 . Id.renderSessionId

slotBytes :: Id.SessionId -> Value.WindowIndex -> Either ArgumentError ByteString
slotBytes session index = do
  when (Value.windowIndexValue index > 2147483647)
    (Left (InvalidOperand "window.index" "index exceeds 2147483647"))
  pure (creationSessionTarget session <> ":" <> Ascii.pack (show (Value.windowIndexValue index)))

paneSlotBytes :: Id.SessionId -> Value.WindowIndex -> Id.PaneId -> Either ArgumentError ByteString
paneSlotBytes session index pane = do
  target <- slotBytes session index
  pure (target <> "." <> Utf8.encodeUtf8 (Id.renderPaneId pane))

-- | Validate and lower one detached creation, including its receipt format.
-- Command argv must fit one native tmux message, including NUL terminators.
-- The native layer independently bounds the full launch vector before admission.
-- Paths and names expand once in tmux; environment and process argv do not.
compileSessionCreation :: Frame.Nonce -> SessionOptions -> Either ArgumentError [ByteString]
compileSessionCreation nonce options = do
  columns <- dimension "width" "-x" options.width
  rows <- dimension "height" "-y" options.height
  compileSpawn "session.creation"
    (map (literal "session.creation") ["new-session", "-d", "-P", "-F", sessionCreationFormat nonce]
     <> optional "session.name" "-s" Utf8.encodeUtf8 options.name
     <> optional "window.name" "-n" Snapshot.labelBytes options.windowName
     <> optional "workingDirectory" "-c" osBytes options.workingDirectory
     <> columns <> rows
     <> [literal "session.creation" "-E" | not options.updateEnvironment])
    options.environment options.process
  where
    dimension key flag = maybe (Right []) $ \value ->
      if Value.dimensionValue value > 65535
        then Left (InvalidOperand key "dimension exceeds 65535 cells")
        else Right [literal key flag, literal key (Ascii.pack (show (Value.dimensionValue value)))]

type Argument = (Text, Bool, ByteString)

literal :: Text -> ByteString -> Argument
literal key value = (key, False, value)

optional :: Text -> ByteString -> (value -> ByteString) -> Maybe value -> [Argument]
optional key flag encode = maybe [] (\value -> [literal key flag, (key, True, encode value)])

compileSpawn :: Text -> [Argument] -> [(PosixString, PosixString)] -> InitialProcess -> Either ArgumentError [ByteString]
compileSpawn operation prefix environment initialProcess = do
  unless (length (take 4097 environment) <= 4096)
    (Left (InvalidOperand "environment" "variable count exceeds 4096"))
  process <- case initialProcess of
    DefaultProcess -> Right []
    ShellCommand command -> Right [literal "initialProcess" command]
    DirectCommand executable arguments -> do
      unless (length (take 4097 (NonEmpty.toList arguments)) <= 4096)
        (Left (InvalidOperand "initialProcess" "argument count exceeds 4096"))
      when (Os.null executable) (Left (InvalidOperand "initialProcess" "empty executable"))
      Right (map (literal "initialProcess" . osBytes) (executable : NonEmpty.toList arguments))
  let arguments = prefix
        <> concatMap (\(key, value) -> [literal "environment" "-e",
             literal "environment" (osBytes key <> "=" <> osBytes value)]) environment
        <> [literal operation "--"] <> process
      rawCost = sum [toInteger (Bytes.length value) + 1 | (_, _, value) <- arguments]
  -- The native argv also holds the executable, -u, -N, -S, socket and -C.
  when (length arguments + 6 > 4096) (Left (EncodedCommandTooLarge operation))
  when (rawCost > commandLimitBytes) (Left (EncodedCommandTooLarge operation))
  mapM_ (\(key, _, value) -> when (Bytes.elem 0 value) (Left (NulOperand key))) arguments
  mapM_ (\(key, _) -> when (Os.null key || Bytes.elem 61 (osBytes key))
    (Left (InvalidOperand "environment" "invalid variable name"))) environment
  let expansion = sum [if format then 6 * toInteger (Bytes.count 35 value) else 0 |
        (_, format, value) <- arguments]
        + toInteger (length [() | (_, _, value) <- arguments, endsSeparator value])
  when (rawCost + expansion > commandLimitBytes) (Left (EncodedCommandTooLarge operation))
  pure [protectSeparator (if format then protectFormat value else value) | (_, format, value) <- arguments]

osBytes :: PosixString -> ByteString
osBytes = Bytes.pack . map (fromIntegral . fromEnum . Os.toChar) . Os.unpack

-- | Native queue evidence. An applied command may still have failing hooks;
-- none of these constructors promises rollback or a refreshed observation.
data MutationReply = Applied | Rejected !ByteString | AppliedWithErrors !ByteString
  deriving stock (Eq, Show)

instance NFData MutationReply where
  rnf Applied = ()
  rnf (Rejected diagnostic) = rnf diagnostic
  rnf (AppliedWithErrors diagnostic) = rnf diagnostic

data ReplyError = UnexpectedReply | ReplyTooLarge
  deriving stock (Eq, Show)

-- | IDs printed by session/window creation or a split before its after-hooks.
-- Parent identities can already exist. These fields do not establish
-- current liveness, process exec success or completion of background jobs.
-- 'decodeSessionCreation' retains them independently of completion evidence.
data SessionReceipt = SessionReceipt
  { serverPid :: !Integer
  , sessionId :: !Id.SessionId
  , windowId :: !Id.WindowId
  , paneId :: !Id.PaneId
  , windowIndex :: !Value.WindowIndex
  } deriving stock (Eq, Show)

instance NFData SessionReceipt where
  rnf (SessionReceipt pid session window pane index) =
    rnf pid `seq` rnf (Id.renderSessionId session) `seq`
    rnf (Id.renderWindowId window) `seq` rnf (Id.renderPaneId pane) `seq` rnf index

-- | Primary completion and historical creation evidence are independent.
-- Unknown completion retains a receipt only when its entire nonce line passed.
-- A complete primary rejection takes precedence over receipt-shaped diagnostics.
-- An unknown outcome's receipt carries prefix evidence without completion.
data SessionCreationReply
  = SessionCreated !SessionReceipt
  | SessionCreatedWithErrors !SessionReceipt !ByteString
  | SessionCreationRejected !ByteString
  | SessionCreationUnknown !(Maybe SessionReceipt) !ReplyError
  deriving stock (Eq, Show)

instance NFData SessionCreationReply where
  rnf (SessionCreated receipt) = rnf receipt
  rnf (SessionCreatedWithErrors receipt diagnostic) = rnf receipt `seq` rnf diagnostic
  rnf (SessionCreationRejected diagnostic) = rnf diagnostic
  rnf (SessionCreationUnknown receipt problem) = rnf receipt `seq` problem `seq` ()

-- | Shared line-safe identity format for creation's @-P -F@ output.
sessionCreationFormat :: Frame.Nonce -> ByteString
sessionCreationFormat nonce = Frame.scalarFormat nonce (Bytes.intercalate " "
  [formatted Field.ServerPid, formatted Field.SessionId, formatted Field.WindowId,
   formatted Field.PaneId, formatted Field.LinkIndex])
  where
    formatted :: Field.Field row value -> ByteString
    formatted field = "#{" <> Field.formatVariable field <> "}"

-- | Decode the closed session/window/split creation profile through an existing pin.
-- Bounded prefix decoding preserves a receipt when later output exceeds limits.
-- Startup/configuration output and persistent control clients need other profiles.
decodeSessionCreation :: Frame.Nonce -> Maybe Int -> ByteString -> ByteString -> SessionCreationReply
decodeSessionCreation nonce exit output errors
  | Bytes.length output > 1048576 || Bytes.length errors > 1048576 = unknown ReplyTooLarge
  | not (Bytes.null errors) = unknown UnexpectedReply
  | otherwise = case known of
      Just (stamp, receipt, following) ->
        case stripControlExit following >>= Bytes.stripPrefix ("%end " <> stamp <> "\n") of
          Just tailBytes | exit == Just 0 -> SessionCreated receipt
                         | exit == Just 1 && not (Bytes.null tailBytes) ->
                             SessionCreatedWithErrors receipt (Bytes.copy tailBytes)
          _ -> rejected
      Nothing -> rejected
  where
    rejected = case initial of
        Just (stamp, body) | exit == Just 1
          , Just packet <- stripControlExit body
          , Right (diagnostic, following) <- errorBody stamp packet ->
              SessionCreationRejected (Bytes.copy (diagnostic <> following))
        _ -> unknown UnexpectedReply
    initial = do
      (header, body) <- boundedLine 64 output
      stamp <- either (const Nothing) Just (guardStamp header)
      pure (stamp, body)
    known = do
      (stamp, body) <- initial
      (line, following) <- boundedLine 256 body
      payload <- either (const Nothing) Just (Frame.decodeScalar nonce 64 (line <> "\n"))
      receipt <- sessionReceipt payload
      pure (stamp, receipt, following)
    -- Force the selected record, so the Maybe cannot retain the stream tuple.
    evidence = case known of
      Just (_, !receipt, _) -> Just receipt
      Nothing -> Nothing
    unknown = SessionCreationUnknown evidence

boundedLine :: Int -> ByteString -> Maybe (ByteString, ByteString)
boundedLine limit bytes =
  let (line, following) = Bytes.break (== 10) (Bytes.take (limit + 1) bytes)
  in if Bytes.null following then Nothing
     else Just (line, Bytes.drop (Bytes.length line + 1) bytes)

sessionReceipt :: ByteString -> Maybe SessionReceipt
sessionReceipt payload = case Ascii.split ' ' payload of
  [pidBytes, sessionBytes, windowBytes, paneBytes, indexBytes] -> do
    pid <- creationField Field.ServerPid pidBytes
    session <- creationField Field.SessionId sessionBytes
    window <- creationField Field.WindowId windowBytes
    pane <- creationField Field.PaneId paneBytes
    index <- creationField Field.LinkIndex indexBytes
    pure (SessionReceipt pid session window pane index)
  _ -> Nothing

-- Creation's native numbers are unpadded; the catalogue owns their domains.
creationField :: Field.Field row value -> ByteString -> Maybe value
creationField field bytes
  | Bytes.length bytes > 1 && Bytes.head bytes == 48 = Nothing
  | otherwise = either (const Nothing) Just (Field.decodeField field bytes)

stripControlExit :: ByteString -> Maybe ByteString
stripControlExit bytes = do
  packet <- Bytes.stripSuffix "%exit\n" bytes
  if Bytes.null packet || Bytes.last packet /= 10 then Nothing else Just packet

-- | Interpret fully drained streams and normal exit status for one t'Mutation'.
-- This is not a general control-mode decoder or evidence for waiting commands.
decodeControlReply :: Maybe Int -> ByteString -> ByteString -> Either ReplyError MutationReply
decodeControlReply exit output errors
  | Bytes.length output > 1048576 || Bytes.length errors > 1048576 = Left ReplyTooLarge
  | not (Bytes.null errors) = Left UnexpectedReply
  | otherwise = do
      packet <- maybe (Left UnexpectedReply) Right (stripControlExit output)
      let (header, following) = Bytes.break (== 10) packet
      stamp <- guardStamp header
      body <- maybe (Left UnexpectedReply) Right (Bytes.stripPrefix "\n" following)
      case Bytes.stripPrefix ("%end " <> stamp <> "\n") body of
        Just tailBytes -> case exit of
          Just 0 -> Right Applied
          Just 1 | not (Bytes.null tailBytes) -> Right (AppliedWithErrors (Bytes.copy tailBytes))
          _ -> Left UnexpectedReply
        Nothing | exit == Just 1 -> do
          (diagnostic, tailBytes) <- errorBody stamp body
          Right (Rejected (Bytes.copy (diagnostic <> tailBytes)))
        Nothing -> Left UnexpectedReply

data ControlDataReply
  = ControlData !ByteString
  | ControlDataExceedsLimit
  | ControlDataHookFailed !ByteString
  | ControlDataRejected !ByteString
  deriving stock (Eq, Show)

instance NFData ControlDataReply where
  rnf (ControlData bytes) = rnf bytes
  rnf ControlDataExceedsLimit = ()
  rnf (ControlDataHookFailed diagnostic) = rnf diagnostic
  rnf (ControlDataRejected diagnostic) = rnf diagnostic

compilePaneCapture :: Id.PaneId -> PaneCaptureOptions -> Either ArgumentError [ByteString]
compilePaneCapture pane options = do
  when (options.byteLimit < 1 || options.byteLimit > 1048576)
    (Left (InvalidOperand "pane.capture.byteLimit" "expected 1 through 1048576 bytes"))
  selection <- case options.rows of
    VisibleRows -> Right []
    RowsBetween first lastRow
      | first <= lastRow && first >= -2147483647 && lastRow <= 32767 ->
          Right ["-S", Ascii.pack (show first), "-E", Ascii.pack (show lastRow)]
      | otherwise -> Left (InvalidOperand "pane.capture.rows" "expected ordered offsets from -2147483647 through 32767")
  pure (["capture-pane", "-p", "-t", Utf8.encodeUtf8 (Id.renderPaneId pane)] <> selection
    <> ["-e" | options.rendering == AnsiStyled])

-- Data belongs to the primary command's guard. After-hooks have separate
-- guards. A duplicate matching boundary makes the reply ambiguous, including
-- when the payload contains a guard-shaped line.
decodeControlData :: Int -> Maybe Int -> ByteString -> ByteString -> Either ReplyError ControlDataReply
decodeControlData limit exit output errors
  | Bytes.length output > 1048576 = Left ReplyTooLarge
  | not (Bytes.null errors) = Left UnexpectedReply
  | otherwise = do
      packet <- maybe (Left UnexpectedReply) Right (stripControlExit output)
      (header, body) <- maybe (Left UnexpectedReply) Right (boundedLine 64 packet)
      stamp <- guardStamp header
      (success, count) <- payloadBoundary stamp body
      case (success, exit) of
        (True, Just 0)
          | count > limit -> Right ControlDataExceedsLimit
          | otherwise -> Right (ControlData (Bytes.copy (Bytes.take count body)))
        (True, Just 1)
          | let following = Bytes.drop (count + Bytes.length stamp + Bytes.length "%end \n") body
          , not (Bytes.null following) -> Right (ControlDataHookFailed (Bytes.copy following))
        (False, Just 1) -> Right (ControlDataRejected (Bytes.copy (Bytes.take count body)))
        _ -> Left UnexpectedReply

payloadBoundary :: ByteString -> ByteString -> Either ReplyError (Bool, Int)
payloadBoundary stamp = scan 0 Nothing
  where
    ended = "%end " <> stamp
    failed = "%error " <> stamp
    scan !offset found bytes
      | Bytes.null bytes = maybe (Left UnexpectedReply) Right found
      | otherwise = do
          let (line, following) = Bytes.break (== 10) bytes
          rest <- maybe (Left UnexpectedReply) Right (Bytes.stripPrefix "\n" following)
          let next = offset + Bytes.length line + 1
          case (line == ended, line == failed, found) of
            (False, False, _) -> scan next found rest
            (success, _, Nothing) -> scan next (Just (success, offset)) rest
            _ -> Left UnexpectedReply

guardStamp :: ByteString -> Either ReplyError ByteString
guardStamp header
  | Bytes.length header > 64 = Left UnexpectedReply
  | otherwise = do
      stamp <- maybe (Left UnexpectedReply) Right (Bytes.stripPrefix "%begin " header)
      case Ascii.words stamp of
        [seconds, number, "0"]
          | Bytes.intercalate " " [seconds, number, "0"] == stamp
          , decimal 9223372036854775807 seconds && decimal 4294967295 number -> Right stamp
        _ -> Left UnexpectedReply
  where
    decimal maximumValue bytes = not (Bytes.null bytes) && Bytes.length bytes <= 20
      && (bytes == "0" || Bytes.head bytes /= 48)
      && Bytes.all (\byte -> byte >= 48 && byte <= 57) bytes
      && case Ascii.readInteger bytes of
        Just (value, "") -> value <= maximumValue
        _ -> False

errorBody :: ByteString -> ByteString -> Either ReplyError (ByteString, ByteString)
errorBody stamp body
  | any (`Bytes.isPrefixOf` body) ["%begin ", "%end ", "%exit"] = Left UnexpectedReply
  | Just tailBytes <- Bytes.stripPrefix closing body = Right ("", tailBytes)
  | otherwise =
      let boundary = "\n" <> closing
          (diagnostic, following) = Bytes.breakSubstring boundary body
      in if Bytes.null following then Left UnexpectedReply
         else Right (diagnostic <> "\n", Bytes.drop (Bytes.length boundary) following)
  where
    closing = "%error " <> stamp <> "\n"

-- | Compile one command without IO. The 16364-byte bound includes every tail argv
-- terminator; the native owner separately checks the full executable/socket
-- invocation before admission. A tail neither validates generation nor reserves
-- a target, and native completion requires its own operation-specific evidence.
compileMutation :: Mutation -> Either ArgumentError [ByteString]
compileMutation = \case
  RenameSession ident text ->
    withOperand (target "rename-session" (Id.renderSessionId ident) <> ["--"])
      (Field.fieldKey Field.SessionName) (Utf8.encodeUtf8 text)
  RenameWindow ident label ->
    withOperand (target "rename-window" (Id.renderWindowId ident) <> ["--"])
      (Field.fieldKey Field.WindowName) (Label.toBytes label)
  SetPaneTitle ident text ->
    withOperand (target "select-pane" (Id.renderPaneId ident) <> ["-T"])
      (Field.fieldKey Field.PaneTitle) (Utf8.encodeUtf8 text)
  KillSession ident -> Right (target "kill-session" (Id.renderSessionId ident))
  KillWindow ident -> Right (target "kill-window" (Id.renderWindowId ident))
  KillPane ident -> Right (target "kill-pane" (Id.renderPaneId ident))
  LinkWindow source sourceIndex destination destinationIndex -> do
    from <- slotBytes source sourceIndex
    to <- slotBytes destination destinationIndex
    pure ["link-window", "-d", "-s", from, "-t", to]
  UnlinkWindow session index -> do
    slot <- slotBytes session index
    pure ["unlink-window", "-t", slot]
  SelectWindowLink session index -> do
    slot <- slotBytes session index
    pure ["select-window", "-t", slot]
  SelectExactPane session index pane -> do
    slot <- paneSlotBytes session index pane
    pure ["select-pane", "-t", slot]
  SelectLayout session index layout -> do
    slot <- slotBytes session index
    let name = case layout of
          EvenHorizontal -> "even-horizontal"
          EvenVertical -> "even-vertical"
          MainHorizontal -> "main-horizontal"
          MainVertical -> "main-vertical"
          Tiled -> "tiled"
    pure ["select-layout", "-t", slot, "--", name]
  ChangeEnvironment scope name change -> do
    validateEnvironmentName name
    let (flags, operands) = case change of
          SetVariable visibility value -> (visibilityFlag visibility, [name, value])
          MarkVariableRemoved -> (["-r"], [name])
          UnsetVariable -> (["-u"], [name])
    literalArguments "environment" (["set-environment"] <> environmentScope scope <> flags <> ["--"]) operands
  LoadBuffer name file -> bufferTransfer "load-buffer" name file
  SaveBuffer name file -> bufferTransfer "save-buffer" name file
  PasteBuffer pane name newlines rawFlag -> do
    validateBufferName name
    literalArguments "buffer.name"
      (target "paste-buffer" (Id.renderPaneId pane)
        <> ["-r" | newlines == PreserveLineFeeds] <> ["-S" | rawFlag] <> ["-b"])
      [name]
  ResizePane ident size ->
    (target "resize-pane" (Id.renderPaneId ident) <>) <$>
      resizeArguments (Field.fieldKey Field.PaneWidth) (Field.fieldKey Field.PaneHeight) size
  ResizeWindow ident size ->
    (target "resize-window" (Id.renderWindowId ident) <>) <$>
      resizeArguments (Field.fieldKey Field.WindowWidth) (Field.fieldKey Field.WindowHeight) size
  SendPaneText ident text ->
    literalArguments "pane.input" (target "send-keys" (Id.renderPaneId ident) <> ["-l", "--"])
      [Utf8.encodeUtf8 text]
  SendPaneKeys ident names -> do
    let keys = NonEmpty.toList names
    -- Native launch includes six fixed arguments and this four-argument prefix.
    when (length (take 4087 keys) > 4086) (Left (EncodedCommandTooLarge "pane.key"))
    encoded <- traverse keyOperand keys
    literalArguments "pane.key" (target "send-keys" (Id.renderPaneId ident) <> ["--"]) encoded
  where
    target command ident = [command, "-t", Utf8.encodeUtf8 ident]
    withOperand prefix key value = do
      let minimumCost = sum (map ((+ 1) . toInteger . Bytes.length) prefix)
            + toInteger (Bytes.length value) + 1
          expansionCost = 6 * toInteger (Bytes.count 35 value) + if endsSeparator value then 1 else 0
      checkCost key value minimumCost expansionCost
      pure (prefix <> [protectSeparator (protectFormat value)])

-- Both axes must pass before the runner admits any native effect. resize-pane
-- can unzoom or change width before its native height validation fails.
resizeArguments :: Text -> Text -> Value.Resize -> Either ArgumentError [ByteString]
resizeArguments widthKey heightKey = \case
  Value.ResizeWidth width -> cells widthKey "-x" width
  Value.ResizeHeight height -> cells heightKey "-y" height
  Value.ResizeBoth width height -> (<>) <$> cells widthKey "-x" width <*> cells heightKey "-y" height
  where
    cells key flag value = do
      when (Value.dimensionValue value > 10000)
        (Left (InvalidOperand key "dimension exceeds 10000 cells"))
      pure [flag, Ascii.pack (show (Value.dimensionValue value))]

-- The claim and effect run in one daemon queue. Nonce acknowledgements belong
-- to the composite operation; arbitrary hook output is not parsed as framing.
compileProgramMutation :: Frame.Nonce -> ProgramCommand -> Either ArgumentError [ByteString]
compileProgramMutation nonce command = do
  values <- case command of
    ProgramGuarded identity client live action -> do
      unless (validClient client) (Left (InvalidOperand "program" "invalid witness client"))
      actionArgs <- case action of
        ProgramHistory {} -> compileProgramCommand action
        ProgramRemain {} -> compileProgramCommand action
        ProgramRemainFormat {} -> compileProgramCommand action
        ProgramGeometry {} -> compileProgramCommand action
        ProgramCapture {} -> compileProgramCommand action
        ProgramInputBytes {} -> compileProgramCommand action
        ProgramKillSession {} -> compileProgramCommand action
        _ -> Left (InvalidOperand "program" "unsupported guarded action")
      let ProgramIdentity session window pane pid = identity
          equals key value = "#{==:#{" <> key <> "}," <> value <> "}"
          both left right = "#{&&:" <> left <> "," <> right <> "}"
          process = if live then both (equals "pane_dead" "0") (equals "pane_pid" (Ascii.pack (show pid)))
            else "#{||:#{pane_dead}," <> equals "pane_pid" (Ascii.pack (show pid)) <> "}"
          captureBounds = case action of
            ProgramCapture _ _ _ columns rows ->
              [equals "pane_width" (Ascii.pack (show columns)), equals "pane_height" (Ascii.pack (show rows))]
            _ -> []
          condition = foldr1 both
            ([ equals "session_id" (Utf8.encodeUtf8 (Id.renderSessionId session))
            , equals "window_id" (Utf8.encodeUtf8 (Id.renderWindowId window))
            , equals "pane_id" (Utf8.encodeUtf8 (Id.renderPaneId pane))
            , equals "session_windows" "1", equals "window_panes" "1", process ] <> captureBounds)
          failure = renderArguments ["has-session", "-t", "=libtmux-refused-" <> Frame.recordMarker nonce]
      pure (["wait-for", "-E", "-w", client, "pane-created", ";"]
        <> acknowledge "claimed" <> [";", "if-shell", "-F", "-t",
          Utf8.encodeUtf8 (Id.renderSessionId session) <> ":", condition, renderArguments actionArgs, failure]
        <> [";"] <> acknowledge "applied")
    _ -> (<> ([";"] <> acknowledge "applied")) <$> compileProgramCommand command
  checkProgramCost values
  pure values
  where
    acknowledge stage = ["display-message", "-p", Frame.scalarFormat nonce stage]
    validClient value = case Bytes.stripPrefix "client-" value of
      Just digits -> not (Bytes.null digits) && Bytes.length digits <= 10
        && Bytes.all (\byte -> byte >= 48 && byte <= 57) digits
      Nothing -> False
    renderArguments = Bytes.intercalate " " . map (\value -> "'" <> Bytes.intercalate "'\\''" (Bytes.split 39 value) <> "'")

-- | Interpret one fully drained composite Program command. A claimed failure
-- proves that the old witness was consumed, not that its later action ran.
decodeProgramReply :: Bool -> Frame.Nonce -> Maybe Int -> ByteString -> ByteString -> Either ReplyError MutationReply
decodeProgramReply guarded nonce exit output errors
  | Bytes.length output > 1048576 || Bytes.length errors > 1048576 = Left ReplyTooLarge
  | otherwise = case exit of
      Just 0 | Bytes.null errors && applied && (not guarded || claimed) -> Right Applied
      Just 1 | applied || guarded && claimed -> Right (AppliedWithErrors diagnostic)
      Just 1 -> Right (Rejected diagnostic)
      _ -> Left UnexpectedReply
  where
    claimedLine = Frame.scalarFormat nonce "claimed"
    appliedLine = Frame.scalarFormat nonce "applied"
    outputLines = Ascii.lines output
    claimed = length (filter (== claimedLine) outputLines) == 1
    applied = Bytes.isSuffixOf (appliedLine <> "\n") output
      && length (filter (== appliedLine) outputLines) == 1
    diagnostic = Bytes.copy (Bytes.take 4096 (errors <> output))

compileProgramCommand :: ProgramCommand -> Either ArgumentError [ByteString]
compileProgramCommand command = do
  let values = case command of
        ProgramRemain pane -> ["set-option", "-p", "-t", paneBytes pane, "remain-on-exit", "on"]
        ProgramRemainFormat pane -> ["set-option", "-p", "-t", paneBytes pane, "remain-on-exit-format", ""]
        ProgramHistory session count -> ["set-option", "-t", sessionBytes session, "history-limit", number count]
        ProgramGeometry window columns rows ->
          ["resize-window", "-t", Utf8.encodeUtf8 (Id.renderWindowId window), "-x", number columns, "-y", number rows]
        ProgramCapture pane buffer count _ _ ->
          ["capture-pane", "-J", "-S", number (negate count), "-t", paneBytes pane, "-b", buffer]
        ProgramSave buffer path -> ["save-buffer", "-b", buffer, protectFormat path]
        ProgramDeleteBuffer buffer -> ["delete-buffer", "-b", buffer]
        ProgramInputBytes pane bytes -> ["send-keys", "-H", "-t", paneBytes pane]
          <> map hexByte (Bytes.unpack bytes)
        ProgramKillSession session -> ["kill-session", "-t", sessionBytes session]
        ProgramGuarded {} -> []
  case command of ProgramGuarded {} -> Left (InvalidOperand "program" "nested lifetime gate"); _ -> pure ()
  let lowered = map protectSeparator values
  checkProgramCost lowered
  pure lowered
  where
    paneBytes = Utf8.encodeUtf8 . Id.renderPaneId
    sessionBytes = Utf8.encodeUtf8 . Id.renderSessionId
    number = Ascii.pack . show
    hexByte value = let alphabet = "0123456789abcdef" in
      Bytes.pack [Bytes.index alphabet (fromIntegral value `div` 16),
        Bytes.index alphabet (fromIntegral value `mod` 16)]

checkProgramCost :: [ByteString] -> Either ArgumentError ()
checkProgramCost values = do
  when (length (take 4091 values) > 4090) (Left (EncodedCommandTooLarge "program"))
  mapM_ (\value -> when (Bytes.elem 0 value) (Left (NulOperand "program"))) values
  when (sum (map ((+ 1) . toInteger . Bytes.length) values) > commandLimitBytes)
    (Left (EncodedCommandTooLarge "program"))

bufferTransfer :: ByteString -> ByteString -> ByteString -> Either ArgumentError [ByteString]
bufferTransfer command name file = do
  validateBufferName name
  literalArguments "buffer.name" [command, "-b"] [name, protectFormat file]

validateBufferName :: ByteString -> Either ArgumentError ()
validateBufferName name =
  when (Bytes.null name) (Left (InvalidOperand "buffer.name" "expected a nonempty buffer name"))

compileEnvironmentRead :: Maybe Id.SessionId -> EnvironmentVisibility -> ByteString -> Either ArgumentError [ByteString]
compileEnvironmentRead scope visibility name = do
  validateEnvironmentName name
  literalArguments "environment.name"
    (["show-environment"] <> environmentScope scope <> visibilityFlag visibility <> ["--"]) [name]

environmentScope :: Maybe Id.SessionId -> [ByteString]
environmentScope Nothing = ["-g"]
environmentScope (Just session) = ["-t", creationSessionTarget session]

visibilityFlag :: EnvironmentVisibility -> [ByteString]
visibilityFlag Visible = []
visibilityFlag Hidden = ["-h"]

validateEnvironmentName :: ByteString -> Either ArgumentError ()
validateEnvironmentName name =
  when (Bytes.null name || Bytes.elem 0 name || Bytes.elem 61 name)
    (Left (InvalidOperand "environment.name" "expected a nonempty name without NUL or '='"))

literalArguments :: Text -> [ByteString] -> [ByteString] -> Either ArgumentError [ByteString]
literalArguments field prefix operands = do
  let arguments = prefix <> map protectSeparator operands
      cost = sum [toInteger (Bytes.length value) + 1 | value <- arguments]
  when (cost > commandLimitBytes) (Left (EncodedCommandTooLarge field))
  when (any (Bytes.elem 0) operands) (Left (NulOperand field))
  pure arguments

keyOperand :: Text -> Either ArgumentError ByteString
keyOperand name
  | Text.null name || Text.toCaseFold name `elem` ["any", "none"] =
      Left (InvalidOperand "pane.key" "expected a deliverable key name")
  | otherwise = Right (Utf8.encodeUtf8 name)

-- list-keys validates a name before looking up its table. A fresh absent
-- table makes either result a primary error, so after-list-keys never runs.
compileKeyProbe :: Frame.Nonce -> Text -> Either ArgumentError [ByteString]
compileKeyProbe nonce name = do
  operand <- keyOperand name
  literalArguments "pane.key" ["list-keys", "-T", keyProbeTable nonce, "--"] [operand]

decodeKeyProbe :: Frame.Nonce -> Maybe Int -> ByteString -> ByteString -> Either ReplyError Bool
decodeKeyProbe nonce status output diagnostic
  | status /= Just 1 || not (Bytes.null output) = Left UnexpectedReply
  | diagnostic == "table " <> keyProbeTable nonce <> " doesn't exist\n" = Right True
  | "invalid key: " `Bytes.isPrefixOf` diagnostic = Right False
  | otherwise = Left UnexpectedReply

keyProbeTable :: Frame.Nonce -> ByteString
keyProbeTable nonce = "libtmux-key-" <> Frame.recordMarker nonce

checkCost :: Text -> ByteString -> Integer -> Integer -> Either ArgumentError ()
checkCost key value minimumCost expansionCost
  | minimumCost > commandLimitBytes = Left (EncodedCommandTooLarge key)
  | Bytes.elem 0 value = Left (NulOperand key)
  | minimumCost + expansionCost > commandLimitBytes = Left (EncodedCommandTooLarge key)
  | otherwise = Right ()

-- tmux 3.3a and 3.8: MAX_IMSGSIZE minus imsg_hdr and msg_command.
-- compat/imsg.c includes the header when proc_send packs client argv.
commandLimitBytes :: Integer
commandLimitBytes = 16384 - 16 - 4

protectFormat :: ByteString -> ByteString
-- tmux preserves hash runs before '['; character expansion avoids that branch.
protectFormat = Bytes.concatMap (\byte -> if byte == 35 then "#{a:35}" else Bytes.singleton byte)

protectSeparator :: ByteString -> ByteString
protectSeparator value
  -- tmux consumes the added backslash instead of splitting another command.
  | endsSeparator value = Bytes.init value <> "\\;"
  | otherwise = value

endsSeparator :: ByteString -> Bool
endsSeparator value = not (Bytes.null value) && Bytes.last value == 59
