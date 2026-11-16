{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module OwnedServerApi where

import Data.List.NonEmpty (NonEmpty (..))
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import System.OsString.Posix qualified as Os

config :: Tmux.OwnedServerConfig
config = Tmux.defaultOwnedServerConfig
  { Tmux.tmuxExecutable = Os.fromBytestring "tmux"
  , Tmux.operationTimeout = 2
  }

open :: Tmux.OwnedServerConfig -> (Tmux.Server -> IO a) -> IO a
open = Tmux.withOwnedServer

lifecycle :: IO (Tmux.Snapshot, Tmux.CreatedSession)
lifecycle = open config $ \server -> do
  created <- Tmux.createSession server Creation.defaultSessionOptions
    { Creation.process = Creation.DirectCommand (Os.fromBytestring "/bin/cat") (Os.fromBytestring "-" :| []) }
  snapshot <- Tmux.capture server
  pure (snapshot, created)

retire :: Tmux.ServerConfig -> IO ()
retire adopted = Tmux.withServer adopted Tmux.killServer

kill :: Tmux.Server -> IO ()
kill = Tmux.killServer
