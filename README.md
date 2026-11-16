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
  tag: ad190fe73c9d09a553c3c160ecf0b6394b7621a6
```

Update the package index:

```console
$ cabal update
```

Needs a current GHC and Cabal, Linux and tmux 3.3a or newer.
More: [installation](https://libtmux.org/en/haskell/latest/guides/installation/) ·
[host requirements](docs/installation.md#native-backend-host-requirements).

## Start and stop a server

### [`withOwnedServer`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-withownedserver/): a private server for one scope

The library starts a tmux daemon on a socket of its own and stops it when the
scope closes. It needs tmux 3.3a or newer on `PATH`:

```console
$ cabal run --verbose=0 owned-server
```

The complete program:

<!-- example: owned-server -->
```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Start a private tmux server, create a session in it, and stop the server.
module Main (main) where

import Control.Exception (ExceptionWithContext (..))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation
import System.Exit (die)
import System.OsString.Posix qualified as Os

main :: IO ()
main = do
  let options = Creation.defaultSessionOptions
        { Creation.name = Just "owned-workspace"
        , Creation.process = Creation.DirectCommand (Os.fromBytestring "/bin/cat") (Os.fromBytestring "-" :| [])
        }
  (server, created, snapshot) <- Tmux.withOwnedServer Tmux.defaultOwnedServerConfig $ \server -> do
    created <- Tmux.createSession server options
    snapshot <- Tmux.capture server
    pure (server, created, snapshot)
  session <- either (die . show) pure (Tmux.lookupSession snapshot created.session)
  putStrLn $ "created session: " <> Text.unpack session.name
  putStrLn $ "sessions in the owned server: " <> show (length (Tmux.sessions snapshot))
  putStrLn $ "creation and capture name one daemon: " <> show (created.serverPid == (Tmux.serverInfo snapshot).pid)
  closed <- Tmux.tryTmux (Tmux.capture server)
  case closed of
    Left (ExceptionWithContext _ Tmux.ServerClosed) -> putStrLn "server closed after the scope: True"
    _ -> die "A retained Server still accepted a capture"
```

It prints:

<!-- example-output: owned-server -->
```text
created session: owned-workspace
sessions in the owned server: 1
creation and capture name one daemon: True
server closed after the scope: True
```

[`killServer`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-killserver/)
retires a daemon you adopted instead; `withServer` alone never stops one.
More: [lifecycle](https://libtmux.org/en/haskell/latest/guides/lifecycle/).

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
daemon running.

More: [capture and recovery](https://libtmux.org/en/haskell/latest/guides/capture/) ·
[`withRuntime`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-withruntime/) for
[shared lifetimes](https://libtmux.org/en/haskell/latest/guides/shared-runtime/).

## Find sessions, windows and panes

### [`runQuery`](https://libtmux.org/en/haskell/latest/reference/libtmux-query-v-runquery/): typed predicates over a capture

[`matching`](https://libtmux.org/en/haskell/latest/reference/libtmux-query-v-matching/) filters a source,
[`exactlyOne`](https://libtmux.org/en/haskell/latest/reference/libtmux-query-v-exactlyone/) insists on a single
match and [`fetch`](https://libtmux.org/en/haskell/latest/reference/libtmux-query-v-fetch/) captures fresh. Run it
against the same demo server:

```console
$ cabal run --verbose=0 query-graph -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

The complete program:

<!-- example: query-graph -->
```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Query one detached graph, then distinguish physical and contextual matches.
module Main (main) where

import Control.Exception (ExceptionWithContext, rethrowIO)
import Data.Bifunctor (first)
import Data.Function ((&))
import Data.Text qualified as Text
import LibTmux qualified as Tmux
import LibTmux.Query qualified as Q
import LibTmux.Query.Link qualified as Link
import LibTmux.Query.Occurrence qualified as Occurrence
import LibTmux.Query.Pane qualified as Pane
import LibTmux.Query.Session qualified as Session
import System.Environment (getArgs)
import System.Exit (die)
import System.OsPath.Posix qualified as Path

data ApplicationError
  = OperationalFailure (ExceptionWithContext Tmux.TmuxException)
  | InvalidQuery Q.QueryError
  | InvalidSelection Q.CardinalityError
  | UnexpectedResult String

activeWide :: Q.Expr Tmux.Pane
activeWide = Q.allOf [Q.eq Pane.active True, Q.dimensionAtLeast Pane.width 120]

selectedPanes :: Q.Query Tmux.Pane
selectedPanes = Q.panes & Q.matching activeWide

main :: IO ()
main = getArgs >>= \case
  [socketArgument, executableArgument] -> do
    socket <- Path.encodeFS socketArgument
    executable <- Path.encodeFS executableArgument
    let config = (Tmux.serverConfig socket) {Tmux.executable = executable}
    acquired <- Tmux.tryTmux $ Tmux.withServer config $ \server -> do
      snapshot <- Tmux.capture server
      fresh <- Q.fetch server selectedPanes
      pure (snapshot, fresh)
    case first OperationalFailure acquired >>= uncurry report of
      Left (OperationalFailure problem) -> rethrowIO problem
      Left (InvalidQuery problem) -> die ("Query validation failed: " <> show problem)
      Left (InvalidSelection problem) -> die ("Selection failed: " <> show problem)
      Left (UnexpectedResult problem) -> die problem
      Right linesToPrint -> mapM_ putStrLn linesToPrint
  _ -> die "Usage: query-graph SOCKET TMUX_EXECUTABLE"

report :: Tmux.Snapshot -> Either Q.QueryError [Tmux.Pane] -> Either ApplicationError [String]
report snapshot acquired = do
  selected <- first InvalidQuery (Q.runQuery snapshot selectedPanes)
  let native = [pane | pane <- Tmux.panes snapshot, pane.active, Tmux.dimensionValue pane.width >= 120]
  if selected == native then Right () else Left (UnexpectedResult "query and native selection disagree")
  unique <- first InvalidSelection (Q.exactlyOne selected)
  occurrences <- first InvalidQuery $ Q.runQuery snapshot $
    Q.paneOccurrences & Q.matching (Q.related Occurrence.pane activeWide)
  highest <- first InvalidQuery $ Q.runQuery snapshot $
    Q.windowLinks & Q.orderBy [Q.descending Link.index] & Q.limit 1
  link <- first InvalidSelection (Q.exactlyOne highest)
  let containingEditors = Q.sessions & Q.matching (Q.some Session.windowLinks (Q.some Link.panes activeWide))
  sessions <- first InvalidQuery (Q.runQuery snapshot containingEditors)
  fresh <- first InvalidQuery acquired
  Right
    [ "query agrees with native predicate: True"
    , "unique physical pane: " <> Text.unpack (Tmux.renderPaneId (Tmux.paneId unique.ref))
    , "contextual matches: " <> show (length occurrences)
    , "contextual uniqueness: " <> either show (const "unique") (Q.exactlyOne occurrences)
    , "highest link index: " <> show (Tmux.windowIndexValue link.index)
    , "sessions containing a match: " <> show (length sessions)
    , "required fields: " <> show (Q.requirements selectedPanes).fieldNames
    , "required relationships: " <> show (Q.requirements containingEditors).relationshipNames
    , "fresh capture matches: " <> show (length fresh)
    ]
```

It prints:

<!-- example-output: query-graph -->
```text
query agrees with native predicate: True
unique physical pane: %0
contextual matches: 2
contextual uniqueness: AtLeastTwoMatches
highest link index: 4
sessions containing a match: 1
required fields: ["pane.active","pane.width"]
required relationships: ["session.windowLinks","windowLink.panes"]
fresh capture matches: 1
```

One physical pane appears twice through its window links, so it matches twice
in the contextual source. More: [typed queries](https://libtmux.org/en/haskell/latest/guides/query/).

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

## Create a session

### [`createSession`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-createsession/): create and use its targets

The [creation program](https://libtmux.org/en/haskell/latest/guides/creation/)
uses the returned window and pane, then captures the updated graph:

```console
$ cabal run --verbose=0 create-session -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

It also checks duplicate-name rejection. The new session stays running until
the demo server is stopped. More: [creation and recovery](docs/creation.md).

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
| Start a private server, or retire an adopted daemon | [Lifecycle](https://libtmux.org/en/haskell/latest/guides/lifecycle/) |
| Capture, filter and navigate linked windows | [Observations and recovery](https://libtmux.org/en/haskell/latest/guides/capture/) |
| Compose typed predicates, traverse relations and require one match | [Typed queries](https://libtmux.org/en/haskell/latest/guides/query/) |
| Create a session and recover its actual targets | [Session creation](https://libtmux.org/en/haskell/latest/guides/creation/) |
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
- **Works today.** Private server start and stop, captures, typed queries, session creation, renames and pane titles.
- **In development.** Window/pane creation, pane input and event streams.
- **Platform.** Linux x86_64. [Host requirements](docs/installation.md).
- **More.** [Status](https://libtmux.org/en/haskell/latest/guides/status/) · [source guides](docs/README.md).

[Contributing](.github/CONTRIBUTING.md) · [License](LICENSE) · [Branding assets](docs/branding.md)
