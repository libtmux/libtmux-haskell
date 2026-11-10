-- | Private literal mutation intents and checked tmux argument tails.
module LibTmux.Internal.Command (Mutation (..), ArgumentError (..), compileMutation) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
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

-- | Compile one command without IO. The 64KiB bound includes every tail argv
-- terminator; the native owner separately checks the full executable/socket
-- invocation before admission. A tail neither validates generation nor reserves
-- a target, and native completion requires its own operation-specific evidence.
compileMutation :: Mutation -> Either ArgumentError [ByteString]
compileMutation mutation
  | minimumCost > 65536 = Left (EncodedCommandTooLarge key)
  | Bytes.elem 0 value = Left (NulOperand key)
  | minimumCost + expansionCost > 65536 = Left (EncodedCommandTooLarge key)
  | otherwise = Right (prefix <> [protectSeparator (protectFormat value)])
  where
    (prefix, value, key) = case mutation of
      RenameSession ident text ->
        (["rename-session", "-t", Utf8.encodeUtf8 (Id.renderSessionId ident), "--"],
         Utf8.encodeUtf8 text, Field.fieldKey Field.SessionName)
      RenameWindow ident label ->
        (["rename-window", "-t", Utf8.encodeUtf8 (Id.renderWindowId ident), "--"],
         Label.toBytes label, Field.fieldKey Field.WindowName)
      SetPaneTitle ident text ->
        (["select-pane", "-t", Utf8.encodeUtf8 (Id.renderPaneId ident), "-T"],
         Utf8.encodeUtf8 text, Field.fieldKey Field.PaneTitle)
    minimumCost = sum (map ((+ 1) . toInteger . Bytes.length) prefix)
      + toInteger (Bytes.length value) + 1
    expansionCost = 6 * toInteger (Bytes.count 35 value) + if endsSeparator value then 1 else 0

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
