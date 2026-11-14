# Share a Runtime across independent Server scopes

Use [`withRuntime`](../src/LibTmux/Server.hs) to give several components one
resource and cleanup owner. Open their endpoints with
[`withServerIn`](../src/LibTmux/Server.hs). Closing one Server scope releases
that handle while the others remain usable under the shared limits.

Create the [private demonstration server](../README.md) from the README, then
run this complete program from a provisioned checkout. CI also runs it from
an installed package, checks output and observes owned process cleanup:

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

The program checks that references remain connection-scoped, the inner handle
closes, the outer handle still captures, and detached navigation works after
the entire Runtime closes.

<!-- example-output: shared-runtime -->
```text
independent handles: verified
closed inner handle: rejected
outer capture panes: 1
detached pane %0 belongs to @0
```

## Use the installed package

The core remains unpublished. This example's project pins the source that
provides the shared Runtime API. Use that project when building the standalone
program, together with its package file:

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

[Installation](installation.md) covers the compiler and native host setup.
The [archive consumer check](../scripts/check_sdist.py) builds the program
outside the checkout and executes it with the same owned fixture.

## Scope and recovery

Each adoption has a distinct generation, including handles to the same daemon.
A reference from one handle does not target another handle's observations.
Closing the Runtime also closes handles still retained by application tasks;
applications own their worker lifetimes. Starting another adoption after the
Runtime closes raises `RuntimeClosed`. Closing either kind of scope leaves
the tmux daemon running.

Limits belong to the Runtime. The current complete-capture reservation admits
one complete capture at a time; concurrent attempts can fail with an
operational capacity error. Capture sequentially or use independent Runtime
scopes when separate capacity is required. The
[performance guide](performance.md) records the measured workload and the
broader qualification still outstanding.

Use [`tryTmux`](../src/LibTmux/Server.hs) to keep the failure's exception
context. `cleanupRecoveries` retrieves its remaining cleanup owners. Their
inspection, retry, explicit wait and logical detachment stay scoped to the
selected responsibility. A failed adoption can retain an owner before it
returns a Server; recovering it does not close neighboring handles.

Nested scopes may contribute overlapping recovery owners. Inspect and resume
each retained responsibility. An explicit cleanup wait has no deadline;
cancellation preserves its owner. Detaching logical uncertainty does not
release native resources or prove a daemon-side command completed.
[Capture recovery](capture.md#errors-and-recovery) and the
[process contract](contracts/process.md#public-scope-outcomes) define the error
and cancellation policy.
