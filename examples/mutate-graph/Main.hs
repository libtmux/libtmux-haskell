{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import System.OsString.Posix qualified as Os

main :: IO ()
main = do
  (created, before, after) <-
    Tmux.withOwnedServer Tmux.defaultOwnedServerConfig $ \server -> do
      created <- Tmux.createSession server Creation.defaultSessionOptions
        { Creation.name = Just "demo"
        , Creation.windowName = Just "editor"
        , Creation.process = cat
        }
      before <- Tmux.capture server
      Tmux.renameSession server created.session "workspace"
      Tmux.renameWindow server created.window "api #{pid};"
      Tmux.setPaneTitle server created.pane "editor-ready"
      index <- require (Tmux.mkWindowIndex 5)
      let editor = Tmux.WindowSlot created.session created.windowIndex
          temporary = Tmux.WindowSlot created.session index
      worker <- Tmux.splitPane server editor created.pane
        Creation.defaultSplitOptions {Creation.splitProcess = cat}
      split <- Tmux.capture server
      workerInEditor <- require (Tmux.lookupPaneOccurrence split editor worker.pane)
      _ <- Tmux.breakPane server workerInEditor temporary
      separated <- Tmux.capture server
      workerOutside <- require (Tmux.lookupPaneOccurrence separated temporary worker.pane)
      editorPane <- require (Tmux.lookupPaneOccurrence separated editor created.pane)
      _ <- Tmux.movePane server workerOutside editorPane Tmux.defaultPaneMoveOptions
      after <- Tmux.capture server
      _ <- require (Tmux.lookupPaneOccurrence after editor worker.pane)
      pure (created, before, after)

  previous <- require (Tmux.lookupSession before created.session)
  current <- require (Tmux.lookupSession after created.session)
  window <- require (Tmux.lookupWindow after created.window)
  pane <- require (Tmux.lookupPane after created.pane)
  label <- require (Tmux.labelText window.name)
  putStrLn $ "Session: " <> Text.unpack previous.name
    <> " -> " <> Text.unpack current.name
  putStrLn $ "Window: " <> Text.unpack label
  putStrLn $ "Pane title: " <> Text.unpack pane.title
  putStrLn "Worker moved back to its original window"

cat :: Creation.InitialProcess
cat = Creation.DirectCommand (Os.fromBytestring "/bin/cat") (Os.fromBytestring "-" :| [])

require :: Show problem => Either problem a -> IO a
require = either (fail . show) pure
