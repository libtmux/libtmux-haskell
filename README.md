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
[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/haskell/)
[![license](https://img.shields.io/badge/license-MIT-blue)](https://github.com/libtmux/libtmux-haskell/blob/master/LICENSE)

[Documentation](https://libtmux.org/en/haskell/) ·
[API reference](https://libtmux.org/en/haskell/latest/reference/) ·
[Examples](https://libtmux.org/en/haskell/latest/examples/)

</div>

## Install

Not on Hackage yet. Add the library to your `.cabal` dependencies:

```cabal
build-depends: libtmux-haskell ^>=0.0.1.0
```

Point Cabal at the Git source in `cabal.project`:

```cabal
source-repository-package
  type: git
  location: https://github.com/libtmux/libtmux-haskell
  tag: v0.0.1.0
```

Update the package index:

```console
$ cabal update
```

Needs a current GHC and Cabal, Linux and tmux 3.3a or newer.
More: [installation](https://libtmux.org/en/haskell/latest/guides/installation/) ·
[host requirements](docs/installation.md#native-backend-host-requirements).

## Read a tmux graph

### [`capture`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-capture/): the whole graph in one read

[`withServer`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-withserver/) scopes the
connection. Run this from a checkout.

Start a demo server on a private socket:

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

Link its window at a second index:

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -N \
    -S "$LIBTMUX_DEMO_DIR/s" \
    link-window \
    -s demo:0 \
    -t demo:4
```

Run the example:

```console
$ cabal run --verbose=0 capture-graph -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

The complete program:

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

It prints:

<!-- example-output: capture-graph -->
```text
physical entities (sessions, windows, panes): (1,1,1)
contextual appearances (links, panes): (2,2)
active panes at least 120 cells wide: 1
demo:0 -> @0 panes=%0
demo:4 -> @0 panes=%0
```

The values stay usable after the scope closes. Closing the handle leaves the
daemon running. More: [capture and recovery](https://libtmux.org/en/haskell/latest/guides/capture/) ·
[`withRuntime`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-withruntime/) for
[shared lifetimes](https://libtmux.org/en/haskell/latest/guides/shared-runtime/).

## Change tmux

### [`renameSession`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-renamesession/): rename what a query found

[`exactlyOne`](https://libtmux.org/en/haskell/latest/reference/libtmux-query-v-exactlyone/) insists on a single
match first. [`renameWindow`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-renamewindow/)
and [`setPaneTitle`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-setpanetitle/) follow.
The [mutation program](https://libtmux.org/en/haskell/latest/guides/mutations/):

```console
$ cabal run --verbose=0 mutate-graph -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

A new capture shows the changes; the old snapshot keeps its values. Each
rename is its own command, and a later failure undoes nothing.

## Clean up

Stop the demo server and remove its directory:

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -N \
    -S "$LIBTMUX_DEMO_DIR/s" \
    kill-server
```

```console
$ rm -r -- "$LIBTMUX_DEMO_DIR"
```

## Find the right guide

| Task | Start here |
| --- | --- |
| Install in an application | [Cabal installation](https://libtmux.org/en/haskell/latest/guides/installation/) |
| Capture, filter and navigate linked windows | [Observations and recovery](https://libtmux.org/en/haskell/latest/guides/capture/) |
| Compose typed predicates, traverse relations and require one match | [Typed queries](https://libtmux.org/en/haskell/latest/guides/query/) |
| Rename sessions/windows, set pane titles and recover interrupted commands | [Mutations](https://libtmux.org/en/haskell/latest/guides/mutations/) |
| Share ownership across independent Server scopes | [Shared Runtime](https://libtmux.org/en/haskell/latest/guides/shared-runtime/) |
| Understand IDs, indices and validation errors | [Typed values](https://libtmux.org/en/haskell/latest/guides/typed-values/) |
| Test graph predicates without tmux | [Validated offline fixtures](https://libtmux.org/en/haskell/latest/guides/offline-fixtures/) |
| Reproduce capture measurements | [Performance](https://libtmux.org/en/haskell/latest/guides/performance/) |
| Browse connection and mutation operations | [`LibTmux.Server`](https://libtmux.org/en/haskell/latest/reference/libtmux-server/) |
| Browse declarations and module documentation | [API reference](https://libtmux.org/en/haskell/latest/reference/) |
| See what works today and what is planned | [Status](https://libtmux.org/en/haskell/latest/guides/status/) |

## Support and status

- **Experimental.** The API may change.
- **Works today.** Captures, typed queries, renames and pane titles.
- **In development.** Creating sessions, pane input and event streams.
- **Platform.** Linux x86_64. [Host requirements](docs/installation.md).
- **More.** [Status](https://libtmux.org/en/haskell/latest/guides/status/) · [source guides](docs/README.md).

[Contributing](.github/CONTRIBUTING.md) · [License](LICENSE) · [Branding assets](docs/branding.md)
