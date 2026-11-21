{-# LANGUAGE BangPatterns #-}

-- | Bound YAML decoding and keep marked parser errors.
module LibTmux.Workspace.Yaml (YamlError (..), decodeWorkspaceYaml) where

import Control.DeepSeq (NFData (..), force)
import Control.Exception (evaluate, try)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Resource (ResourceT)
import Data.Aeson (Object, Value (..))
import Data.ByteString qualified as Bytes
import Data.Conduit (ConduitT, await, runConduitRes, yield, (.|))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Void (Void)
import Data.Yaml qualified as Yaml
import System.IO.Unsafe (unsafePerformIO)
import Text.Libyaml qualified as Lib

data Limits = Limits
  { maxBytes :: !Int
  , maxEvents :: !Int
  , maxDepth :: !Int
  , maxScalarBytes :: !Int
  }

defaultLimits :: Limits
defaultLimits = Limits 1048576 20000 64 65536

-- | Parser diagnostic with a one-based source position when available.
data YamlError = YamlError
  { code :: !Text
  , message :: !Text
  , line :: !(Maybe Int)
  , column :: !(Maybe Int)
  }
  deriving stock (Eq, Show)

instance NFData YamlError where
  rnf problem = rnf (problem.code, problem.message, problem.line, problem.column)

data Frame = Sequence | Mapping !(Set.Set Text) !Bool

-- The two libyaml passes read only these bytes. Run them to completion before
-- returning so the pure caller holds no parser resources.
{-# NOINLINE decodeWorkspaceYaml #-}
decodeWorkspaceYaml :: Bytes.ByteString -> Either YamlError Object
decodeWorkspaceYaml bytes = unsafePerformIO (parseBytes bytes >>= evaluate . force)

parseBytes :: Bytes.ByteString -> IO (Either YamlError Object)
parseBytes bytes
  | Bytes.length bytes > maxBytes limits = pure (Left (withoutMark "input-limit" "input exceeds byte limit"))
  | otherwise = do
      checked <- try @Lib.YamlException $ runConduitRes $
        Lib.decodeMarked bytes .| checkEvents limits 0 0 []
      case checked of
        Left (Lib.YamlParseException problem context mark) ->
          pure (Left (atMark "syntax" (Text.pack (problem <> ": " <> context)) mark))
        Left problem -> pure (Left (withoutMark "yaml-parser" (Text.pack (show problem))))
        Right (Left problem) -> pure (Left problem)
        Right (Right ()) -> do
          decoded <- Yaml.decodeHelper (Lib.decode bytes)
          pure $ case decoded of
            Left problem -> Left (withoutMark "conversion" (Text.pack (Yaml.prettyPrintParseException problem)))
            Right (_, Left problem) -> Left (withoutMark "conversion" (Text.pack problem))
            Right (_, Right (Object fields)) -> Right fields
            Right (_, Right _) -> Left (withoutMark "root-type" "workspace root must be a mapping")
  where
    limits = defaultLimits

checkEvents :: Limits -> Int -> Int -> [Frame] -> ConduitT Lib.MarkedEvent Void (ResourceT IO) (Either YamlError ())
checkEvents limits !count !documents frames = do
  next <- await
  case next of
    Nothing -> pure (Right ())
    Just marked
      | count >= maxEvents limits -> pure $ Left $ issue marked "event-limit" "input exceeds event limit"
      | otherwise -> do
          advanced <- liftIO $ step marked
          case advanced of
            Left err -> pure (Left err)
            Right (documents', frames') -> checkEvents limits (count + 1) documents' frames'
  where
    step marked = case Lib.yamlEvent marked of
      Lib.EventDocumentStart
        | documents > 0 -> pure $ Left $ issue marked "multiple-documents" "exactly one YAML document is allowed"
        | otherwise -> pure $ Right (documents + 1, frames)
      Lib.EventAlias _ -> pure $ Left $ issue marked "alias" "YAML aliases are unsupported"
      Lib.EventScalar bytes tag style _
        | Bytes.length bytes > maxScalarBytes limits -> pure $ Left $ issue marked "scalar-limit" "scalar exceeds byte limit"
        | Just err <- checkTag marked [Lib.NoTag, Lib.StrTag] tag -> pure (Left err)
        | otherwise -> do
            consumed <- consumeScalar marked bytes tag style frames
            pure $ (documents,) <$> consumed
      Lib.EventSequenceStart tag _ _ -> pure $ do
        maybe (Right ()) Left (checkTag marked [Lib.NoTag, Lib.SeqTag] tag)
        entered <- enter marked Sequence
        Right (documents, entered)
      Lib.EventMappingStart tag _ _ -> pure $ do
        maybe (Right ()) Left (checkTag marked [Lib.NoTag, Lib.MapTag] tag)
        entered <- enter marked (Mapping Set.empty True)
        Right (documents, entered)
      Lib.EventSequenceEnd -> pure $ Right (documents, drop 1 frames)
      Lib.EventMappingEnd -> pure $ Right (documents, drop 1 frames)
      _ -> pure $ Right (documents, frames)

    enter marked frame
      | length frames >= maxDepth limits = Left $ issue marked "depth-limit" "input exceeds nesting depth limit"
      | Mapping _ True : _ <- frames = Left $ issue marked "non-text-key" "mapping keys must be text scalars"
      | otherwise = Right $ frame : consumeValue frames

consumeScalar :: Lib.MarkedEvent -> Bytes.ByteString -> Lib.Tag -> Lib.Style -> [Frame] -> IO (Either YamlError [Frame])
consumeScalar marked bytes tag style (Mapping keys True : rest) = do
  -- Use the public decoder's resolver, retaining the scalar's tag and quoting.
  decoded <- Yaml.decodeHelper $ mapM_ yield
    [ Lib.EventStreamStart, Lib.EventDocumentStart
    , Lib.EventScalar bytes tag style Nothing
    , Lib.EventDocumentEnd, Lib.EventStreamEnd
    ]
  pure $ case decoded of
    Right (_, Right (String key))
      | key == "<<" -> Left $ issue marked "merge-key" "YAML merge keys are refused"
      | Set.member key keys -> Left $ issue marked "duplicate-key" ("duplicate key " <> key)
      | otherwise -> Right $ Mapping (Set.insert key keys) False : rest
    Right (_, Right _) -> Left $ issue marked "non-text-key" "mapping keys must resolve to text scalars"
    _ -> Left $ issue marked "key-conversion" "mapping key could not be resolved"
consumeScalar _ _ _ _ frames = pure $ Right $ consumeValue frames

consumeValue :: [Frame] -> [Frame]
consumeValue (Mapping keys False : rest) = Mapping keys True : rest
consumeValue frames = frames

checkTag :: Lib.MarkedEvent -> [Lib.Tag] -> Lib.Tag -> Maybe YamlError
checkTag marked allowed tag
  | tag `elem` allowed = Nothing
  | Lib.UriTag uri <- tag = Just $ issue marked "custom-tag" ("custom YAML tags are refused: " <> Text.pack uri)
  | otherwise = Just $ issue marked "explicit-tag" ("unsupported explicit YAML tag: " <> Text.pack (show tag))

issue :: Lib.MarkedEvent -> Text -> Text -> YamlError
issue marked code message = atMark code message (Lib.yamlStartMark marked)

atMark :: Text -> Text -> Lib.YamlMark -> YamlError
atMark code message mark = YamlError code message (Just (Lib.yamlLine mark + 1)) (Just (Lib.yamlColumn mark + 1))

withoutMark :: Text -> Text -> YamlError
withoutMark code message = YamlError code message Nothing Nothing
