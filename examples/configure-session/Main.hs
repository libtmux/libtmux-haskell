{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (bracket)
import Control.Monad (unless)
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import System.Environment (getArgs)
import System.Exit (die)
import System.OsPath.Posix qualified as Path

main :: IO ()
main = getArgs >>= \case
  [socketArgument, executableArgument] -> do
    socket <- Path.encodeFS socketArgument
    executable <- Path.encodeFS executableArgument
    let config = (Tmux.serverConfig socket) {Tmux.executable = executable}
        options = Creation.defaultSessionOptions {Creation.process = Creation.ShellCommand "exec /bin/cat"}
    Tmux.withServer config $ \server ->
      bracket (Tmux.createSession server options) (Tmux.killSession server . (.session)) $ \created -> do
        let local = Tmux.SessionOptionsAt created.session
            event = "after-rename-window"
        Tmux.setOption server local "history-limit" (Tmux.NumberValue 500)
        stored <- Tmux.readOption server local Tmux.LocalOption "history-limit"
        case stored of
          Just (Tmux.NumberValue rows) -> putStrLn ("local history-limit = " <> show rows)
          _ -> die "Expected a local numeric history limit"
        Tmux.setHook server local event 0 "set-option @last-rename seen"
        hook <- Tmux.readHook server local event
        unless (hook == Just "after-rename-window[0] set-option @last-rename seen\n")
          (die "Expected one entry in the local rename hook")
        Tmux.renameWindow server created.window "review"
        observed <- Tmux.readOption server local Tmux.LocalOption "@last-rename"
        unless (observed == Just (Tmux.StringValue "seen")) (die "The rename hook did not run")
        putStrLn "rename hook recorded the change"
  _ -> die "Usage: configure-session SOCKET TMUX_EXECUTABLE"
