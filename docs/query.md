# Select observations with typed queries

Use [`runQuery`](../src/LibTmux/Query.hs) when a predicate needs inspection,
typed fields or relationship composition. It reads an existing
[`Snapshot`](../src/LibTmux/Snapshot.hs) and returns ordinary lists inside
`Either QueryError`. Native comprehensions and `filter` remain the unrestricted
path for application logic; see the [capture program](capture.md).

This program finds active panes at least 120 cells wide. It compares the
typed selection with a native predicate over the same snapshot, checks
uniqueness, follows session-to-link-to-pane relationships, and inspects the
required fields. The fixture links one window at indices 0 and 4: one
physical pane therefore appears twice in the contextual source.

Create the [private demonstration server](../README.md) from the README. From a
[provisioned checkout](../.github/CONTRIBUTING.md#toolchain), run:

```console
$ cabal run --verbose=0 query-graph -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

CI runs the installed program against an owned fixture, asserts output and
empty stderr, and observes the server and initial pane exiting afterward.
The program accepts an existing socket and tmux executable. Every
query construction and selection below is pure except the explicitly named
[`capture`](../src/LibTmux/Server.hs) and [`fetch`](../src/LibTmux/Query.hs).

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

[`panes`](../src/LibTmux/Query.hs) selects unique physical panes.
[`paneOccurrences`](../src/LibTmux/Query.hs) selects their appearances through
window links. Filtering preserves the chosen source's multiplicity.
`exactlyOne` rejects no matches and reports `AtLeastTwoMatches` at the second
match; it does not count the remaining list. `atMostOne` also permits absence.
Proving uniqueness may still require traversing every input element.

[`some`](../src/LibTmux/Query.hs) tests one related child against its entire
predicate. Put all required conditions inside that child predicate when one
pane must satisfy them together. Two separate existential predicates may
match different panes. Over a known empty relation, `some` is false, `every`
is true and `none` is true. Missing required lookups remain errors.
`optionalRelated` is false for a known absent target; its negation includes
absence. An unavailable relationship is a validation error, even on an empty
source or in a branch that would otherwise short-circuit.

## Inspect, order and limit

The qualified [field modules](api.md) expose typed tokens from the capture
catalogue. Boolean fields cannot take numeric comparisons, and fields from
different row types cannot be mixed. `dimensionAtLeast` accepts an unbounded
`Integer` threshold while observed dimensions retain their checked type.
Text equality and containment are exact, without case folding or Unicode
normalization. Command names, paths and window labels retain their declared
byte-preserving types; there is no implicit text conversion.

[`requirements`](../src/LibTmux/Query.hs) reports stable source, field and
relationship names, ordering keys and the final limit. This is dependency
inspection, not serialization or a backend execution plan. Validation checks
all declared requirements before examining rows, including ordering keys,
empty membership predicates and zero limits.

`matching` accumulates predicates. `orderBy` replaces the ordering keys and
uses stable sorting; tied rows keep source order. `limit` replaces the final
nonnegative `Natural` bound. Evaluation always filters, orders and then
limits, regardless of builder order. Every authored description and operand
list must be finite.

## Keep acquisition and failures explicit

[`fetch`](../src/LibTmux/Query.hs) captures a new complete snapshot on every
call. It checks compiled evaluator support before acquisition, then validates
version requirements against captured metadata. This implementation performs
no backend filtering. Reuse `runQuery` over one snapshot when several
selections should share observations; see [capture costs](performance.md).

The example combines operational exceptions, pure query errors and
cardinality errors in an application error type. `tryTmux` catches library
exceptions only. Its handler preserves the exception context with `rethrowIO`,
keeping cleanup and capture recovery owners reachable; asynchronous
cancellation propagates. See [recovery](capture.md) when an application needs
to inspect and resume those owners.

The report reads detached values after the Server closes. Its equality check
uses one snapshot. The final fresh-capture count demonstrates another
acquisition; two independently changing captures do not prove evaluator
equivalence. Cardinality and reference equality establish observed selection,
not current liveness. Public mutation, query interchange, backend optimization
and event subscriptions remain [unfinished](status.md).

For a separate application, copy the [program](../examples/query-graph/Main.hs)
and [package file](../examples/query-graph/libtmux-query-graph.cabal), then use
its [immutable source dependency](../examples/query-graph/cabal.project.vcs)
with the [installation instructions](installation.md).
