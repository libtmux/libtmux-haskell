{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Capture once, then navigate detached values after the Server scope closes.
module Main (main) where

import Control.Monad (forM_)
import Data.List (intercalate)
import Data.Text qualified as Text
import LibTmux qualified as Tmux
import System.Environment (getArgs)
import System.Exit (die)
import System.OsPath.Posix qualified as Path

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    [socketArgument, executableArgument] -> do
      socket <- Path.encodeFS socketArgument
      executable <- Path.encodeFS executableArgument
      let config = (Tmux.serverConfig socket) {Tmux.executable = executable}
      snapshot <- Tmux.withServer config Tmux.capture

      let activeWidePanes =
            [ pane
            | pane <- Tmux.panes snapshot
            , pane.active
            , Tmux.dimensionValue pane.width >= 120
            ]
      putStrLn $ "physical entities (sessions, windows, panes): " <> show
        (length (Tmux.sessions snapshot), length (Tmux.windows snapshot), length (Tmux.panes snapshot))
      putStrLn $ "contextual appearances (links, panes): " <> show
        (length (Tmux.windowLinks snapshot), length (Tmux.paneOccurrences snapshot))
      putStrLn $ "active panes at least 120 cells wide: " <> show (length activeWidePanes)

      forM_ (Tmux.sessions snapshot) $ \session -> do
        links <- either (fail . show) pure (Tmux.linksForSession snapshot session.ref)
        forM_ links $ \link -> do
          window <- either (fail . show) pure (Tmux.lookupWindow snapshot link.window)
          children <- either (fail . show) pure (Tmux.panesForWindow snapshot window.ref)
          let paneIds = [Text.unpack (Tmux.renderPaneId (Tmux.paneId pane.ref)) | pane <- children]
          putStrLn $ Text.unpack session.name <> ":" <> show (Tmux.windowIndexValue link.index)
            <> " -> " <> Text.unpack (Tmux.renderWindowId (Tmux.windowId window.ref))
            <> " panes=" <> intercalate "," paneIds
    _ -> die "Usage: capture-graph SOCKET TMUX_EXECUTABLE"
