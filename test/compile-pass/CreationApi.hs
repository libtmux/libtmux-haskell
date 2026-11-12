{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module CreationApi where

import Data.List.NonEmpty (NonEmpty (..))
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import System.OsString.Posix qualified as Os

options :: Tmux.SessionOptions
options = Creation.defaultSessionOptions
  { Creation.name = Just "workspace"
  , Creation.process = Creation.DirectCommand (Os.fromBytestring "/bin/cat") (Os.fromBytestring "-" :| [])
  }

create :: Tmux.Server -> IO Tmux.CreatedSession
create server = Tmux.createSession server options

targets :: Tmux.CreatedSession -> (Tmux.SessionRef, Tmux.WindowRef, Tmux.PaneRef, Tmux.WindowIndex, Integer)
targets created = (created.session, created.window, created.pane, created.windowIndex, created.serverPid)
