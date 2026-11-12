-- | Private literal mutations and nonce-qualified native creation receipts.
--
-- 'compileMutation' preserves operand bytes through tmux's command and format
-- parsers. 'decodeControlReply' applies only to these synchronous handlers,
-- whose primary success response is empty. The Runtime owns the client until
-- normal exit; later hook output remains opaque to this decoder.
module LibTmux.Internal.Command
  ( Mutation (..), ArgumentError (..), compileMutation
  , MutationReply (..), ReplyError (..), decodeControlReply
  , SessionReceipt (..), SessionCreationReply (..)
  , sessionCreationFormat, decodeSessionCreation
  ) where

import Control.DeepSeq (NFData (rnf))
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.Text (Text)
import Data.Text.Encoding qualified as Utf8
import Foreign.C.Types (CInt)
import LibTmux.Id qualified as Id
import LibTmux.Internal.Field qualified as Field
import LibTmux.Internal.Frame qualified as Frame
import LibTmux.Internal.TmuxText (TmuxText)
import LibTmux.Internal.TmuxText qualified as Label
import LibTmux.Value qualified as Value

-- | Literal requests with canonical entity targets. Native name validation
-- and normalization remain command outcomes rather than lowering policy.
data Mutation
  = RenameSession !Id.SessionId !Text
  | RenameWindow !Id.WindowId !TmuxText
  | SetPaneTitle !Id.PaneId !Text
  deriving stock (Eq, Show)

-- | Refusal before a command tail exists, carrying its catalogue field key.
data ArgumentError = NulOperand !Text | EncodedCommandTooLarge !Text
  deriving stock (Eq, Show)

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

-- | IDs printed by new-session before its after-hooks. They do not establish
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

-- | The line-safe identity format for detached @new-session -P -F@.
sessionCreationFormat :: Frame.Nonce -> ByteString
sessionCreationFormat nonce = Frame.scalarFormat nonce
  "#{pid} #{session_id} #{window_id} #{pane_id} #{window_index}"

-- | Decode the closed detached new-session profile through an existing pin.
-- Bounded prefix decoding preserves a receipt when later output exceeds limits.
-- Startup/configuration output and persistent control clients need other profiles.
decodeSessionCreation :: Frame.Nonce -> Maybe Int -> ByteString -> ByteString -> SessionCreationReply
decodeSessionCreation nonce exit output errors
  | Bytes.length output > 1048576 || Bytes.length errors > 1048576 = unknown ReplyTooLarge
  | not (Bytes.null errors) = unknown UnexpectedReply
  | otherwise = case known of
      Just (stamp, receipt, following) ->
        case Bytes.stripSuffix "%exit\n" following >>= Bytes.stripPrefix ("%end " <> stamp <> "\n") of
          Just tailBytes | exit == Just 0 -> SessionCreated receipt
                         | exit == Just 1 && not (Bytes.null tailBytes) ->
                             SessionCreatedWithErrors receipt (Bytes.copy tailBytes)
          _ -> unknown UnexpectedReply
      Nothing -> case initial of
        Just (stamp, body) | exit == Just 1
          , Just packet <- Bytes.stripSuffix "%exit\n" body
          , Right (diagnostic, following) <- errorBody stamp packet ->
              SessionCreationRejected (Bytes.copy (diagnostic <> following))
        _ -> unknown UnexpectedReply
  where
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
    pid <- nativeNumber pidBytes
    if pid == 0 then Nothing else pure ()
    session <- nativeId Id.parseSessionId sessionBytes
    window <- nativeId Id.parseWindowId windowBytes
    pane <- nativeId Id.parsePaneId paneBytes
    index <- nativeNumber indexBytes
    checked <- either (const Nothing) Just (Value.mkWindowIndex index)
    pure (SessionReceipt pid session window pane checked)
  _ -> Nothing

nativeId :: (Text -> Either Id.IdError value) -> ByteString -> Maybe value
nativeId parse bytes = do
  text <- either (const Nothing) Just (Utf8.decodeUtf8' bytes)
  either (const Nothing) Just (parse text)

nativeNumber :: ByteString -> Maybe Integer
nativeNumber bytes
  | Bytes.null bytes || Bytes.length bytes > 10 = Nothing
  | Bytes.head bytes == 48 && Bytes.length bytes /= 1 = Nothing
  | not (Bytes.all (\byte -> byte >= 48 && byte <= 57) bytes) = Nothing
  | otherwise = case Ascii.readInteger bytes of
      Just (value, "") | value <= toInteger (maxBound @CInt) -> Just value
      _ -> Nothing

-- | Interpret fully drained streams and normal exit status for one t'Mutation'.
-- This is not a general control-mode decoder or evidence for waiting commands.
decodeControlReply :: Maybe Int -> ByteString -> ByteString -> Either ReplyError MutationReply
decodeControlReply exit output errors
  | Bytes.length output > 1048576 || Bytes.length errors > 1048576 = Left ReplyTooLarge
  | not (Bytes.null errors) = Left UnexpectedReply
  | otherwise = do
      packet <- maybe (Left UnexpectedReply) Right (Bytes.stripSuffix "%exit\n" output)
      if Bytes.null packet || Bytes.last packet /= 10 then Left UnexpectedReply else pure ()
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

-- | Compile one command without IO. The 64KiB bound includes every tail argv
-- terminator; the native owner separately checks the full executable/socket
-- invocation before admission. A tail neither validates generation nor reserves
-- a target, and native completion requires its own operation-specific evidence.
compileMutation :: Mutation -> Either ArgumentError [ByteString]
compileMutation mutation = do
  checkCost key value minimumCost expansionCost
  pure (prefix <> [protectSeparator (protectFormat value)])
  where
    (prefix, value, key) = mutationParts mutation
    minimumCost = sum (map ((+ 1) . toInteger . Bytes.length) prefix)
      + toInteger (Bytes.length value) + 1
    expansionCost = 6 * toInteger (Bytes.count 35 value) + if endsSeparator value then 1 else 0

mutationParts :: Mutation -> ([ByteString], ByteString, Text)
mutationParts mutation = case mutation of
  RenameSession ident text ->
    (["rename-session", "-t", Utf8.encodeUtf8 (Id.renderSessionId ident), "--"],
     Utf8.encodeUtf8 text, Field.fieldKey Field.SessionName)
  RenameWindow ident label ->
    (["rename-window", "-t", Utf8.encodeUtf8 (Id.renderWindowId ident), "--"],
     Label.toBytes label, Field.fieldKey Field.WindowName)
  SetPaneTitle ident text ->
    (["select-pane", "-t", Utf8.encodeUtf8 (Id.renderPaneId ident), "-T"],
     Utf8.encodeUtf8 text, Field.fieldKey Field.PaneTitle)

checkCost :: Text -> ByteString -> Integer -> Integer -> Either ArgumentError ()
checkCost key value minimumCost expansionCost
  | minimumCost > 65536 = Left (EncodedCommandTooLarge key)
  | Bytes.elem 0 value = Left (NulOperand key)
  | minimumCost + expansionCost > 65536 = Left (EncodedCommandTooLarge key)
  | otherwise = Right ()

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
