-- | Execute a validated plan through the public libtmux API.
module LibTmux.Workspace.Apply
  ( applyWorkspace
  , WorkspaceApplyError (..)
  , WorkspaceRecovery, workspaceRecoveries, workspaceRecoverySession, pendingWorkspaceCreation
  ) where

import Control.Concurrent.STM (atomically)
import Control.Exception
  ( Exception, ExceptionWithContext (..), SomeException, catchNoPropagate, mask, rethrowIO, throwIO )
import Control.Exception.Annotation (ExceptionAnnotation)
import Control.Exception.Context qualified as Context
import Control.Monad (forM_, unless)
import Data.ByteString qualified as Bytes
import Data.Char (ord)
import Data.Foldable (toList, traverse_)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Utf8
import Data.Unique (hashUnique, newUnique)
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import LibTmux.Recovery qualified as Recovery
import LibTmux.Workspace.Plan (PanePlan (..), WindowPlan (..), WorkspaceCommand (..), WorkspacePlan (..), WorkspacePreview (..))
import Numeric (showOct)
import System.Directory (doesDirectoryExist)
import System.OsString.Posix (PosixString)
import System.OsString.Posix qualified as Os
import System.Timeout (timeout)

-- | A missing directory or a pane whose shell did not acknowledge input.
data WorkspaceApplyError
  = DirectoryUnavailable !FilePath
  | ShellAcknowledgementTimedOut !Tmux.PaneRef
  | ShellObservationEnded !Tmux.PaneRef !Tmux.ControlEnd
  deriving stock (Show)

instance Exception WorkspaceApplyError

-- | Ownership from an unsuccessful apply. It can hold a known session or
-- the native creation owner when the initial request was interrupted.
data WorkspaceRecovery
  = KnownSession !Tmux.SessionRef
  | PendingSession !Recovery.CreationRecovery
  deriving stock (Show)

instance ExceptionAnnotation WorkspaceRecovery

-- | Find workspace owners retained in an exception's context.
workspaceRecoveries :: Context.ExceptionContext -> [WorkspaceRecovery]
workspaceRecoveries = Context.getExceptionAnnotations

-- | Read the exact identity of the new session when observed. Use that
-- reference with @killSession@ from "LibTmux.Server" to retire the session.
workspaceRecoverySession :: WorkspaceRecovery -> IO (Maybe Tmux.SessionRef)
workspaceRecoverySession (KnownSession session) = pure (Just session)
workspaceRecoverySession (PendingSession creation) = fmap (.session) <$> Recovery.creationReceipt creation

-- | Inspect or resume the outstanding initial creation with "LibTmux.Recovery".
pendingWorkspaceCreation :: WorkspaceRecovery -> Maybe Recovery.CreationRecovery
pendingWorkspaceCreation (PendingSession creation) = Just creation
pendingWorkspaceCreation (KnownSession _) = Nothing

-- | Create a new detached session and apply the window and pane plans.
-- The returned reference belongs to the caller's Server. Before sending any
-- configured commands, observe an acknowledgement from each shell that will
-- receive input. Failure or cancellation retains the new session or its
-- creation evidence.
applyWorkspace :: Tmux.Server -> WorkspacePlan -> IO Tmux.SessionRef
applyWorkspace server (WorkspacePlan preview) = mask $ \restore -> do
  restore (checkDirectories preview)
  created <- catchNoPropagate create annotateCreation
  catchNoPropagate (restore (build created)) (retain [KnownSession created.session])
  where
    create = Tmux.createSession server Creation.defaultSessionOptions
      { Creation.name = Just preview.sessionName
      , Creation.windowName = Just "workspace-bootstrap"
      , Creation.workingDirectory = pathBytes <$> preview.sessionDirectory
      , Creation.environment = environmentBytes preview.sessionEnvironment
      , Creation.updateEnvironment = False
      }
    annotateCreation original@(ExceptionWithContext context (_ :: SomeException)) =
      retain (map PendingSession (Recovery.creationRecoveries context)) original
    build created = do
      let initial = slot created
      reserved <- either (fail . show) pure (bootstrapIndex preview.windows created.windowIndex)
      let temporary = Tmux.WindowSlot created.session reserved
      Tmux.linkWindow server initial temporary
      Tmux.unlinkWindow server initial
      built <- traverse (buildWindow server created.session) preview.windows
      Tmux.killWindow server created.window
      let choices = NonEmpty.zipWith (\desired actual -> (desired.focusWindow, actual)) preview.windows built
          BuiltWindow selected _ = chooseFocus (NonEmpty.head built) choices
      Tmux.selectWindowLink server selected
      let input = [(pane, plan) | BuiltWindow _ panes <- toList built, (pane, plan) <- toList panes,
                    not (null plan.commands)]
      unless (null input) $ Tmux.withControl server created.session
        Tmux.defaultControlOptions {Tmux.includePaneOutput = True, Tmux.eventCapacity = 128} $ \observer ->
          traverse_ (acknowledgeShell server observer . fst) input
      traverse_ (uncurry (sendCommands server)) input
      pure created.session

data BuiltWindow = BuiltWindow !Tmux.WindowSlot !(NonEmpty (Tmux.PaneRef, PanePlan))

buildWindow :: Tmux.Server -> Tmux.SessionRef -> WindowPlan -> IO BuiltWindow
buildWindow server session plan = do
  let initial :| rest = plan.panes
      placement = maybe (Creation.NextFree session) (Creation.At . Tmux.WindowSlot session) plan.windowIndex
      options = Creation.defaultWindowOptions
        { Creation.windowLabel = Tmux.labelFromBytes . Utf8.encodeUtf8 <$> plan.windowName
        , Creation.windowDirectory = pathBytes <$> initial.paneDirectory
        , Creation.windowEnvironment = maybe [] environmentBytes initial.paneEnvironment
        }
  created <- Tmux.createWindow server placement options
  let target = slot created
      add previous pane = do
        next <- Tmux.splitPane server target previous Creation.defaultSplitOptions
          { Creation.splitDirectory = pathBytes <$> pane.paneDirectory
          , Creation.splitEnvironment = maybe [] environmentBytes pane.paneEnvironment
          }
        Tmux.selectLayout server target Tmux.Tiled
        pure next.pane
  following <- appendPanes add created.pane rest
  traverse_ (Tmux.selectLayout server target) plan.layout
  let allPanes = (created.pane, initial) :| following
      candidates = NonEmpty.zipWith (\position actual -> (position.focusPane, actual)) plan.panes allPanes
      (selected, _) = chooseFocus (NonEmpty.last allPanes) candidates
  Tmux.selectExactPane server target selected
  pure (BuiltWindow target allPanes)

appendPanes :: (Tmux.PaneRef -> PanePlan -> IO Tmux.PaneRef) -> Tmux.PaneRef -> [PanePlan] -> IO [(Tmux.PaneRef, PanePlan)]
appendPanes _ _ [] = pure []
appendPanes add previous (pane : rest) = do
  next <- add previous pane
  ((next, pane) :) <$> appendPanes add next rest

chooseFocus :: result -> NonEmpty (Bool, result) -> result
chooseFocus fallback = maybe fallback snd . find fst . reverse . NonEmpty.toList

acknowledgeShell :: Tmux.Server -> Tmux.Control -> Tmux.PaneRef -> IO ()
acknowledgeShell server observer pane = do
  unique <- hashUnique <$> newUnique
  let marker = "workspace-ready-" <> Text.pack (show unique)
      encoded = Text.concatMap (\character -> Text.pack ('\\' : showOct (ord character) "")) marker
  -- The typed line contains only the octal spelling. Its terminal echo
  -- cannot be mistaken for the bytes produced by printf.
  Tmux.sendKeys server pane (Tmux.LiteralText (" command printf '" <> encoded <> "\\n'"))
  Tmux.sendKeys server pane (Tmux.NamedKeys ("Enter" :| []))
  timeout 1000000 (observe (Utf8.encodeUtf8 marker) Bytes.empty) >>= \case
    Just (Right ()) -> pure ()
    Just (Left reason) -> throwIO (ShellObservationEnded pane reason)
    Nothing -> throwIO (ShellAcknowledgementTimedOut pane)
  where
    prefix = "%output " <> Utf8.encodeUtf8 (Tmux.renderPaneId (Tmux.paneId pane)) <> " "
    observe marker carried = atomically (Tmux.readControlEvent observer) >>= \case
      Left reason -> pure (Left reason)
      Right (Tmux.ControlNotification line) | Just fragment <- Bytes.stripPrefix prefix line -> do
        let output = carried <> fragment
        if marker `Bytes.isInfixOf` output then pure (Right ())
        else observe marker (Bytes.drop (Bytes.length output - Bytes.length marker + 1) output)
      Right _ -> observe marker carried

sendCommands :: Tmux.Server -> Tmux.PaneRef -> PanePlan -> IO ()
sendCommands server pane plan = forM_ plan.commands $ \command -> do
  unless (Text.null command.shellText) $ do
    let literal = if plan.suppressHistory then " " <> command.shellText else command.shellText
    Tmux.sendKeys server pane (Tmux.LiteralText literal)
  if command.sendEnter then Tmux.sendKeys server pane (Tmux.NamedKeys ("Enter" :| [])) else pure ()

checkDirectories :: WorkspacePreview -> IO ()
checkDirectories plan = forM_ directories $ \path -> do
  exists <- doesDirectoryExist path
  unless exists (throwIO (DirectoryUnavailable path))
  where
    directories = Set.fromList
      [ path
      | candidate <- plan.sessionDirectory :
          [ pane.paneDirectory | window <- NonEmpty.toList plan.windows, pane <- NonEmpty.toList window.panes ]
      , Just path <- [candidate]
      ]

bootstrapIndex :: NonEmpty WindowPlan -> Tmux.WindowIndex -> Either Tmux.ValueError Tmux.WindowIndex
bootstrapIndex windows occupied = Tmux.mkWindowIndex (next 99)
  where
    planned = Set.fromList (Tmux.windowIndexValue occupied :
      [Tmux.windowIndexValue index | window <- NonEmpty.toList windows, Just index <- [window.windowIndex]])
    next candidate | Set.member candidate planned = next (candidate + 1)
                   | otherwise = candidate

slot :: Creation.CreatedEntities -> Tmux.WindowSlot
slot created = Tmux.WindowSlot created.session created.windowIndex

pathBytes :: FilePath -> PosixString
pathBytes = Os.fromBytestring . Utf8.encodeUtf8 . Text.pack

environmentBytes :: Map Text Text -> [(PosixString, PosixString)]
environmentBytes = map (\(name, value) -> (encode name, encode value)) . Map.toAscList
  where
    encode = Os.fromBytestring . Utf8.encodeUtf8

retain :: [WorkspaceRecovery] -> ExceptionWithContext SomeException -> IO a
retain owners (ExceptionWithContext context problem) =
  rethrowIO (ExceptionWithContext (foldr Context.addExceptionAnnotation context owners) problem)
