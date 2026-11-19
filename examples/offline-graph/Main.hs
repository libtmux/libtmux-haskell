{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Test a pane-selection policy without starting tmux or opening a socket.
module Main (main) where

import Data.Bifunctor (first)
import LibTmux qualified as Tmux
import LibTmux.Query qualified as Q
import LibTmux.Query.Client qualified as Client
import LibTmux.Query.Link qualified as Link
import LibTmux.Query.Pane qualified as Pane
import LibTmux.Query.Session qualified as Session
import LibTmux.Query.Window qualified as Window
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
  metadata <- either die pure (metadataMatches snapshot)
  putStrLn ("metadata matches: " <> show metadata)

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
      session = Tmux.Session (F.sessionRef origin sid) "work" 1 (Just "team")
      window = Tmux.Window (F.windowRef origin wid) "editor" width height "offline-layout" False
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
        , Tmux.cursorX = 0
        , Tmux.cursorY = 0
        , Tmux.modeCount = 0
        , Tmux.mode = Nothing
        }
      input = (F.emptyFixture origin version)
        { F.sessions = [session], F.windows = [window], F.panes = [pane]
        , F.windowLinks = [Tmux.WindowLink session.ref firstIndex window.ref True "*",
                          Tmux.WindowLink session.ref secondIndex window.ref False ""]
        , F.clients = [F.AttachedClient (Os.fromBytestring "terminal") 7
            (Just (Os.fromBytestring "/dev/fixture")) sid wid firstIndex pid 120 (Just 40)]
        }
  checked (F.validateFixture origin input)

-- Select native metadata through the same typed fields used for live captures.
metadataMatches :: Tmux.Snapshot -> Either String [Int]
metadataMatches snapshot = sequence
  [ count (Q.matching (Q.eq Session.group (Just "team")) Q.sessions)
  , count (Q.matching (Q.allOf [Q.eq Window.layout "offline-layout", Q.eq Window.zoomed False]) Q.windows)
  , count (Q.matching (Q.eq Link.flags "*") Q.windowLinks)
  , count (Q.matching (Q.allOf [Q.eq Pane.cursorX 0, Q.eq Pane.cursorY 0,
      Q.eq Pane.modeCount 0, Q.eq Pane.mode Nothing]) Q.panes)
  , count (Q.matching (Q.allOf [Q.eq Client.width 120, Q.eq Client.height (Just 40)]) Q.clients)
  ]
  where
    count :: Q.Query row -> Either String Int
    count query = length <$> checked (Q.runQuery snapshot query)

checked :: Show problem => Either problem value -> Either String value
checked = first show
