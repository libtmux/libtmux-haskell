module QueryFixture (snapshot, emptySnapshot) where

import Data.Bifunctor (first)
import LibTmux.Id qualified as Id
import LibTmux.Internal.Graph qualified as G
import LibTmux.Internal.TmuxText qualified as Label
import LibTmux.Value qualified as V
import LibTmux.Version qualified as Version
import System.OsString.Posix qualified as Os

snapshot :: Either String G.Snapshot
snapshot = do
  version <- checked (Version.parseVersion "3.8")
  let generation = G.FixtureGeneration "query-tests"
  sid0 <- checked (Id.parseSessionId "$0")
  sid1 <- checked (Id.parseSessionId "$1")
  wid0 <- checked (Id.parseWindowId "@0")
  wid1 <- checked (Id.parseWindowId "@1")
  pid0 <- checked (Id.parsePaneId "%0")
  pid1 <- checked (Id.parsePaneId "%1")
  pid2 <- checked (Id.parsePaneId "%2")
  width0 <- checked (V.mkDimension 120)
  width1 <- checked (V.mkDimension 80)
  width2 <- checked (V.mkDimension 160)
  outerWidth <- checked (V.mkDimension 201)
  height <- checked (V.mkDimension 40)
  pane0 <- checked (V.mkPaneIndex 0)
  pane1 <- checked (V.mkPaneIndex 1)
  index0 <- checked (V.mkWindowIndex 0)
  index2 <- checked (V.mkWindowIndex 2)
  index4 <- checked (V.mkWindowIndex 4)
  index7 <- checked (V.mkWindowIndex 7)
  let s0 = G.Session (G.SessionRef generation sid0) "work" 1
      s1 = G.Session (G.SessionRef generation sid1) "other" 0
      w0 = G.Window (G.WindowRef generation wid0) "work" outerWidth height
      w1 = G.Window (G.WindowRef generation wid1) (Label.fromBytes "bad\255") width2 height
      p0 = G.Pane (G.PaneRef generation pid0) w0.ref pane0 width0 height True False "caf\233"
        (Os.fromBytestring "cat") (Os.fromBytestring "/offline/project")
      p1 = G.Pane (G.PaneRef generation pid1) w0.ref pane1 width1 height False False "other"
        (Os.fromBytestring "ghci") (Os.fromBytestring "/offline/project")
      p2 = G.Pane (G.PaneRef generation pid2) w1.ref pane0 width2 height True False "cafe\769"
        (Os.fromBytestring "cat") (Os.fromBytestring "/offline/project")
      links = [G.WindowLink s0.ref index0 w0.ref True, G.WindowLink s0.ref index4 w0.ref False,
               G.WindowLink s0.ref index7 w1.ref False, G.WindowLink s1.ref index2 w1.ref True]
      info = G.ServerInfo generation 7 0 version (Os.fromBytestring "fixture:query")
      client = G.ClientInput (Os.fromBytestring "control") 11 Nothing sid0 wid0 index0 pid0
  graph <- checked (G.assembleEntityGraph generation [s0, s1] [w0, w1] [p0, p1, p2] links)
  checked (G.assembleSnapshot info graph [client])

emptySnapshot :: Either String G.Snapshot
emptySnapshot = do
  full <- snapshot
  let info = G.serverInfo full
  graph <- checked (G.assembleEntityGraph info.generation [] [] [] [])
  checked (G.assembleSnapshot info graph [])

checked :: Show problem => Either problem value -> Either String value
checked = first show
