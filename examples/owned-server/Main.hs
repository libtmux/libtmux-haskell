{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Start a private tmux server, create a session in it, and stop the server.
module Main (main) where

import Control.Exception (ExceptionWithContext (..))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import System.Exit (die)
import System.OsString.Posix qualified as Os

main :: IO ()
main = do
  let options = Creation.defaultSessionOptions
        { Creation.name = Just "owned-workspace"
        , Creation.process = Creation.DirectCommand (Os.fromBytestring "/bin/cat") (Os.fromBytestring "-" :| [])
        }
  (server, created, snapshot) <- Tmux.withOwnedServer Tmux.defaultOwnedServerConfig $ \server -> do
    created <- Tmux.createSession server options
    snapshot <- Tmux.capture server
    pure (server, created, snapshot)
  session <- either (die . show) pure (Tmux.lookupSession snapshot created.session)
  putStrLn $ "created session: " <> Text.unpack session.name
  putStrLn $ "sessions in the owned server: " <> show (length (Tmux.sessions snapshot))
  putStrLn $ "creation and capture name one daemon: " <> show (created.serverPid == (Tmux.serverInfo snapshot).pid)
  closed <- Tmux.tryTmux (Tmux.capture server)
  case closed of
    Left (ExceptionWithContext _ Tmux.ServerClosed) -> putStrLn "server closed after the scope: True"
    _ -> die "A retained Server still accepted a capture"
