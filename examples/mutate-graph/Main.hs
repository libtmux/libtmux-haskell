{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Text qualified as Text
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation

main :: IO ()
main = do
  (created, before, after) <-
    Tmux.withOwnedServer Tmux.defaultOwnedServerConfig $ \server -> do
      created <- Tmux.createSession server Creation.defaultSessionOptions
        { Creation.name = Just "demo"
        , Creation.windowName = Just "editor"
        , Creation.process = Creation.ShellCommand "exec /bin/cat -"
        }
      before <- Tmux.capture server
      Tmux.renameSession server created.session "workspace"
      Tmux.renameWindow server created.window "api #{pid};"
      Tmux.setPaneTitle server created.pane "editor-ready"
      after <- Tmux.capture server
      pure (created, before, after)

  previous <- either (fail . show) pure
    (Tmux.lookupSession before created.session)
  current <- either (fail . show) pure
    (Tmux.lookupSession after created.session)
  window <- either (fail . show) pure (Tmux.lookupWindow after created.window)
  pane <- either (fail . show) pure (Tmux.lookupPane after created.pane)
  label <- either (fail . show) pure (Tmux.labelText window.name)
  putStrLn $ "Session: " <> Text.unpack previous.name
    <> " -> " <> Text.unpack current.name
  putStrLn $ "Window: " <> Text.unpack label
  putStrLn $ "Pane title: " <> Text.unpack pane.title
