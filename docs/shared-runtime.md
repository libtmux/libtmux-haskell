# Share a Runtime across independent Server scopes

[`withRuntime`](../src/LibTmux/Server.hs) gives several components one
resource and cleanup owner. Open each endpoint with
[`withServerIn`](../src/LibTmux/Server.hs). Closing one Server scope releases
only that handle; the others keep working under the shared limits.

Start the [demo server](../README.md) from the README, then run from a
checkout:

```console
$ cabal run --verbose=0 shared-runtime -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

<!-- example: shared-runtime -->
```haskell
{-# LANGUAGE OverloadedRecordDot #-}

-- | Share Runtime resources while keeping Server lifetimes independent.
module Main (main) where

import Control.Exception (ExceptionWithContext (..))
import Control.Monad (forM_, unless)
import Data.Text qualified as Text
import LibTmux qualified as Tmux
import System.Environment (getArgs)
import System.Exit (die)
import System.OsPath.Posix qualified as Path

main :: IO ()
main = getArgs >>= \case
  [socketArgument, executableArgument] -> do
    socket <- Path.encodeFS socketArgument
    executable <- Path.encodeFS executableArgument
    let config = (Tmux.serverConfig socket) {Tmux.executable = executable}
    snapshot <- Tmux.withRuntime $ \runtime ->
      Tmux.withServerIn runtime config $ \outer -> do
        first <- Tmux.capture outer
        closed <- Tmux.withServerIn runtime config $ \inner -> do
          unless (Tmux.serverGeneration inner /= Tmux.serverGeneration outer) $
            fail "independent handles shared a connection generation"
          captured <- Tmux.capture inner
          case Tmux.panes captured of
            pane : _ -> unless (Tmux.lookupPane first pane.ref == Left Tmux.ForeignGeneration) $
              fail "a reference crossed independent handle generations"
            [] -> fail "the owned example fixture has no pane"
          pure inner
        Tmux.tryTmux (Tmux.capture closed) >>= \case
          Left (ExceptionWithContext _ Tmux.ServerClosed) -> pure ()
          Left problem -> fail ("closed handle returned an unexpected error: " <> show problem)
          Right _ -> fail "the inner handle remained open after its scope"
        Tmux.capture outer
    putStrLn "independent handles: verified"
    putStrLn "closed inner handle: rejected"
    putStrLn $ "outer capture panes: " <> show (length (Tmux.panes snapshot))
    forM_ (Tmux.panes snapshot) $ \pane -> do
      window <- either (fail . show) pure (Tmux.lookupWindow snapshot pane.window)
      putStrLn $ "detached pane " <> Text.unpack (Tmux.renderPaneId (Tmux.paneId pane.ref))
        <> " belongs to " <> Text.unpack (Tmux.renderWindowId (Tmux.windowId window.ref))
  _ -> die "Usage: shared-runtime SOCKET TMUX_EXECUTABLE"
```

The program checks that:

- References stay connection-scoped.
- The inner handle closes.
- The outer handle still captures.
- Detached navigation works after the whole Runtime closes.

<!-- example-output: shared-runtime -->
```text
independent handles: verified
closed inner handle: rejected
outer capture panes: 1
detached pane %0 belongs to @0
```

## Use the installed package

To build the program on its own, use this project, which pins the release that
provides the shared Runtime API, and its package file:

<!-- example-project: shared-runtime -->
```cabal
packages: .
index-state: 2026-11-06T00:00:00Z

source-repository-package
  type: git
  location: https://github.com/libtmux/libtmux-haskell
  tag: v0.0.1.0
```

<!-- example-package: shared-runtime -->
```cabal
cabal-version: 3.18
name: libtmux-shared-runtime
version: 0.0.0
build-type: Simple
license: MIT
extra-doc-files: README.md

executable shared-runtime
  main-is: Main.hs
  default-language: GHC2024
  ghc-options: -Wall -Werror
  build-depends:
    base >=4.22 && <4.23,
    filepath >=1.5.4 && <1.6,
    libtmux-haskell ^>=0.0.1.0,
    text >=2.1.3 && <2.2
```

[Installation](installation.md) covers the compiler and host setup.

## Scope and recovery

- Every adoption has its own generation, even for the same daemon. A reference
  from one handle does not target another handle's observations.
- Closing the Runtime also closes handles that application tasks still hold.
  You own your worker lifetimes.
- Adopting after the Runtime closes raises `RuntimeClosed`.
- Closing either kind of scope leaves the tmux daemon running.

Limits belong to the Runtime:

- It admits one complete capture at a time. A concurrent attempt can fail with
  an operational capacity error.
- Capture sequentially, or use separate Runtimes for separate capacity. See
  [performance](performance.md) for the measured workload.

Recovery:

- Catch with [`tryTmux`](../src/LibTmux/Server.hs) to keep the exception
  context. `cleanupRecoveries` returns the remaining cleanup owners.
- Inspect, retry, wait and detach act on the one responsibility you select.
- A failed adoption can hold an owner before it returns a Server. Recovering it
  does not close neighboring handles.
- Nested scopes can contribute overlapping owners. Inspect and resume each.
- An explicit cleanup wait has no deadline. Cancelling it keeps the owner.
- Detaching releases no native resource and proves no daemon-side completion.

More: [capture recovery](capture.md#errors-and-recovery) and the
[process contract](contracts/process.md#public-scope-outcomes) for the error and
cancellation policy.
