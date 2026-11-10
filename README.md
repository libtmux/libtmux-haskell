<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="docs/assets/logo.svg" type="image/svg+xml">
    <img src="docs/assets/logo-128.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux for Haskell

Haskell tmux client library with detached observations, typed identities
and explicit `IO`. Capture once, then use ordinary records and collections.

[![CI](https://github.com/libtmux/libtmux-haskell/actions/workflows/ci.yml/badge.svg)](https://github.com/libtmux/libtmux-haskell/actions/workflows/ci.yml)

</div>

Use a current GHC and Cabal that satisfy the [package bounds](libtmux-haskell.cabal).
[Toolchain pins](.tool-versions) record the reproducible CI setup.
Native operations require the [Linux host capabilities](docs/installation.md#native-backend-host-requirements).
The tmux support range is 3.3a through 3.8 inclusive; CI tests the endpoints.
[Add the source dependency](docs/installation.md) to a Cabal application,
or run the example from a provisioned checkout.

Create a private demonstration server:

```console
$ export LIBTMUX_DEMO_DIR="$(mktemp -d -t libtmux-haskell-demo.XXXXXX)"
```

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_DEMO_DIR/s" \
    -f /dev/null \
    new-session \
    -d \
    -s demo \
    -n editor \
    -x 120 \
    -y 40 \
    /bin/cat -
```

Link its window at a second index to demonstrate physical and contextual identity:

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -N \
    -S "$LIBTMUX_DEMO_DIR/s" \
    link-window \
    -s demo:0 \
    -t demo:4
```

Run the Haskell executable through Cabal:

```console
$ cabal run --verbose=0 capture-graph -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

The complete program accepts an existing socket and tmux executable:

<!-- example: capture-graph -->
```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Capture once, then navigate detached values after the Server scope closes.
module Main (main) where

import Control.Monad (forM_)
import Data.List (intercalate)
import Data.Text qualified as Text
import LibTmux qualified as Tmux
import System.Environment (getArgs)
import System.Exit (die)
import System.OsPath.Posix qualified as Path

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    [socketArgument, executableArgument] -> do
      socket <- Path.encodeFS socketArgument
      executable <- Path.encodeFS executableArgument
      let config = (Tmux.serverConfig socket) {Tmux.executable = executable}
      snapshot <- Tmux.withServer config Tmux.capture

      let activeWidePanes =
            [ pane
            | pane <- Tmux.panes snapshot
            , pane.active
            , Tmux.dimensionValue pane.width >= 120
            ]
      putStrLn $ "physical entities (sessions, windows, panes): " <> show
        (length (Tmux.sessions snapshot), length (Tmux.windows snapshot), length (Tmux.panes snapshot))
      putStrLn $ "contextual appearances (links, panes): " <> show
        (length (Tmux.windowLinks snapshot), length (Tmux.paneOccurrences snapshot))
      putStrLn $ "active panes at least 120 cells wide: " <> show (length activeWidePanes)

      forM_ (Tmux.sessions snapshot) $ \session -> do
        links <- either (fail . show) pure (Tmux.linksForSession snapshot session.ref)
        forM_ links $ \link -> do
          window <- either (fail . show) pure (Tmux.lookupWindow snapshot link.window)
          children <- either (fail . show) pure (Tmux.panesForWindow snapshot window.ref)
          let paneIds = [Text.unpack (Tmux.renderPaneId (Tmux.paneId pane.ref)) | pane <- children]
          putStrLn $ Text.unpack session.name <> ":" <> show (Tmux.windowIndexValue link.index)
            <> " -> " <> Text.unpack (Tmux.renderWindowId (Tmux.windowId window.ref))
            <> " panes=" <> intercalate "," paneIds
    _ -> die "Usage: capture-graph SOCKET TMUX_EXECUTABLE"
```

Program output:

<!-- example-output: capture-graph -->
```text
physical entities (sessions, windows, panes): (1,1,1)
contextual appearances (links, panes): (2,2)
active panes at least 120 cells wide: 1
demo:0 -> @0 panes=%0
demo:4 -> @0 panes=%0
```

[`withServer`](src/LibTmux/Server.hs) scopes the connection resources;
[`capture`](src/LibTmux/Server.hs) reads and validates the complete baseline
graph. Every list comprehension and relationship lookup above uses detached
values after the scope has closed. Closing the handle leaves the daemon running.
Operational exceptions retain their recovery context; see [capture and recovery](docs/capture.md).
For independent handle lifetimes under one resource budget, use the tested
[shared Runtime program](docs/shared-runtime.md).

Stop the demonstration server and remove only its temporary directory:

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -N \
    -S "$LIBTMUX_DEMO_DIR/s" \
    kill-server
```

```console
$ rm -r -- "$LIBTMUX_DEMO_DIR"
```

| Task | Start here |
| --- | --- |
| Install in an application | [Cabal source dependency](docs/installation.md) |
| Capture, filter and navigate linked windows | [Observations and recovery](docs/capture.md) |
| Compose typed predicates, traverse relations and require one match | [Typed queries](docs/query.md) |
| Share ownership across independent Server scopes | [Shared Runtime](docs/shared-runtime.md) |
| Understand IDs, indices and validation errors | [Typed values](docs/values.md) |
| Test graph predicates without tmux | [Validated offline fixtures](docs/fixtures.md) |
| Reproduce capture measurements | [Performance](docs/performance.md) |
| Browse declarations and module documentation | [API guide](docs/api.md) |
| Evaluate the implemented scope and compatibility evidence | [Status](docs/status.md) |

The package is unpublished. Observation, recovery and typed local queries are
implemented. Mutation commands, event streams and the workspace library/CLI
remain under development. MCP is excluded. Native operations require Linux x86_64,
glibc 2.39+ and compatible pidfd support; [installation](docs/installation.md)
describes the host contract. The [manual](docs/README.md) and
[status](docs/status.md) distinguish available behavior from planned work.

[Contributing](.github/CONTRIBUTING.md) · [License](LICENSE) · [Branding assets](docs/branding.md)
