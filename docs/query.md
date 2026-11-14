# Select observations with typed queries

[`runQuery`](../src/LibTmux/Query.hs) evaluates a typed query over a
[`Snapshot`](../src/LibTmux/Snapshot.hs) and returns lists in
`Either QueryError`. Use it when you need to inspect a predicate, use typed
fields or compose relationships. Plain comprehensions and `filter` still work
for everything else; see [capture](capture.md).

The program finds active panes at least 120 cells wide, then:

- Compares the query with a plain predicate on one snapshot.
- Checks uniqueness.
- Follows session, link and pane relationships.
- Prints the fields the query requires.

The demo links one window at indices 0 and 4, so its one physical pane
appears twice as a contextual match.

Start the [demo server](../README.md) from the README, then run from a
[checkout](../.github/CONTRIBUTING.md#toolchain):

```console
$ cabal run --verbose=0 query-graph -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

Everything in it is pure except [`capture`](../src/LibTmux/Server.hs) and
[`fetch`](../src/LibTmux/Query.hs).

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

Expected output:

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

## Choose the source before checking cardinality

- [`panes`](../src/LibTmux/Query.hs) selects unique physical panes.
- [`paneOccurrences`](../src/LibTmux/Query.hs) selects their appearances
  through window links. Filtering keeps the source's multiplicity.
- `exactlyOne` rejects no match and reports `AtLeastTwoMatches` at the second
  match, without counting the rest. Proving uniqueness can still traverse every
  input element.
- `atMostOne` also allows no match.

Relationships:

- [`some`](../src/LibTmux/Query.hs) tests one related child against its whole
  predicate. To require several conditions on one pane, put them all inside it;
  two separate `some` predicates can match different panes.
- On a known empty relation, `some` is false; `every` and `none` are true.
- `optionalRelated` is false for a known absent target. Its negation includes
  absence.
- A missing required lookup is an error. So is an unavailable relationship,
  even on an empty source or in a short-circuited branch.

## Inspect, order and limit

- The qualified [field modules](api.md) expose typed tokens. Boolean fields
  reject numeric comparisons; fields of different row types do not mix.
- `dimensionAtLeast` takes an unbounded `Integer`; observed dimensions keep
  their checked type.
- Text equality and containment are exact: no case folding, no Unicode
  normalization.
- Command names, paths and window labels keep their byte-preserving types,
  with no implicit text conversion.

[`requirements`](../src/LibTmux/Query.hs) lists a query's source, field and
relationship names, ordering keys and limit. It inspects dependencies; it is
not serialization or an execution plan. Validation checks every declared
requirement before reading rows, including ordering keys, empty membership
predicates and zero limits.

Building a query:

- `matching` adds predicates.
- `orderBy` replaces the ordering keys. The sort is stable, so ties keep source
  order.
- `limit` replaces the final bound, a nonnegative `Natural`.
- Evaluation always filters, then orders, then limits, whatever the builder
  order.
- Descriptions and operand lists must be finite.

## Keep acquisition and failures explicit

- [`fetch`](../src/LibTmux/Query.hs) captures a new complete snapshot on every
  call. It checks evaluator support before acquiring, then validates version
  requirements against the captured metadata.
- It does no backend filtering. To share observations across selections, reuse
  `runQuery` on one snapshot; see [capture costs](performance.md).

Errors:

- The example folds operational, query and cardinality errors into one
  application error type.
- `tryTmux` catches library exceptions only; asynchronous cancellation
  propagates.
- `rethrowIO` keeps the exception context, so cleanup and capture recovery
  owners stay reachable. To inspect and resume them, see
  [recovery](capture.md).

Reading the result:

- The report reads detached values after the Server closes.
- The equality check uses one snapshot; the fresh-capture count is a second
  acquisition. Two captures of a changing server do not prove the evaluator
  equals the plain predicate.
- Cardinality and reference equality describe what was observed, not what is
  alive now.
- Query interchange, backend optimization and event streams are not
  implemented; see [status](status.md).

To use it in your own application, copy the
[program](../examples/query-graph/Main.hs) and
[package file](../examples/query-graph/libtmux-query-graph.cabal), then add its
[pinned source dependency](../examples/query-graph/cabal.project.vcs) as
described in [installation](installation.md).
