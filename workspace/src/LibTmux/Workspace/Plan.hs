-- | Validate workspace fields and resolve configuration inheritance.
module LibTmux.Workspace.Plan
  ( PlanInputs (..), defaultPlanInputs
  , WorkspacePlan (..), WorkspacePreview (..), WindowPlan (..), PanePlan (..)
  , WorkspaceCommand (..), WorkspaceError (..)
  , planTmuxp
  ) where

import Control.Applicative ((<|>))
import Control.Monad (unless, when)
import Data.Aeson (Object, Result (..), Value (..), fromJSON)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as Keys
import Data.ByteString (ByteString)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Foldable (toList, traverse_)
import Data.Int (Int32)
import Data.List (mapAccumL)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import LibTmux qualified as Tmux
import LibTmux.Workspace.Yaml (YamlError, decodeWorkspaceYaml)
import System.FilePath.Posix (dropTrailingPathSeparator, isAbsolute, normalise, (</>))

-- | Explicit inputs for resolving relative paths, home and variable names.
-- Planning reads no process environment.
data PlanInputs = PlanInputs
  { configDirectory :: !FilePath
  , homeDirectory :: !(Maybe FilePath)
  , variables :: !(Map Text Text)
  }

-- | Use the configuration file's absolute parent directory. Supply home
-- and variable values when a workspace uses them.
defaultPlanInputs :: FilePath -> PlanInputs
defaultPlanInputs directory = PlanInputs directory Nothing Map.empty

-- | An application-ready plan. Obtain one through 'planTmuxp'.
newtype WorkspacePlan = WorkspacePlan WorkspacePreview

-- | Resolved, detached workspace settings in file order.
data WorkspacePreview = WorkspacePreview
  { sessionName :: !Text
  , sessionDirectory :: !(Maybe FilePath)
  , sessionEnvironment :: !(Map Text Text)
  , windows :: !(NonEmpty WindowPlan)
  } deriving stock (Eq)

-- | A desired window. A missing index uses tmux's next free slot.
data WindowPlan = WindowPlan
  { windowName :: !(Maybe Text)
  , windowIndex :: !(Maybe Tmux.WindowIndex)
  , layout :: !(Maybe Tmux.NamedLayout)
  , windowDirectory :: !(Maybe FilePath)
  , windowEnvironment :: !(Maybe (Map Text Text))
  , focusWindow :: !Bool
  , panes :: !(NonEmpty PanePlan)
  } deriving stock (Eq)

-- | Effective settings for a pane before it receives its commands.
data PanePlan = PanePlan
  { paneDirectory :: !(Maybe FilePath)
  , paneEnvironment :: !(Maybe (Map Text Text))
  , focusPane :: !Bool
  , suppressHistory :: !Bool
  , commands :: ![WorkspaceCommand]
  } deriving stock (Eq)

-- | Shell text with the Enter policy inherited from its pane or command list.
data WorkspaceCommand = WorkspaceCommand
  { shellText :: !Text
  , sendEnter :: !Bool
  } deriving stock (Eq)

-- | A document problem or a structural field path. Field paths use
-- zero-based list indexes.
data WorkspaceError
  = InvalidYaml !YamlError
  | MissingField !Text
  | InvalidField !Text !Text
  | UnsupportedField !Text
  deriving stock (Eq, Show)

type Decode = Either WorkspaceError

data Defaults = Defaults
  { directory :: !(Maybe FilePath)
  , environment :: !(Maybe (Map Text Text))
  , beforeCommands :: ![(Text, Maybe Bool)]
  , historySuppressed :: !Bool
  }

-- | Parse one tmuxp YAML document and resolve its plan without opening tmux.
planTmuxp :: PlanInputs -> ByteString -> Decode WorkspacePlan
planTmuxp inputs bytes = do
  unless (isAbsolute inputs.configDirectory) $
    Left (InvalidField "configDirectory" "expected the absolute directory holding the workspace file")
  document <- either (Left . InvalidYaml) Right (decodeWorkspaceYaml bytes)
  allow "" ["session_name", "start_directory", "environment", "shell_command_before", "suppress_history", "windows"] document
  name <- required "" "session_name" text document
  let resolvedName = expand inputs name
  when (Text.null resolvedName || Text.any (`elem` ['\NUL', ':', '.']) resolvedName) $
    Left (InvalidField "session_name" "expected a nonempty native session name without colon or period")
  inherited <- defaults inputs "" (Defaults Nothing Nothing [] True) document
  plans <- required "" "windows" (nonemptyList (parseWindow inputs inherited {environment = Nothing})) document
  let explicit = [index | window <- NonEmpty.toList plans, Just index <- [window.windowIndex]]
  unless (length explicit == Set.size (Set.fromList explicit)) $
    Left (InvalidField "windows" "window_index values must be unique")
  pure (WorkspacePlan (WorkspacePreview resolvedName inherited.directory
    (maybe Map.empty id inherited.environment) plans))

parseWindow :: PlanInputs -> Defaults -> Text -> Value -> Decode WindowPlan
parseWindow inputs inherited path value = do
  object <- mapping path value
  allow path ["window_name", "window_index", "layout", "start_directory", "environment",
    "focus", "shell_command_before", "suppress_history", "panes"] object
  local <- defaults inputs path inherited object
  name <- optional path "window_name" text object
  index <- optional path "window_index" parseIndex object
  layout <- optional path "layout" parseLayout object
  focus <- flag path "focus" False object
  explicit <- optional path "panes" (nonemptyList (parsePane inputs local)) object
  panes <- case explicit of
    Just panes -> pure panes
    Nothing -> NonEmpty.singleton <$> parsePane inputs local (indexed (field path "panes") 0) Null
  let resolvedName = expand inputs <$> name
  traverse_ (validateText (field path "window_name")) resolvedName
  pure (WindowPlan resolvedName index layout local.directory local.environment focus panes)

parsePane :: PlanInputs -> Defaults -> Text -> Value -> Decode PanePlan
parsePane inputs inherited path value = do
  let object = case value of
        Null -> Object Keys.empty
        Object _ -> value
        _ -> Object (Keys.singleton "shell_command" value)
  fields <- mapping path object
  allow path ["start_directory", "environment", "focus", "shell_command", "shell_command_before",
    "enter", "suppress_history"] fields
  local <- defaults inputs path inherited fields
  focus <- flag path "focus" False fields
  enter <- flag path "enter" True fields
  own <- maybe [] id <$> optional path "shell_command" commandList fields
  let addCommand previous (line, override) =
        let next = maybe previous id override in (next, WorkspaceCommand (expand inputs line) next)
      resolved = snd (mapAccumL addCommand enter (local.beforeCommands <> own))
  traverse_ (validateText (field path "shell_command") . (.shellText)) resolved
  pure (PanePlan local.directory local.environment focus local.historySuppressed resolved)

defaults :: PlanInputs -> Text -> Defaults -> Object -> Decode Defaults
defaults inputs path inherited object = do
  directory <- optional path "start_directory" (parseDirectory inputs inherited.directory) object
  environment <- optional path "environment" (parseEnvironment inputs) object
  before <- maybe [] id <$> optional path "shell_command_before" commandList object
  history <- flag path "suppress_history" inherited.historySuppressed object
  pure (Defaults (directory <|> inherited.directory) (environment <|> inherited.environment)
    (inherited.beforeCommands <> before) history)

parseDirectory :: PlanInputs -> Maybe FilePath -> Text -> Value -> Decode FilePath
parseDirectory inputs parent path value = do
  source <- text path value
  let expanded = expand inputs source
  validateText path expanded
  when (Text.null expanded || Text.isPrefixOf "~" expanded) $
    Left (InvalidField path "expected a directory with an explicit home for ~")
  let resolved = normalise (maybe inputs.configDirectory id parent </> Text.unpack expanded)
  pure (if Text.isPrefixOf "." expanded then dropTrailingPathSeparator resolved else resolved)

parseEnvironment :: PlanInputs -> Text -> Value -> Decode (Map Text Text)
parseEnvironment inputs path value = do
  object <- mapping path value
  Map.fromList <$> traverse parseEntry (Keys.toList object)
  where
    parseEntry (key, entry) = do
      let name = Key.toText key
          location = field path name
      unless (validVariable name) $
        Left (InvalidField location "expected an environment variable name")
      configured <- text location entry
      let expanded = expand inputs configured
      validateText location expanded
      pure (name, expanded)

parseIndex :: Text -> Value -> Decode Tmux.WindowIndex
parseIndex path value = case fromJSON @Int32 value of
  Success number | Right index <- Tmux.mkWindowIndex (toInteger number) -> Right index
  _ -> Left (InvalidField path "expected an integer index from 0 through 2147483647")

parseLayout :: Text -> Value -> Decode Tmux.NamedLayout
parseLayout path value = text path value >>= \case
  "even-horizontal" -> Right Tmux.EvenHorizontal
  "even-vertical" -> Right Tmux.EvenVertical
  "main-horizontal" -> Right Tmux.MainHorizontal
  "main-vertical" -> Right Tmux.MainVertical
  "tiled" -> Right Tmux.Tiled
  _ -> Left (InvalidField path "expected one of tmux's five named layouts")

commandList :: Text -> Value -> Decode [(Text, Maybe Bool)]
commandList _ Null = Right []
commandList _ (String "blank") = Right []
commandList _ (String "pane") = Right []
commandList path (Array values) = case toList values of
  [Null] -> Right []
  [String "blank"] -> Right []
  [String "pane"] -> Right []
  entries -> traverse (uncurry command) (zipWith (\index item -> (indexed path index, item)) [0 ..] entries)
commandList path value = pure <$> command path value

command :: Text -> Value -> Decode (Text, Maybe Bool)
command path value@(String _) = (, Nothing) <$> text path value
command path value = do
  object <- mapping path value
  allow path ["cmd", "enter"] object
  line <- required path "cmd" text object
  enter <- optional path "enter" boolean object
  pure (line, enter)

expand :: PlanInputs -> Text -> Text
expand inputs = expandVariables inputs.variables . replaceHome
  where
    replaceHome source = case (inputs.homeDirectory, Text.stripPrefix "~" source) of
      (Just home, Just rest) | Text.null rest || Text.isPrefixOf "/" rest -> Text.pack home <> rest
      _ -> source

expandVariables :: Map Text Text -> Text -> Text
expandVariables variables source = case Text.breakOn "$" source of
  (prefix, rest) | Text.null rest -> prefix
  (prefix, rest) -> prefix <> substitute (Text.drop 1 rest)
  where
    substitute rest | Just braced <- Text.stripPrefix "{" rest =
      case Text.breakOn "}" braced of
        (name, suffix) | not (Text.null suffix) ->
          value ("${" <> name <> "}") name <> expandVariables variables (Text.drop 1 suffix)
        _ -> "$" <> expandVariables variables rest
    substitute rest = case Text.span variableCharacter rest of
      (name, suffix) | not (Text.null name) -> value ("$" <> name) name <> expandVariables variables suffix
      _ -> "$" <> expandVariables variables rest
    value original name = Map.findWithDefault original name variables

validVariable :: Text -> Bool
validVariable name = case Text.uncons name of
  Just (first, rest) -> (asciiLetter first || first == '_') && Text.all variableCharacter rest
  Nothing -> False

asciiLetter :: Char -> Bool
asciiLetter character = isAsciiLower character || isAsciiUpper character

variableCharacter :: Char -> Bool
variableCharacter character = asciiLetter character || isDigit character || character == '_'

text :: Text -> Value -> Decode Text
text path (String value) = validateText path value >> pure value
text path _ = Left (InvalidField path "expected text")

validateText :: Text -> Text -> Decode ()
validateText path value = when (Text.elem '\NUL' value) (Left (InvalidField path "text contains NUL"))

boolean :: Text -> Value -> Decode Bool
boolean _ (Bool value) = Right value
boolean path _ = Left (InvalidField path "expected a boolean")

mapping :: Text -> Value -> Decode Object
mapping _ (Object value) = Right value
mapping path _ = Left (InvalidField path "expected a mapping")

nonemptyList :: (Text -> Value -> Decode value) -> Text -> Value -> Decode (NonEmpty value)
nonemptyList parse path (Array entries)
  | Just items <- NonEmpty.nonEmpty (toList entries) =
      sequenceA (NonEmpty.zipWith (parse . indexed path) (0 :| [1 ..]) items)
nonemptyList _ path _ = Left (InvalidField path "expected a nonempty list")

allow :: Text -> [Text] -> Object -> Decode ()
allow path allowed object =
  case filter (`notElem` allowed) (map Key.toText (Keys.keys object)) of
    [] -> Right ()
    key : _ -> Left (UnsupportedField (field path key))

required :: Text -> Text -> (Text -> Value -> Decode value) -> Object -> Decode value
required path key parse object = optional path key parse object >>= maybe (Left (MissingField (field path key))) pure

optional :: Text -> Text -> (Text -> Value -> Decode value) -> Object -> Decode (Maybe value)
optional path key parse object = traverse (parse (field path key)) (Keys.lookup (Key.fromText key) object)

flag :: Text -> Text -> Bool -> Object -> Decode Bool
flag path key fallback object = maybe fallback id <$> optional path key boolean object

field :: Text -> Text -> Text
field "" name = name
field path name = path <> "." <> name

indexed :: Text -> Int -> Text
indexed path index = path <> "[" <> Text.pack (show index) <> "]"
