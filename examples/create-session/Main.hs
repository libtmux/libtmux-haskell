{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Create native targets, refresh their graph, and retain detached values.
module Main (main) where

import Control.Exception (ExceptionWithContext (..), rethrowIO)
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
    let config = (Tmux.serverConfig socket) {Tmux.executable = executable}
        options = Creation.defaultSessionOptions
          { Creation.name = Just "workspace"
          , Creation.windowName = Just (Tmux.labelFromBytes "editor")
          , Creation.width = Just width
          , Creation.process = Creation.DirectCommand (Os.fromBytestring "/bin/cat") (Os.fromBytestring "-" :| [])
          }
    result <- Tmux.tryTmux $ Tmux.withServer config $ \server -> do
      before <- Tmux.capture server
      created <- Tmux.createSession server options
      Tmux.renameWindow server created.window "api"
      Tmux.setPaneTitle server created.pane "editor-ready"
      after <- Tmux.capture server
      duplicate <- Tmux.tryTmux (Tmux.createSession server options)
      rejected <- case duplicate of
        Left (ExceptionWithContext _ (Tmux.MutationRejected _)) -> pure True
        Left problem -> rethrowIO problem
        Right _ -> die "Duplicate creation unexpectedly succeeded"
      pure (created, before, after, rejected)
    case result of
      Left problem -> rethrowIO problem
      Right (created, before, after, rejected) -> do
        session <- require "Created session" (Tmux.lookupSession after created.session)
        window <- require "Created window" (Tmux.lookupWindow after created.window)
        pane <- require "Created pane" (Tmux.lookupPane after created.pane)
        links <- require "Created session links" (Tmux.linksForSession after created.session)
        label <- require "Window label" (Tmux.labelText window.name)
        putStrLn $ "created session: " <> Text.unpack session.name
        putStrLn $ "initial window: " <> Text.unpack label
        putStrLn $ "pane title: " <> Text.unpack pane.title
        putStrLn $ "same created targets: " <> show (session.ref == created.session && window.ref == created.window && pane.ref == created.pane)
        putStrLn $ "captured sessions: " <> show (length (Tmux.sessions before)) <> " -> " <> show (length (Tmux.sessions after))
        putStrLn $ "created window links: " <> show (length links)
        putStrLn $ "duplicate name rejected: " <> show rejected
  _ -> die "Usage: create-session SOCKET TMUX_EXECUTABLE"

require :: Show problem => String -> Either problem a -> IO a
require context = either (die . ((context <> ": ") <>) . show) pure
