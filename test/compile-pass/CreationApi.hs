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

window :: Tmux.Server -> Tmux.CreatedSession -> IO Tmux.CreatedWindow
window server created = Tmux.createWindow server (Creation.NextFree created.session)
  Creation.defaultWindowOptions

split :: Tmux.Server -> Tmux.CreatedWindow -> IO Tmux.CreatedPane
split server created = Tmux.splitPane server
  (Creation.WindowSlot created.session created.windowIndex) created.pane Creation.defaultSplitOptions

receipt :: Tmux.CreatedEntities -> Tmux.PaneRef
receipt created = created.pane
