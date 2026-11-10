# Test graph logic without tmux

Use [`LibTmux.Snapshot.Fixture`](../src/LibTmux/Snapshot/Fixture.hs) to build
ordinary observation records and validate their relationships. No fixture
operation starts tmux, opens a socket or allocates an operational Server.

The complete program below tests a pane-selection policy against one physical
window appearing at two session indices. Run it from a provisioned checkout:

```console
$ cabal run --verbose=0 offline-graph
```

For a separate Cabal application, copy [Main.hs](../examples/offline-graph/Main.hs)
and its [package file](../examples/offline-graph/libtmux-offline-graph.cabal).
Save the [pinned source project](../examples/offline-graph/cabal.project.vcs)
as `cabal.project`, provision its dependencies, then run the same command.

<!-- example: offline-graph -->
```haskell
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
```

Program output:

<!-- example-output: offline-graph -->
```text
DefinedOffline "reports"
[("%3",120)]
(1,2)
```

`fixtureOrigin` creates a named offline namespace. Reuse a name to model
successive observations in one test scenario; use different names for
independent scenarios. Fixture references never compare equal to references
from an adopted Server, even when their native IDs match.

`emptyFixture` supplies synthetic server metadata and empty collections.
Populate its ordinary records, then call `validateFixture`. It reuses graph
and metadata validation, including reference membership, duplicate slots,
active selections and attached-client context. A failed input returns
`FixtureError`; it never becomes an empty snapshot. Reading an edited record
alone does not validate the graph or update a previously built snapshot.
Wire decoding, tmux's field normalization and transport limits apply to live
acquisition. Synthetic values can exercise cases a live capture cannot produce.

`SnapshotOrigin` distinguishes `DefinedOffline` from `AcquiredFromTmux`.
Offline snapshots have no acquisition interval. Neither provenance nor an
opaque reference proves that a tmux target is currently alive.

The [installed consumer check](../scripts/check_sdist.py) compiles this source
against the archived public package and asserts its output. The Hspec cases
exercise namespace separation and invalid graphs without a daemon. See
[capture and recovery](capture.md) for observations acquired from tmux.
