{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Create native targets, refresh their graph, and retain detached values.
module Main (main) where

import Control.Exception (ExceptionWithContext (..), rethrowIO)
import Control.Monad (unless)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import System.Environment (getArgs)
import System.Exit (die)
import System.OsPath.Posix qualified as Path
import System.OsString.Posix qualified as Os

main :: IO ()
main = getArgs >>= \case
  [socketArgument, executableArgument] -> do
    socket <- Path.encodeFS socketArgument
    executable <- Path.encodeFS executableArgument
    width <- require "Width" (Tmux.mkDimension 120)
    extraIndex <- require "Second link index" (Tmux.mkWindowIndex 4)
    let config = (Tmux.serverConfig socket) {Tmux.executable = executable}
        options = Creation.defaultSessionOptions
          { Creation.name = Just "created-workspace"
          , Creation.windowName = Just (Tmux.labelFromBytes "editor")
          , Creation.width = Just width
          , Creation.process = Creation.DirectCommand (Os.fromBytestring "/bin/cat") (Os.fromBytestring "-" :| [])
          }
    result <- Tmux.tryTmux $ Tmux.withServer config $ \server -> do
      before <- Tmux.capture server
      created <- Tmux.createSession server options
      let environment = Tmux.SessionEnvironment created.session
          key = "LIBTMUX_EXAMPLE_STATE"
      Tmux.setEnvironment server environment key Tmux.Visible ""
      empty <- Tmux.getEnvironment server environment key
      Tmux.markEnvironmentRemoved server environment key
      removed <- Tmux.getEnvironment server environment key
      Tmux.unsetEnvironment server environment key
      absent <- Tmux.getEnvironment server environment key
      unless (empty == Just (Tmux.EnvironmentValue Tmux.Visible "")
          && removed == Just (Tmux.EnvironmentRemoved Tmux.Visible) && absent == Nothing)
        (die "Expected distinct empty, removed and absent entries")
      Tmux.renameWindow server created.window "api"
      Tmux.setPaneTitle server created.pane "editor-ready"
      added <- Tmux.createWindow server (Creation.NextFree created.session)
        Creation.defaultWindowOptions {Creation.windowLabel = Just "worker", Creation.windowProcess = options.process}
      let workerSlot = Creation.WindowSlot added.session added.windowIndex
          secondLink = Creation.WindowSlot added.session extraIndex
      split <- Tmux.splitPane server workerSlot added.pane
        Creation.defaultSplitOptions
          { Creation.direction = Creation.LeftRight
          , Creation.size = Creation.SplitPercent 25
          , Creation.splitProcess = Creation.ShellCommand
              "stty -echo; printf 'input-ready\\n'; exec /bin/cat -"
          }
      Tmux.linkWindow server workerSlot secondLink
      Tmux.selectWindowLink server secondLink
      Tmux.selectExactPane server secondLink split.pane
      Tmux.selectLayout server secondLink Tmux.Tiled
      linked <- Tmux.capture server
      linkedSlots <- require "Worker links" (Tmux.linksForSession linked added.session)
      let workerIndices = [Tmux.windowIndexValue link.index | link <- linkedSlots, link.window == added.window]
      Tmux.unlinkWindow server secondLink
      _ <- awaitText server split.pane Tmux.defaultPaneWait "input-ready"
      baseline <- Tmux.capturePane server split.pane Tmux.defaultPaneCapture
      Tmux.sendKeys server split.pane (Tmux.LiteralText "Enter")
      Tmux.sendKeys server split.pane (Tmux.NamedKeys ("Enter" :| []))
      screen <- awaitText server split.pane
        Tmux.defaultPaneWait {Tmux.waitMatch = Tmux.FreshSince baseline} "Enter"
      after <- Tmux.capture server
      duplicate <- Tmux.tryTmux (Tmux.createSession server options)
      rejected <- case duplicate of
        Left (ExceptionWithContext _ (Tmux.MutationRejected _)) -> pure True
        Left problem -> rethrowIO problem
        Right _ -> die "Duplicate creation unexpectedly succeeded"
      Tmux.killSession server created.session
      let disposable = options {Creation.name = Nothing}
      windowOwner <- Tmux.createSession server disposable
      Tmux.killWindow server windowOwner.window
      paneOwner <- Tmux.createSession server disposable
      Tmux.killPane server paneOwner.pane
      remaining <- Tmux.capture server
      pure (created, added, split, before, after, screen, workerIndices, rejected, remaining)
    case result of
      Left problem -> rethrowIO problem
      Right (created, added, split, before, after, screen, workerIndices, rejected, remaining) -> do
        session <- require "Created session" (Tmux.lookupSession after created.session)
        window <- require "Created window" (Tmux.lookupWindow after created.window)
        pane <- require "Created pane" (Tmux.lookupPane after created.pane)
        worker <- require "New window" (Tmux.lookupWindow after added.window)
        panes <- require "New window panes" (Tmux.panesForWindow after added.window)
        splitPane <- require "Split pane" (Tmux.lookupPane after split.pane)
        links <- require "Created session links" (Tmux.linksForSession after created.session)
        label <- require "Window label" (Tmux.labelText window.name)
        workerLabel <- require "New window label" (Tmux.labelText worker.name)
        putStrLn $ "created session: " <> Text.unpack session.name
        putStrLn "session environment: empty, removed, absent"
        putStrLn $ "initial window: " <> Text.unpack label
        putStrLn $ "pane title: " <> Text.unpack pane.title
        putStrLn $ "same created targets: " <> show (session.ref == created.session && window.ref == created.window && pane.ref == created.pane)
        putStrLn $ "captured sessions: " <> show (length (Tmux.sessions before)) <> " -> " <> show (length (Tmux.sessions after))
        putStrLn $ "created session links: " <> show (length links)
        putStrLn $ "new window: " <> Text.unpack workerLabel
        putStrLn $ "new window panes: " <> show (length panes)
        putStrLn $ "same worker window at indices: " <> show workerIndices
        putStrLn $ "split exact target: " <> show (splitPane.window == added.window && split.session == added.session && split.windowIndex == added.windowIndex)
        putStrLn $ "captured pane rows match height: " <> show
          (toInteger (length (Text.lines (Tmux.paneText screen))) == Tmux.dimensionValue splitPane.height)
        putStrLn "captured pane text"
        putStr (Text.unpack (Text.unlines (filter (not . Text.null) (Text.lines (Tmux.paneText screen)))))
        putStrLn $ "duplicate name rejected: " <> show rejected
        putStrLn $ "original sessions after removal: " <> show
          (map (.ref) (Tmux.sessions remaining) == map (.ref) (Tmux.sessions before))
  _ -> die "Usage: create-session SOCKET TMUX_EXECUTABLE"

awaitText :: Tmux.Server -> Tmux.PaneRef -> Tmux.PaneWaitOptions -> Text.Text -> IO Tmux.PaneText
awaitText server pane options expected =
  Tmux.waitForText server pane options expected >>= \case
    Tmux.PaneTextMatched screen -> pure screen
    Tmux.PaneTextTimedOut _ _ -> die "Timed out waiting for pane text"
    Tmux.PaneTextExited _ -> die "Pane exited before producing text"

require :: Show problem => String -> Either problem a -> IO a
require context = either (die . ((context <> ": ") <>) . show) pure
