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

Install from Git until the first Hackage release. Add the library to your
`.cabal` dependencies.

```cabal
build-depends: libtmux-haskell ^>=0.0.1.0
```

Point Cabal at the Git source in `cabal.project`:

```cabal
source-repository-package
  type: git
  location: https://github.com/libtmux/libtmux-haskell
  tag: 4f60b832f5303f9221251b199e86b5d928757943
```

Update the package index:

```console
$ cabal update
```

Requires Linux x86_64 with glibc 2.39 or newer, GHC 9.14, Cabal 3.18 or
newer, and tmux 3.3a or newer. The first example uses Linux 6.5 peer pidfds.
[Installation](https://libtmux.org/en/haskell/latest/guides/installation/) ·
[Host requirements](docs/installation.md#native-backend-host-requirements)

## Read a tmux graph

### [`capture`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-capture/): the whole graph in one read

[`withOwnedServer`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-withownedserver/)
starts a private daemon and retires it after the example. Run from a checkout.

```console
$ cabal run --verbose=0 capture-graph
```

<!-- example: capture-graph -->
```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (forM_)
import Data.Text qualified as Text
import LibTmux qualified as Tmux
import LibTmux.Creation qualified as Creation

main :: IO ()
main = do
  alias <- either (fail . show) pure (Tmux.mkWindowIndex 4)
  snapshot <- Tmux.withOwnedServer Tmux.defaultOwnedServerConfig $ \server -> do
    created <- Tmux.createSession server Creation.defaultSessionOptions
      { Creation.name = Just "demo"
      , Creation.process = Creation.ShellCommand "exec /bin/cat -"
      }
    Tmux.linkWindow server (Creation.WindowSlot created.session created.windowIndex)
      (Creation.WindowSlot created.session alias)
    Tmux.capture server

  putStrLn $ "Physical windows: " <> show (length (Tmux.windows snapshot))
  forM_ (Tmux.windowLinks snapshot) $ \link ->
    putStrLn $ "Window index " <> show (Tmux.windowIndexValue link.index)
      <> " refers to " <> Text.unpack (Tmux.renderWindowId (Tmux.windowId link.window))
```

It prints:

<!-- example-output: capture-graph -->
```text
Physical windows: 1
Window index 0 refers to @0
Window index 4 refers to @0
```

The snapshot stays usable after the private daemon exits.

More: [capture and recovery](https://libtmux.org/en/haskell/latest/guides/capture/) ·
[`withRuntime`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-withruntime/) for
[shared lifetimes](https://libtmux.org/en/haskell/latest/guides/shared-runtime/).

Use [`windowZoomed`](src/LibTmux/Query/Fields.hs) to select zoomed windows,
or [`paneMode`](src/LibTmux/Query/Fields.hs) to find panes in copy mode.
[Captured metadata](docs/capture.md#read-captured-metadata) explains coordinates,
link flags and optional client sizes; [offline selections](docs/fixtures.md)
show the typed predicates.

## Find sessions, windows and panes

### [`runQuery`](https://libtmux.org/en/haskell/latest/reference/libtmux-query-v-runquery/): typed predicates over a capture

[`matching`](https://libtmux.org/en/haskell/latest/reference/libtmux-query-v-matching/) filters a source,
[`exactlyOne`](https://libtmux.org/en/haskell/latest/reference/libtmux-query-v-exactlyone/) insists on a single
match and [`fetch`](https://libtmux.org/en/haskell/latest/reference/libtmux-query-v-fetch/) captures fresh. Run it
on its own private daemon.

```console
$ cabal run --verbose=0 query-graph
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
import LibTmux.Creation qualified as Creation
import LibTmux.Query qualified as Q
import LibTmux.Query.Fields qualified as F
import System.Exit (die)

data ApplicationError
  = OperationalFailure (ExceptionWithContext Tmux.TmuxException)
  | InvalidQuery Q.QueryError
  | InvalidSelection Q.CardinalityError
  | UnexpectedResult String

activeWide :: Q.Expr Tmux.Pane
activeWide = Q.allOf [Q.eq F.paneActive True, Q.dimensionAtLeast F.paneWidth 120]

selectedPanes :: Q.Query Tmux.Pane
selectedPanes = Q.panes & Q.matching activeWide

main :: IO ()
main = do
  width <- either (fail . show) pure (Tmux.mkDimension 120)
  alias <- either (fail . show) pure (Tmux.mkWindowIndex 4)
  acquired <- Tmux.tryTmux $ Tmux.withOwnedServer Tmux.defaultOwnedServerConfig $ \server -> do
    created <- Tmux.createSession server Creation.defaultSessionOptions
      { Creation.width = Just width
      , Creation.process = Creation.ShellCommand "exec /bin/cat -"
      }
    Tmux.linkWindow server (Creation.WindowSlot created.session created.windowIndex)
      (Creation.WindowSlot created.session alias)
    snapshot <- Tmux.capture server
    fresh <- Q.fetch server selectedPanes
    pure (snapshot, fresh)
  case first OperationalFailure acquired >>= uncurry report of
    Left (OperationalFailure problem) -> rethrowIO problem
    Left (InvalidQuery problem) -> die ("Query validation failed: " <> show problem)
    Left (InvalidSelection problem) -> die ("Selection failed: " <> show problem)
    Left (UnexpectedResult problem) -> die problem
    Right linesToPrint -> mapM_ putStrLn linesToPrint

report :: Tmux.Snapshot -> Either Q.QueryError [Tmux.Pane] -> Either ApplicationError [String]
report snapshot acquired = do
  selected <- first InvalidQuery (Q.runQuery snapshot selectedPanes)
  let native = [pane | pane <- Tmux.panes snapshot, pane.active, Tmux.dimensionValue pane.width >= 120]
  if selected == native then Right () else Left (UnexpectedResult "query and native selection disagree")
  unique <- first InvalidSelection (Q.exactlyOne selected)
  occurrences <- first InvalidQuery $ Q.runQuery snapshot $
    Q.paneOccurrences & Q.matching (Q.related F.occurrencePane activeWide)
  highest <- first InvalidQuery $ Q.runQuery snapshot $
    Q.windowLinks & Q.orderBy [Q.descending F.linkIndex] & Q.limit 1
  link <- first InvalidSelection (Q.exactlyOne highest)
  let containingEditors = Q.sessions & Q.matching (Q.some F.sessionWindowLinks (Q.some F.linkPanes activeWide))
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

### [`renameSession`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-renamesession/): change a session by reference

Keep the references returned by creation. The
[mutation program](https://libtmux.org/en/haskell/latest/guides/mutations/)
uses them to rename a session and window and change a pane title.

```console
$ cabal run --verbose=0 mutate-graph
```

A new capture shows the changes; the old snapshot keeps its values. Each
rename is its own command, and a later failure undoes nothing.

### [`movePane` and `breakPane`](docs/mutations.md#move-a-running-pane) to relocate a running pane

The same program moves a worker out of its editor window and back. It uses
the same `PaneRef` and resolves each destination from a fresh capture.

## Create sessions, windows and panes

### [`createSession`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-createsession/): create and use its targets

The [creation program](https://libtmux.org/en/haskell/latest/guides/creation/)
uses the returned window and pane, then captures the updated graph:

```console
$ cabal run --verbose=0 create-session
```

After checking duplicate-name rejection, the example removes the targets it
created and checks that the original sessions survive. See the
[creation and removal guide](docs/creation.md#remove-a-target).

Use [`sendKeys`](docs/mutations.md#send-input-to-a-pane) to type text or send
named keys to the new pane.

### [`createWindow`](src/LibTmux/Server.hs): add a window at an explicit placement

The same program adds a window to the created session. Choose its next free
index, an exact slot, or insertion before or after a slot. Occupied slots
require an explicit replacement policy.

### [`splitPane`](src/LibTmux/Server.hs): split one pane through an exact link

The program splits that window's initial pane, sends input to the new pane and
cleans up its session. A `WindowSlot` retains the session and index; a `PaneRef`
chooses the pane even when another pane is active. Capture again for actual
dimensions and pane count.

### [`capturePane`](src/LibTmux/Server.hs) to read the new pane's screen

Read the captured rows with `paneText`. The creation example checks that the
visible row count matches the pane height. The
[pane capture guide](docs/mutations.md#read-pane-text) shows how to read
retained history and keep ANSI styling.

### [`waitForText`](src/LibTmux/Server.hs) to wait for new output

The creation example waits for a readiness marker, captures a baseline,
sends input and waits for a new occurrence with `FreshSince baseline`.
See [text waits](docs/mutations.md#wait-for-pane-text) for timeout and exit
results.

### [`linkWindow`](src/LibTmux/Server.hs) to share a window across slots

The creation example links the worker window at two indices. It selects the
new link, chooses a pane, applies `Tiled` and removes the extra link. See
[window links and focus](docs/creation.md#link-select-and-arrange-windows).

### [`getEnvironment`](src/LibTmux/Server.hs) to inspect a session entry

The example sets an empty value, marks it removed and unsets it in the new
session. [Environment operations](docs/mutations.md#read-and-change-the-environment)
explain scope, visibility and literal bytes.

### [`pasteBuffer`](src/LibTmux/Server.hs) to paste to a specific pane

The [paste buffer example](docs/buffers.md) verifies a binary round trip and
observes the output of a pane after pasting text with preserved line feeds.

### [`lookupOption`](src/LibTmux/Options.hs) to find a setting's type and scope

Pass `serverCapabilities server` to look up native settings or hooks for
the connected daemon. See [options and hooks](docs/options.md) for the
pinned releases and list operations.

### [`setOption`](src/LibTmux/Server.hs) and [`setHook`](src/LibTmux/Server.hs) to configure a session

The [session settings program](docs/options.md) reads a local history limit
and observes a rename hook's effect.

```console
$ cabal run --verbose=0 configure-session
```

<!-- example-output: configure-session -->
```text
local history-limit = 500
rename hook recorded the change
```

### [`withControl`](src/LibTmux/Server.hs) to watch a window

The [control example](docs/control.md) observes a rename through a bounded
stream. [`waitForPaneState`](src/LibTmux/Server.hs) then confirms
that a split pane is gone.

```console
$ cabal run --verbose=0 watch-window
```

<!-- example-output: watch-window -->
```text
window renamed to control-demo
split pane removed
```

## Resize panes and windows

### [`resizePane`](src/LibTmux/Server.hs) and [`resizeWindow`](src/LibTmux/Server.hs): request absolute cells

The [geometry program](docs/resizing.md) chooses a width, height or both,
prints fresh dimensions and removes its disposable session:

```console
$ cabal run --verbose=0 resize-geometry
```

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

Native layouts can clamp requested sizes. Every supplied axis must fit
1 through 10000 cells before dispatch. More: [resizing and recovery](docs/resizing.md).

## Run a terminal application

### [`runProgram`](src/LibTmux/Server.hs): run, observe and clean up owned work

The [program example](examples/managed-program/Main.hs) runs literal argv,
cancels and retries an interactive wait, and bounds an owning scope. It requires
tmux 3.8, Linux 6.9 process-group pidfds and Bash timed reads:

```console
$ cabal run --verbose=0 managed-program
```

<!-- example-output: managed-program -->
```text
exit: ProgramExited 7
literal argv: True
cancelled observation: True
interactive retry: True
owning deadline: True
borrowed resources preserved: True
```

More: [program ownership, bounds and recovery](docs/programs.md).

## Connect to an existing daemon

### [`withServer`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-withserver/): borrow a connection

Pass its socket path to `serverConfig`. The scope retires the library’s
connection resources and leaves the daemon running.

[`killServer`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-killserver/)
waits for the daemon generation admitted by this handle to exit.
[Generation checks and recovery](docs/capture.md#retire-a-server-early)

## Find the right guide

| Task | Start here |
| --- | --- |
| Install in an application | [Cabal installation](https://libtmux.org/en/haskell/latest/guides/installation/) |
| Capture, filter and navigate linked windows | [Observations and recovery](https://libtmux.org/en/haskell/latest/guides/capture/) |
| Compose typed predicates, traverse relations and require one match | [Typed queries](https://libtmux.org/en/haskell/latest/guides/query/) |
| Create sessions, windows and panes with recoverable targets | [Creation](https://libtmux.org/en/haskell/latest/guides/creation/) |
| Set absolute pane and window geometry | [Resizing](docs/resizing.md) |
| Rename sessions/windows, set pane titles and recover interrupted commands | [Mutations](https://libtmux.org/en/haskell/latest/guides/mutations/) |
| Share ownership across independent Server scopes | [Shared Runtime](https://libtmux.org/en/haskell/latest/guides/shared-runtime/) |
| Understand IDs, indices and validation errors | [Typed values](https://libtmux.org/en/haskell/latest/guides/typed-values/) |
| Test graph predicates without tmux | [Validated offline fixtures](https://libtmux.org/en/haskell/latest/guides/offline-fixtures/) |
| Inspect a Haskell application’s tmux daemon from an agent | [MCP setup and discovery](docs/agents.md) |
| Reproduce capture measurements | [Performance](https://libtmux.org/en/haskell/latest/guides/performance/) |
| Browse connection and mutation operations | [`LibTmux.Server`](https://libtmux.org/en/haskell/latest/reference/libtmux-server/) |
| Preview tmuxp YAML and apply it to a new session | [Workspace loader](docs/workspaces.md) |
| Browse declarations and module documentation | [API reference](https://libtmux.org/en/haskell/latest/reference/) |
| See what works today and what is planned | [Status](https://libtmux.org/en/haskell/latest/guides/status/) |

## Support and status

- **Experimental.** The API may change.
- **Works today.** Private daemon scopes, typed graph queries, pane input, bounded capture and control notifications.
- **Platform.** Linux x86_64. [Host requirements](docs/installation.md).
- **More.** [Status](https://libtmux.org/en/haskell/latest/guides/status/) · [source guides](docs/README.md).

[Contributing](.github/CONTRIBUTING.md) · [License](LICENSE) · [Branding assets](docs/branding.md)
