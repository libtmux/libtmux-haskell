-- | Private literal mutations and their closed native acknowledgment profile.
module LibTmux.Internal.Command
  ( Mutation (..), ArgumentError (..), compileMutation
  , MutationReply (..), ReplyError (..), decodeControlReply
  ) where

import Control.DeepSeq (NFData (rnf))
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Ascii
import Data.Text (Text)
import Data.Text.Encoding qualified as Utf8
import LibTmux.Id qualified as Id
import LibTmux.Internal.Field qualified as Field
import LibTmux.Internal.TmuxText (TmuxText)
import LibTmux.Internal.TmuxText qualified as Label

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
