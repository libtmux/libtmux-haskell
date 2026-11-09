# API documentation

The public modules are:

| Module | Read it for |
| --- | --- |
| [LibTmux](../src/LibTmux.hs) | Common entry point re-exporting the public modules |
| [LibTmux.Server](../src/LibTmux/Server.hs) | Operational scope, configuration, capture, failures and recovery |
| [LibTmux.Snapshot](../src/LibTmux/Snapshot.hs) | Detached entities, typed references, collections and indexed navigation |
| [LibTmux.Snapshot.Fixture](../src/LibTmux/Snapshot/Fixture.hs) | Pure fixture construction and graph validation |
| [LibTmux.Id](../src/LibTmux/Id.hs) | Distinct entity IDs, canonical parsing, rendering and `IdError` |
| [LibTmux.Value](../src/LibTmux/Value.hs) | Checked dimensions/indices, numeric access and `ValueError` |
| [LibTmux.Version](../src/LibTmux/Version.hs) | Stable-release identity, admission and `VersionError` |

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
Module overviews explain the types; declarations specify input domains, results and
errors. The project enables declaration-to-source links, interactive symbol
search and a Hoogle index for this package. Acquisition and recovery are
explicit `IO`; field access, list processing, parsers and navigation are pure.
Record fields use
[`OverloadedRecordDot`](https://downloads.haskell.org/ghc/9.14.1/docs/users_guide/exts/overloaded_record_dot.html);
the library does not generate
top-level selector functions. Detached record constructors support patterns
and local updates. Snapshot assembly and targeting references remain opaque.
For an ambiguous record update, qualify the field through its defining module.
For example, import `LibTmux.Server` as `Server` and update `Server.socketPath`;
this identifies the field owner without deprecated type-directed disambiguation.

The copy repairs navigation in Haddock 2.33.0's output: repeated record labels have
distinct owner-qualified anchors, and instance methods have local targets.
A name-only field link offers its record owners; a source identifier on
several lines offers those lines. Missing hidden-module instance attributions
retain their text and valid Source links. No private API page is added.

`navigation.json` records raw and prepared file digests and edit counts.
The check rejects missing local targets and unexpected duplicate IDs, including
index and search links. It preserves signatures, instances, source text and
compiled interfaces. It does not verify external dependency URLs, prove that
an arbitrary raw directory is fresh, or publish anything. CI builds from its
checked-out source and retains the raw and prepared artifacts separately.

The complete [capture example](../examples/capture-graph/Main.hs),
[shared Runtime example](../examples/shared-runtime/Main.hs) and
[typed-value example](../examples/typed-values/Main.hs) use only public
exports. Their source and output are checked against the source archive by
the [consumer check](../scripts/check_sdist.py).

Private graph, framing and transport modules are implementation details.
The source layout does not define visibility: Cabal's `exposed-modules`
controls the installed API. See [status](status.md) for remaining work.
