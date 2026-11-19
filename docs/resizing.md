# Resize panes and windows

[`resizePane` and `resizeWindow`](../src/LibTmux/Server.hs) request absolute
geometry for a captured physical reference. Choose a width, a height, or both
with [`Resize`](../src/LibTmux/Value.hs), then capture again for actual cells.
A successful command can leave dimensions clamped by native layout constraints.

Start the [README's private demonstration server](../README.md), then run
from a [provisioned checkout](../.github/CONTRIBUTING.md#toolchain):

```console
$ cabal run --verbose=0 resize-geometry -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

The program creates three panes in its own session. It changes one pane and
then its window, refuses an invalid request, checks the original windows and
removes its session. Follow the [README's teardown](../README.md#clean-up)
for the borrowed demonstration server.

<!-- example: resize-geometry -->
```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Request absolute geometry and observe the resulting cells.
module Main (main) where

import Control.Exception (ExceptionWithContext (..), bracket, rethrowIO)
import Control.Monad (forM_)
import Data.List.NonEmpty (NonEmpty (..))
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
    columns <- dimension 120
    rows <- dimension 60
    side <- dimension 30
    lower <- dimension 20
    paneWidth <- dimension 50
    paneHeight <- dimension 10
    windowWidth <- dimension 100
    windowHeight <- dimension 40
    finalWidth <- dimension 80
    oversized <- dimension 10001
    let config = (Tmux.serverConfig socket) {Tmux.executable = executable}
        process = Creation.DirectCommand (Os.fromBytestring "/bin/cat") (Os.fromBytestring "-" :| [])
        options = Creation.defaultSessionOptions
          {Creation.width = Just columns, Creation.height = Just rows, Creation.process = process}
    result <- Tmux.tryTmux $ Tmux.withServer config $ \server -> do
      before <- Tmux.capture server
      bracket (Tmux.createSession server options) (Tmux.killSession server . (.session)) $ \created -> do
        let slot = Creation.WindowSlot created.session created.windowIndex
        _ <- Tmux.splitPane server slot created.pane Creation.defaultSplitOptions
          {Creation.direction = Creation.LeftRight, Creation.size = Creation.SplitCells side,
            Creation.splitProcess = process}
        _ <- Tmux.splitPane server slot created.pane Creation.defaultSplitOptions
          {Creation.size = Creation.SplitCells lower, Creation.splitProcess = process}
        forM_ [("pane width", Tmux.ResizeWidth paneWidth), ("pane height", Tmux.ResizeHeight paneHeight),
               ("pane both", Tmux.ResizeBoth paneWidth lower)] $ \(label, size) -> do
          Tmux.resizePane server created.pane size
          fresh <- Tmux.capture server
          pane <- require (Tmux.lookupPane fresh created.pane)
          putStrLn $ label <> ": " <> show (Tmux.dimensionValue pane.width, Tmux.dimensionValue pane.height)
        forM_ [("window width", Tmux.ResizeWidth windowWidth), ("window height", Tmux.ResizeHeight windowHeight),
               ("window both", Tmux.ResizeBoth finalWidth side)] $ \(label, size) -> do
          Tmux.resizeWindow server created.window size
          fresh <- Tmux.capture server
          window <- require (Tmux.lookupWindow fresh created.window)
          putStrLn $ label <> ": " <> show (Tmux.dimensionValue window.width, Tmux.dimensionValue window.height)
        invalid <- Tmux.tryTmux (Tmux.resizePane server created.pane (Tmux.ResizeBoth paneWidth oversized))
        refused <- case invalid of
          Left (ExceptionWithContext _ (Tmux.InvalidMutationArgument (Tmux.InvalidOperand "pane.height" _))) ->
            pure True
          Left problem -> rethrowIO problem
          Right () -> die "Oversized resize unexpectedly succeeded"
        after <- Tmux.capture server
        let preserved old = case Tmux.lookupWindow after old.ref of
              Right current -> (current.width, current.height) == (old.width, old.height)
              Left _ -> False
        putStrLn $ "invalid size refused: " <> show refused
        putStrLn $ "bystander preserved: " <> show (all preserved (Tmux.windows before))
      remaining <- Tmux.capture server
      putStrLn $ "original sessions after cleanup: " <>
        show (map (.ref) (Tmux.sessions remaining) == map (.ref) (Tmux.sessions before))
    either rethrowIO pure result
  _ -> die "Usage: resize-geometry SOCKET TMUX_EXECUTABLE"

dimension :: Integer -> IO Tmux.Dimension
dimension = require . Tmux.mkDimension

require :: Show problem => Either problem a -> IO a
require = either (die . show) pure
```

It prints:

<!-- example-output: resize-geometry -->
```text
pane width: (50,39)
pane height: (50,10)
pane both: (50,20)
window width: (100,60)
window height: (100,40)
window both: (80,30)
invalid size refused: True
bystander preserved: True
original sessions after cleanup: True
```

## Choose and validate dimensions

`ResizeWidth width` retains the native height; `ResizeHeight height` retains
the native width. `ResizeBoth width height` supplies both axes. Every request
contains at least one [`Dimension`](../src/LibTmux/Value.hs).
[`mkDimension`](../src/LibTmux/Value.hs) rejects zero and negative values.
The resize operations additionally require every axis to be at most 10000
cells, the shared bound for tmux 3.3a and 3.8.

Validation checks the whole request before admitting a mutation. An oversized
second axis cannot unzoom the window or leave the first axis resized.
`InvalidMutationArgument` contains the invalid field, and no operation is
retained. A positive `Dimension` alone does not establish a command's upper
bound.

## Observe native layout effects

`resizePane` targets the exact `PaneRef`, including an inactive pane. Native
resizing can change neighboring panes or unzoom the containing window.
The requested size can clamp or leave the layout unchanged. It does not
select the target pane.

`resizeWindow` targets one physical `WindowRef` across all its links and sets
its `window-size` option to `manual`. Absolute sizing needs no active link or
client selection. Layout constraints determine the resulting cells.
Both operations return `IO ()`; use a new [`capture`](../src/LibTmux/Server.hs)
to read geometry. Earlier snapshots retain their old values.

## Handle errors and interruption

The default operations use [`defaultMutationOptions`](../src/LibTmux/Server.hs).
`resizePaneWith` and `resizeWindowWith` accept an explicit deadline.
Generation checks refuse foreign references; a missing native target raises
`MutationRejected`. A failing after-hook can report
`MutationAppliedWithErrors` after the primary resize has happened.

Keep exception context when catching failures. Cancellation preserves its
exception class and correlated [`MutationRecovery`](../src/LibTmux/Server.hs).
An uncertain outcome does not trigger an automatic retry. See
[mutation recovery](mutations.md#known-and-uncertain-outcomes).

Absolute width and height are implemented. Directional adjustments, pane
percentages, largest/smallest-client fitting, zoom toggles, history trimming,
mouse actions and floating-specific modes remain separate work in the
[pane and window contract](https://github.com/libtmux/libtmux-haskell/blob/master/docs/contracts/pane-commands.md).
