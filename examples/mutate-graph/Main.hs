{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Select physical targets, mutate them, and compare detached observations.
module Main (main) where

import Control.Exception (rethrowIO)
import Data.Function ((&))
import Data.Text qualified as Text
import LibTmux qualified as Tmux
import LibTmux.Query qualified as Q
import LibTmux.Query.Pane qualified as Pane
import System.Environment (getArgs)
import System.Exit (die)
import System.OsPath.Posix qualified as Path

main :: IO ()
main = getArgs >>= \case
  [socketArgument, executableArgument] -> do
    socket <- Path.encodeFS socketArgument
    executable <- Path.encodeFS executableArgument
    let config = (Tmux.serverConfig socket) {Tmux.executable = executable}
        selected = Q.panes & Q.matching (Q.eq Pane.active True)
    result <- Tmux.tryTmux $ Tmux.withServer config $ \server -> do
      before <- Tmux.capture server
      session <- require "Session selection" (Q.exactlyOne (Tmux.sessions before))
      matches <- require "Pane query" (Q.runQuery before selected)
      pane <- require "Pane selection" (Q.exactlyOne matches)
      window <- require "Pane's window" (Tmux.lookupWindow before pane.window)

      Tmux.renameSession server session.ref "workspace"
      Tmux.renameWindow server window.ref "api #{pid};"
      Tmux.setPaneTitle server pane.ref "editor-ready"
      after <- Tmux.capture server
      pure (before, after, session, window, pane)
    case result of
      Left problem -> rethrowIO problem
      Right (before, after, session, window, pane) -> do
        changedSession <- require "Fresh session" (Tmux.lookupSession after session.ref)
        changedWindow <- require "Fresh window" (Tmux.lookupWindow after window.ref)
        changedPane <- require "Fresh pane" (Tmux.lookupPane after pane.ref)
        oldWindow <- require "Old window" (Tmux.lookupWindow before window.ref)
        oldName <- require "Old window encoding" (Tmux.labelText oldWindow.name)
        newName <- require "New window encoding" (Tmux.labelText changedWindow.name)
        let links = [link | link <- Tmux.windowLinks after, link.window == window.ref]
        putStrLn $ "session: " <> Text.unpack session.name <> " -> " <> Text.unpack changedSession.name
        putStrLn $ "window: " <> Text.unpack oldName <> " -> " <> Text.unpack newName
        putStrLn $ "pane title: " <> Text.unpack changedPane.title
        putStrLn $ "physical window links: " <> show (length links)
        putStrLn $ "same target identities: " <> show
          (session.ref == changedSession.ref && window.ref == changedWindow.ref && pane.ref == changedPane.ref)
        putStrLn $ "old snapshot values: " <> Text.unpack session.name <> ", " <> Text.unpack oldName
  _ -> die "Usage: mutate-graph SOCKET TMUX_EXECUTABLE"

require :: Show problem => String -> Either problem a -> IO a
require context = either (die . ((context <> ": ") <>) . show) pure
