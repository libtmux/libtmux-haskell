# API documentation

The public modules are:

| Module | Read it for |
| --- | --- |
| [LibTmux](../src/LibTmux.hs) | Common observation, Server and scalar entry point |
| [LibTmux.Server](../src/LibTmux/Server.hs) | Private and borrowed scopes, capture, creation, mutations, geometry and deadlines |
| [LibTmux.Recovery](../src/LibTmux/Recovery.hs) | Inspect and resume cleanup of retained scopes and operations |
| [LibTmux.Options](../src/LibTmux/Options.hs) | Daemon-specific catalogues, option stores and scalar values |
| [LibTmux.Control](../src/LibTmux/Control.hs) | Control events, bounded queues and terminal results |
| [LibTmux.Program](../src/LibTmux/Program.hs) | Scoped application execution, input, exit, rendered output and cleanup |
| [LibTmux.Capabilities](../src/LibTmux/Capabilities.hs) | Per-operation requirements from the connected daemon release |
| [LibTmux.Creation](../src/LibTmux/Creation.hs) | Session options, process modes and historical created references |
| [LibTmux.Snapshot](../src/LibTmux/Snapshot.hs) | Detached entities, typed references, collections and indexed navigation |
| [LibTmux.Snapshot.Fixture](../src/LibTmux/Snapshot/Fixture.hs) | Pure fixture construction and graph validation |
| [LibTmux.Id](../src/LibTmux/Id.hs) | Distinct entity IDs, canonical parsing, rendering and `IdError` |
| [LibTmux.Value](../src/LibTmux/Value.hs) | Checked dimensions/indices, absolute resize requests and `ValueError` |
| [LibTmux.Version](../src/LibTmux/Version.hs) | Release identity, ordering, minimum-version admission and `VersionError` |
| [LibTmux.Query](../src/LibTmux/Query.hs) | Pure typed predicates, ordering, requirements, cardinality and explicit fresh fetch |
| [LibTmux.Query.Fields](../src/LibTmux/Query/Fields.hs) | Row-prefixed captured fields and typed relationships |

Import `LibTmux.Query` as `Q` and `LibTmux.Query.Fields` as `F`, as the
[query program](query.md) does. The common `LibTmux` module keeps snapshot collection access separate
from query descriptions.
The [program guide](programs.md) runs a terminal application, cancels and retries
an observation, and distinguishes owning deadlines from observation timeouts.
The [resizing program](resizing.md) changes absolute geometry and reports actual cells.
The [creation program](creation.md) uses actual returned references and reads
them from a new capture. The [mutation program](mutations.md) renames its
newly created targets and compares their detached observations afterward.

Build the native Haddock browser from a checkout:

```console
$ cabal haddock lib:libtmux-haskell --offline
```

Prepare a separate browser copy with checked local navigation:

```console
$ uv run scripts/prepare_haddock/prepare_haddock.py \
    dist-newstyle/haddock-prepared \
    --build-plan dist-newstyle/cache/plan.json
```

The destination must be new; choose another directory or remove your previous
generated copy before preparing it again. The command selects the configured
library from Cabal's plan and leaves Cabal's original output untouched.

Serve the copy over HTTP so Quick Jump can load its search index:

```console
$ python3 -m http.server 8000 \
    --bind 127.0.0.1 \
    --directory dist-newstyle/haddock-prepared
```

Open [the local API browser](http://127.0.0.1:8000/).

- Module overviews explain the types. Declarations give input domains, results
  and errors.
- Declaration-to-source links, symbol search and a Hoogle index are enabled.
- Acquisition and recovery are explicit `IO`. Field access, list processing,
  parsers and navigation are pure.
- Record fields use
  [`OverloadedRecordDot`](https://downloads.haskell.org/ghc/latest/docs/users_guide/exts/overloaded_record_dot.html).
  There are no top-level selector functions.
- Detached records support patterns and local updates. Snapshot assembly and
  targeting references are opaque.
- To update an ambiguous record field, qualify it by its defining module:
  import `LibTmux.Server` as `Server` and update `Server.socketPath`. This
  avoids deprecated type-directed disambiguation.

The prepared copy repairs Haddock's navigation:

- Repeated record labels get owner-qualified anchors. Instance methods get
  local targets.
- A field name offers its record owners; a source identifier on several lines
  offers those lines.
- Wide sections scroll within the page on narrow screens. Source listings keep
  their scrolling inside a keyboard-focusable region.
- Source text and identifier targets keep their native contents. No private API
  page is added.

`navigation.json` records raw and prepared file digests and edit counts. The
check rejects missing local targets, browser assets and unexpected duplicate
IDs, including index and search links. It does not verify external dependency
URLs, prove that a raw directory is fresh, or publish anything.

The complete [capture example](../examples/capture-graph/Main.hs),
[shared Runtime example](../examples/shared-runtime/Main.hs),
[typed query example](../examples/query-graph/Main.hs),
[creation example](../examples/create-session/Main.hs),
[geometry example](../examples/resize-geometry/Main.hs) and
[typed-value example](../examples/typed-values/Main.hs) use only public
exports. Their source and output are checked against the source archive by
the [consumer check](../scripts/check_sdist/check_sdist.py).

Private graph, framing and transport modules are implementation details.
The source layout does not define visibility: Cabal's `exposed-modules`
controls the installed API. See [status](status.md) for remaining work.

## Query field migration for the shared site

The Haskell site update in [libtmux/docs#309](https://github.com/libtmux/docs/pull/309)
needs the new exposed-module list and native Haddock archive. Replace the eight
field-module pages with `LibTmux.Query.Fields`; keep `LibTmux.Query` for sources,
predicates and execution. Do not retain the retired imports in site examples.

| Retired module | New token prefix |
| --- | --- |
| `LibTmux.Query.Session` | `session`, for example `F.sessionWindowLinks` |
| `LibTmux.Query.Window` | `window`, for example `F.windowZoomed` |
| `LibTmux.Query.Pane` | `pane`, for example `F.paneActive` |
| `LibTmux.Query.Link` | `link`, for example `F.linkFlags` |
| `LibTmux.Query.Occurrence` | `occurrence`, for example `F.occurrencePane` |
| `LibTmux.Query.Client` | `client`, for example `F.clientHeight` |
| `LibTmux.Query.ClientAttachment` | `clientAttachment`, for example `F.clientAttachmentPane` |
| `LibTmux.Query.ServerInfo` | `serverInfo`, for example `F.serverInfoVersion` |

Use `F.windowLinks` for a window's appearances and `Q.windowLinks` as a
query source. Refresh the API sidebar, symbol search and declaration links
from that archive.
The native target for `F.paneActive` is
`LibTmux-Query-Fields.html#v:paneActive`; each token keeps its scalar or
relationship type and its query requirement name. Copy the current registered
programs and installation source pins so rendered snippets use the same API.
