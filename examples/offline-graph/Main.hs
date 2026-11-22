{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Test a pane-selection policy without starting tmux or opening a socket.
module Main (main) where

import Data.Bifunctor (first)
import LibTmux qualified as Tmux
import LibTmux.Query qualified as Q
import LibTmux.Query.Fields qualified as F
import LibTmux.Snapshot.Fixture qualified as Fixture
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
  let origin = Fixture.fixtureOrigin "reports"
      session =
        Tmux.Session (Fixture.sessionRef origin sid) "work" 1 (Just "team")
      window = Tmux.Window
        (Fixture.windowRef origin wid)
        "editor"
        width
        height
        "offline-layout"
        False
      pane = Tmux.Pane
        { Tmux.ref = Fixture.paneRef origin pid
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
      input = (Fixture.emptyFixture origin version)
        { Fixture.sessions = [session]
        , Fixture.windows = [window]
        , Fixture.panes = [pane]
        , Fixture.windowLinks =
            [ Tmux.WindowLink session.ref firstIndex window.ref True "*"
            , Tmux.WindowLink session.ref secondIndex window.ref False ""
            ]
        , Fixture.clients =
            [ Fixture.AttachedClient
                (Os.fromBytestring "terminal")
                7
                (Just (Os.fromBytestring "/dev/fixture"))
                sid
                wid
                firstIndex
                pid
                120
                (Just 40)
            ]
        }
  checked (Fixture.validateFixture origin input)

-- Select native metadata through the same typed fields used for live captures.
metadataMatches :: Tmux.Snapshot -> Either String [Int]
metadataMatches snapshot = sequence
  [ count (Q.matching (Q.eq F.sessionGroup (Just "team")) Q.sessions)
  , count
      (Q.matching
        (Q.allOf
          [Q.eq F.windowLayout "offline-layout", Q.eq F.windowZoomed False])
        Q.windows)
  , count (Q.matching (Q.eq F.linkFlags "*") Q.windowLinks)
  , count (Q.matching (Q.allOf [Q.eq F.paneCursorX 0, Q.eq F.paneCursorY 0,
      Q.eq F.paneModeCount 0, Q.eq F.paneMode Nothing]) Q.panes)
  , count
      (Q.matching
        (Q.allOf [Q.eq F.clientWidth 120, Q.eq F.clientHeight (Just 40)])
        Q.clients)
  ]
  where
    count :: Q.Query row -> Either String Int
    count query = length <$> checked (Q.runQuery snapshot query)

checked :: Show problem => Either problem value -> Either String value
checked = first show
