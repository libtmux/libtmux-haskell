module CatalogueTest (tests) where

import Control.Monad (forM)
import Data.Aeson
import Data.Aeson.KeyMap qualified as Keys
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.List (sort)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import LibTmux qualified as Tmux
import LibTmux.Workspace qualified as Workspace
import System.Directory (listDirectory)
import System.Environment (lookupEnv)
import System.FilePath.Posix ((</>), replaceExtension, takeExtension)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests = testGroup "tmuxp planning"
  [ testCase "canonical fixture structure and form coverage" $ do
      let root = "test/fixtures/tmuxp"
          manifests = root </> "expected"
      names <- sort . filter ((== ".yaml") . takeExtension) <$> listDirectory root
      canonical <- sort . filter ((== ".json") . takeExtension)
        . filter (/= "syntax-features.json") <$> listDirectory manifests
      canonical @?= map (`replaceExtension` "json") names
      length names @?= 23
      verdicts <- forM names $ \name -> do
        bytes <- Bytes.readFile (root </> name)
        canonicalValue <- readJSON (manifests </> replaceExtension name "json")
        expected <- either fail pure (parseEither canonicalPlan canonicalValue)
        pure (name, case Workspace.planTmuxp inputs bytes of
          Left problem -> object ["status" .= ("refused" :: Text), "reason" .= show problem]
          Right plan ->
            let actual = previewValue (Workspace.previewWorkspace plan)
            in if actual == expected then object ["status" .= ("matches" :: Text)]
               else object ["status" .= ("differs" :: Text), "observed" .= actual, "canonical" .= expected])
      catalogue <- readJSON (manifests </> "syntax-features.json")
      forms <- either fail pure (parseEither (withObject "feature catalogue" (.: "features")) catalogue)
      coverage <- traverse (either fail pure . parseEither (formCoverage (Map.fromList verdicts))) forms
      let report = object ["examples" .= Map.fromList verdicts, "forms" .= (coverage :: [Value])]
      lookupEnv "LIBTMUX_WORKSPACE_REPORT" >>= \case
        Just output -> Lazy.writeFile output (encode report <> "\n")
        Nothing -> readJSON (root </> "compatibility.json") >>= (@?= report)

  , testCase "refuse malformed YAML before planning and retain its marked position" $ do
      let top = "session_name: test\nwindows:\n  - panes: [blank]\n"
          refuses code bytes = case Workspace.planTmuxp inputs bytes of
            Left (Workspace.InvalidYaml problem) -> problem.code @?= code
            _ -> assertFailure ("expected YAML refusal " <> Text.unpack code)
      refuses "duplicate-key" (top <> "session_name: duplicate\n")
      refuses "duplicate-key" "session_name: test\nwindows: [{panes: [blank], panes: []}]\n"
      refuses "alias" "session_name: test\nwindows: &loop [*loop]\n"
      refuses "non-text-key" (top <> "12: true\n")
      refuses "multiple-documents" (top <> "---\nother: true\n")
      refuses "custom-tag" (top <> "other: !unknown test\n")
      refuses "depth-limit" ("windows: " <> Bytes.replicate 65 91 <> "0" <> Bytes.replicate 65 93)
      refuses "input-limit" (Bytes.replicate (1048576 + 1) 32)
      case Workspace.planTmuxp inputs (top <> "session_name: duplicate\n") of
        Left (Workspace.InvalidYaml problem) -> (problem.line, problem.column) @?= (Just 4, Just 1)
        _ -> assertFailure "duplicate key lost its source position"
      case Workspace.planTmuxp inputs "session_name: test\nwindows: [{window_index: 2147483648}]\n" of
        Left (Workspace.InvalidField "windows[0].window_index" _) -> pure ()
        _ -> assertFailure "unrepresentable native window index was accepted"

  , testCase "accept each released native layout name" $
      mapM_ (\(name, layout) -> do
        let yaml = "session_name: test\nwindows:\n  - layout: " <> name
        plan <- either (fail . show) pure (Workspace.planTmuxp inputs yaml)
        (NonEmpty.head (Workspace.previewWorkspace plan).windows).layout @?= Just layout)
        [("even-horizontal", Tmux.EvenHorizontal), ("even-vertical", Tmux.EvenVertical),
         ("main-horizontal", Tmux.MainHorizontal), ("main-vertical", Tmux.MainVertical), ("tiled", Tmux.Tiled)]
  ]

inputs :: Workspace.PlanInputs
inputs = (Workspace.defaultPlanInputs "/@WORKSPACE_DIR@")
  { Workspace.homeDirectory = Just "/@HOME@"
  , Workspace.variables = Map.fromList
      [("HOME", "/@HOME@"), ("PWD", "/@PWD@"), ("USER", "@USER@"),
       ("MY_ENV_VAR", "/@MY_ENV_VAR@"), ("SERVER_PORT", "@SERVER_PORT@"),
       ("MAIN_PANE_HEIGHT", "@MAIN_PANE_HEIGHT@")]
  }

previewValue :: Workspace.WorkspacePreview -> Value
previewValue plan = object
  [ "session" .= object
      [ "session_name" .= plan.sessionName
      , "start_directory" .= plan.sessionDirectory
      , "environment" .= (if Map.null plan.sessionEnvironment then Null else toJSON plan.sessionEnvironment)
      ]
  , "windows" .= map window (NonEmpty.toList plan.windows)
  ]
  where
    window value = object
      [ "window_name" .= value.windowName
      , "window_index" .= (Tmux.windowIndexValue <$> value.windowIndex)
      , "start_directory" .= value.windowDirectory
      , "environment" .= value.windowEnvironment
      , "layout" .= (layoutName <$> value.layout)
      , "focus" .= value.focusWindow
      , "panes" .= map pane (NonEmpty.toList value.panes)
      ]
    pane value = object
      [ "start_directory" .= value.paneDirectory
      , "environment" .= value.paneEnvironment
      , "focus" .= value.focusPane
      , "suppress_history" .= value.suppressHistory
      , "commands" .= map (\line -> object ["cmd" .= line.shellText, "enter" .= line.sendEnter]) value.commands
      ]
    layoutName :: Tmux.NamedLayout -> Text
    layoutName = \case
      Tmux.EvenHorizontal -> "even-horizontal"
      Tmux.EvenVertical -> "even-vertical"
      Tmux.MainHorizontal -> "main-horizontal"
      Tmux.MainVertical -> "main-vertical"
      Tmux.Tiled -> "tiled"

canonicalPlan :: Value -> Parser Value
canonicalPlan = withObject "canonical plan" $ \entry -> do
  session <- entry .: "session"
  windows <- entry .: "windows" >>= traverse window
  pure (object ["session" .= select ["session_name", "start_directory", "environment"] session,
    "windows" .= (windows :: [Value])])
  where
    window = withObject "canonical window" $ \entry -> do
      panes <- entry .: "panes" >>= traverse pane
      pure (Object (Keys.insert "panes" (toJSON (panes :: [Value]))
        (select ["window_name", "window_index", "start_directory", "environment", "layout", "focus"] entry)))
    pane = withObject "canonical pane" $ \entry -> do
      commands <- map (select ["cmd", "enter"]) <$> entry .: "commands"
      runtime <- entry .: "runtime"
      let base = select ["start_directory", "environment", "focus"] entry
          history = select ["suppress_history"] runtime
      pure (Object (Keys.insert "commands" (toJSON commands) (history <> base)))
    select :: [Key] -> Object -> Object
    select keys = Keys.fromList . filter ((`elem` keys) . fst) . Keys.toList

formCoverage :: Map.Map FilePath Value -> Value -> Parser Value
formCoverage verdicts = withObject "canonical form" $ \entry -> do
  name <- entry .: "id" :: Parser Text
  files <- entry .: "files" :: Parser [FilePath]
  results <- traverse (\file -> maybe (fail "unknown fixture") pure (Map.lookup file verdicts)) files
  statuses <- traverse (withObject "example verdict" (.: "status")) results :: Parser [Text]
  let evidence
        | "matches" `elem` statuses = "matching preview"
        | "differs" `elem` statuses = "preview difference"
        | null statuses = "no catalog case"
        | otherwise = "only refused examples"
  pure (object ["id" .= name, "evidence" .= (evidence :: Text), "files" .= files])

readJSON :: FilePath -> IO Value
readJSON path = either fail pure =<< eitherDecodeFileStrict' path
