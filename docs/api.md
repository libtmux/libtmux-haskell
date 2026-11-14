# API documentation

The public modules are:

| Module | Read it for |
| --- | --- |
| [LibTmux](../src/LibTmux.hs) | Common observation, Server and scalar entry point |
| [LibTmux.Server](../src/LibTmux/Server.hs) | Operational scope, capture, rename/title commands, deadlines and recovery |
| [LibTmux.Snapshot](../src/LibTmux/Snapshot.hs) | Detached entities, typed references, collections and indexed navigation |
| [LibTmux.Snapshot.Fixture](../src/LibTmux/Snapshot/Fixture.hs) | Pure fixture construction and graph validation |
| [LibTmux.Id](../src/LibTmux/Id.hs) | Distinct entity IDs, canonical parsing, rendering and `IdError` |
| [LibTmux.Value](../src/LibTmux/Value.hs) | Checked dimensions/indices, numeric access and `ValueError` |
| [LibTmux.Version](../src/LibTmux/Version.hs) | Stable-release identity, admission and `VersionError` |
| [LibTmux.Query](../src/LibTmux/Query.hs) | Pure typed predicates, ordering, requirements, cardinality and explicit fresh fetch |
| [LibTmux.Query.Pane](../src/LibTmux/Query/Pane.hs) | Physical pane fields and window relationship |
| [LibTmux.Query.Session](../src/LibTmux/Query/Session.hs) | Session fields, window links and attached clients |
| [LibTmux.Query.Window](../src/LibTmux/Query/Window.hs) | Physical window fields, panes and contextual appearances |
| [LibTmux.Query.Link](../src/LibTmux/Query/Link.hs) | Session/index context and navigation to physical entities |
| [LibTmux.Query.Occurrence](../src/LibTmux/Query/Occurrence.hs) | Pane and link of a contextual appearance |
| [LibTmux.Query.Client](../src/LibTmux/Query/Client.hs) | Captured client fields and optional attachment |
| [LibTmux.Query.ClientAttachment](../src/LibTmux/Query/ClientAttachment.hs) | A client's selected session, window and contextual pane |
| [LibTmux.Query.ServerInfo](../src/LibTmux/Query/ServerInfo.hs) | Captured daemon metadata fields |

Import query sources and field modules qualified, as the [query program](query.md)
does. The common `LibTmux` module keeps snapshot collection access separate
from query descriptions.
The [mutation program](mutations.md) selects physical targets before issuing
commands and compares their detached observations afterward.

Build the native Haddock browser from a checkout:

```console
$ cabal haddock lib:libtmux-haskell --offline
```

Prepare a separate browser copy with checked local navigation:

```console
$ python3 scripts/prepare_haddock.py \
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
[typed query example](../examples/query-graph/Main.hs) and
[typed-value example](../examples/typed-values/Main.hs) use only public
exports. Their source and output are checked against the source archive by
the [consumer check](../scripts/check_sdist.py).

Private graph, framing and transport modules are implementation details.
The source layout does not define visibility: Cabal's `exposed-modules`
controls the installed API. See [status](status.md) for remaining work.
