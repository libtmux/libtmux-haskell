{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Test a pane-selection policy without starting tmux or opening a socket.
module Main (main) where

import Data.Bifunctor (first)
import LibTmux qualified as Tmux
import LibTmux.Snapshot.Fixture qualified as F
import System.Exit (die)
import System.OsString.Posix qualified as Os

main :: IO ()
main = do
  snapshot <- either die pure buildSnapshot
  print (Tmux.snapshotOrigin snapshot)
  print
    [ (Tmux.renderPaneId (Tmux.paneId pane.ref), Tmux.dimensionValue pane.width)
    | pane <- Tmux.panes snapshot
    , pane.active
    , Tmux.dimensionValue pane.width >= 120
    ]
  print (length (Tmux.windows snapshot), length (Tmux.paneOccurrences snapshot))

buildSnapshot :: Either String Tmux.Snapshot
buildSnapshot = do
  version <- checked (Tmux.parseVersion "3.8")
  sid <- checked (Tmux.parseSessionId "$1")
  wid <- checked (Tmux.parseWindowId "@2")
  pid <- checked (Tmux.parsePaneId "%3")
  width <- checked (Tmux.mkDimension 120)
  height <- checked (Tmux.mkDimension 40)
  paneIndex <- checked (Tmux.mkPaneIndex 0)
  firstIndex <- checked (Tmux.mkWindowIndex 0)
  secondIndex <- checked (Tmux.mkWindowIndex 4)
  let origin = F.fixtureOrigin "reports"
      session = Tmux.Session (F.sessionRef origin sid) "work" 0
      window = Tmux.Window (F.windowRef origin wid) "editor" width height
      pane = Tmux.Pane
        { Tmux.ref = F.paneRef origin pid
        , Tmux.window = window.ref
        , Tmux.index = paneIndex
        , Tmux.width = width
        , Tmux.height = height
        , Tmux.active = True
        , Tmux.dead = False
        , Tmux.title = "editor"
        , Tmux.currentCommand = Os.fromBytestring "ghci"
        , Tmux.currentPath = Os.fromBytestring "/offline/project"
        }
      input = (F.emptyFixture origin version)
        { F.sessions = [session], F.windows = [window], F.panes = [pane]
        , F.windowLinks = [Tmux.WindowLink session.ref firstIndex window.ref True,
                          Tmux.WindowLink session.ref secondIndex window.ref False]
        }
  checked (F.validateFixture origin input)

checked :: Show problem => Either problem value -> Either String value
checked = first show
