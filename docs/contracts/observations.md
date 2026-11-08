# Captured values and local selection

Proposed contract; these APIs are not implemented. Acquisition remains an
explicit `capture` or `fetch` operation. None of the operations below reads
tmux, refreshes a handle or acquires a resource.

## Sources and context

| Source | Result | Order and multiplicity |
| --- | --- | --- |
| Complete snapshot | Sessions, physical windows, physical panes, observed clients | Numeric entity ID order; observed clients use their captured name bytes. |
| Session in a snapshot | Window links | Link index, then numeric window ID. Two indices pointing at one window remain two links. |
| Session in a snapshot | Pane occurrences | Link order, then pane index and numeric pane ID. Repeated links retain repeated occurrences. |
| Physical window in a snapshot | Physical panes | Pane index, then numeric pane ID. |
| Physical window in a snapshot | Linked sessions | Unique session references in numeric ID order. Use window links when index or multiplicity matters. |

`WindowLink.session` and `PaneOccurrence.link.session` provide session
context. A physical window or pane has no unique session. The physical pane
record identifies its window directly; resolving that reference to a record
uses the supplied snapshot. A reference from an earlier capture resolves to
the supplied snapshot's observation when its connection generation matches.
Capture provenance is separate from reference equality.

References supplied to graph accessors must belong to the snapshot's endpoint
and connection generation. A missing or foreign reference is a `LookupError`, not
an empty relationship. Known empty relationships are valid values. Active
window and pane accessors follow the validated graph; session active-pane
access returns an occurrence carrying the active window link.

An observed client's attached session, window link and pane occurrence are
stored detached values from that capture. Their projections take only the
observed client, so they cannot resolve an older client name in a newer
snapshot. The client may be unattached. These optional relationships do not
identify a later process occupying the same client name or tty.

Attached-session selection means captured attached count greater than zero.
This deliberately corrects the pinned Python helper's `__noeq` predicate,
which is not a registered lookup operator. Qualify counts zero, one and two;
do not preserve a defect that excludes a session with multiple clients.

## Record access

IDs, names, indices, dimensions, titles and edge flags are ordinary record
projections. Reference equality describes identity; record equality compares
observed contents. A renamed entity can retain its reference while its record
changes. Window indices belong to links, not physical windows. Indices are
checked nonnegative values; dimensions are checked positive values.

Deprecated Python `get` field helpers map to record projection. They do not
introduce a string-keyed Haskell getter. Missing capabilities have a distinct
representation or prevent the required capture; `Nothing` means supported
absence. A projection never performs deferred fallible decoding.

Caller-edited records do not alter snapshot indexes or certify capture
provenance. Provide validated offline fixtures with a detached origin; their
references cannot target a live Server. Snapshot and reference construction
remain validated, including through reconstruction-capable instances.

## Reported text and POSIX values

The private [graph model](../../internal/LibTmux/Internal/Graph.hs) keeps
session names and pane titles as strict Text. Window names use a lossless
[TmuxText](../../internal/LibTmux/Internal/TmuxText.hs) value with byte equality
and explicit UTF-8 conversion. Conversion failure preserves the original
label; it does not remove an entity or fail the complete capture.

Current process names use PosixString and current paths use PosixPath. These
hold reported endpoint bytes without filesystem access, locale conversion
or local path resolution. Capture forces the owned values before returning.
Explicit text conversion is subsequent pure application logic, not a hidden
field read. No replacement decoding occurs.

Preserving a report does not recover upstream normalization. Supported tmux
releases before 3.7 can report invalid UTF-8 in names and process commands.
tmux 3.7+ can instead report an empty command after rejecting its bytes, and
new-window name validation also changes at that boundary. Verify the reported
value against the qualified release; do not infer the original argv from it.

These are private implementation types. Their installed public ergonomics,
query/wire profiles and complete Snapshot coverage remain qualification work.

## Selection and cardinality

Native `filter`, comprehensions, `map` and folds process captured lists
without restrictions on application logic. Search and deprecated dynamic
lookup aliases map to these operations or to an explicitly typed query.
They do not require duplicate wrapper functions in the public API.

Python's `search_*` methods also accept arbitrary tmux `-f` format strings
and perform acquisition. The native pure replacement deliberately changes
that input/effect boundary: arbitrary tmux formats use the explicit low-level
`IO` command path. They are not silently translated into a closed query or
evaluated as pure functions.

The former `items` operation becomes an ordinary list of `(key, row)` pairs
using an explicit key projection. Preserve duplicate keys and source order;
converting to a map would change its behavior.

Typed queries validate every field, relationship and evaluator requirement
against the snapshot before evaluating any branch. The result is
`Either QueryError [row]`. Filtering preserves source order and multiplicity;
sorting and limits are explicit and follow membership evaluation.

`exactlyOne` returns a cardinality error for zero or multiple matches.
`atMostOne` returns `Right Nothing` for zero and an error for multiple matches.
The Python `find_where` and `get_by_id` replacements use the latter behavior.
Looking up a physical window ID in a list of links can still be ambiguous
when two links point at that window. An ambiguity
check can stop after the second match and report “at least two”; proving
uniqueness can still examine the whole source. These checks reserve no target
against later tmux changes.

## Required cases

Retain a snapshot after client closure and evaluate all these operations.
Verify no external operation occurs; compare identical references with
different observed contents; preserve two links to one window in a session;
check occurrence multiplicity and deterministic ordering; reject foreign
references; exercise unattached clients; and distinguish zero, one and two
matches before any mutation. Intended wrong entity, field and operand
combinations must fail compilation for their stated reason.
