-- | Private literal mutation protocols and nonce-qualified queue receipts.
module LibTmux.Internal.Command
  ( Mutation (..), ArgumentError (..), compileMutation, compileScript
  , MutationReply (..), ReplyError (..), decodeReply
  ) where

import Control.DeepSeq (NFData (rnf))
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.Text (Text)
import Data.Text.Encoding qualified as Utf8
import LibTmux.Id qualified as Id
import LibTmux.Internal.Field qualified as Field
import LibTmux.Internal.Frame qualified as F
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

-- | Encode one mutation and two receipt groups for @source-file -@. Octal
-- quoting protects the command-file parser; hash expansion protects formats.
-- The complete stdin bound is checked before either expansion is allocated.
compileScript :: F.Nonce -> Mutation -> Either ArgumentError ByteString
compileScript nonce mutation = do
  checkCost key value minimumCost (24 * toInteger (Bytes.count 35 value))
  pure (Bytes.intercalate " " (map quote (prefix <> [protectFormat value])) <> receipts)
  where
    (prefix, value, key) = mutationParts mutation
    receipts = " ; display-message -p -F " <> F.scalarFormat nonce "applied" <> "\n"
      <> "display-message -p -F " <> F.scalarFormat nonce "finished" <> "\n"
    count = toInteger (length prefix + 1)
    minimumCost = toInteger (Bytes.length receipts) + 2 * count + count - 1
      + 4 * sum (map (toInteger . Bytes.length) prefix) + 4 * toInteger (Bytes.length value)

quote :: ByteString -> ByteString
quote value = "\"" <> Bytes.concatMap octal value <> "\""
  where
    octal byte = Bytes.pack [92, 48 + byte `div` 64, 48 + (byte `div` 8) `mod` 8, 48 + byte `mod` 8]

-- | Require an exact drained reply and compatible native exit. Extra hook
-- output is uncertainty, including text resembling control protocol lines.
decodeReply :: F.Nonce -> Maybe Int -> ByteString -> ByteString -> Either ReplyError MutationReply
decodeReply nonce exit output errors
  | Bytes.length output > 1048576 || Bytes.length errors > 1048576 = Left ReplyTooLarge
  | exit == Just 0 && output == applied <> finished && Bytes.null errors = Right Applied
  | exit == Just 1 && not (Bytes.null errors) =
      if output == finished then Right (Rejected (Bytes.copy errors))
      else if output == applied <> finished then Right (AppliedWithErrors (Bytes.copy errors))
      else Left UnexpectedReply
  | otherwise = Left UnexpectedReply
  where
    applied = F.scalarFormat nonce "applied" <> "\n"
    finished = F.scalarFormat nonce "finished" <> "\n"

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
