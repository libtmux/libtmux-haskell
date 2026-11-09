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

Open the `index.html` path printed by Cabal. Module overviews explain the
types; declaration documentation specifies input domains, results and
errors. The project enables declaration-to-source links, interactive symbol
search and a Hoogle index for this package. Acquisition and recovery are
explicit `IO`; field access, list processing, parsers and navigation are pure.
Record fields use
[`OverloadedRecordDot`](https://downloads.haskell.org/ghc/9.14.1/docs/users_guide/exts/overloaded_record_dot.html);
the library does not generate
top-level selector functions. Detached record constructors support patterns
and local updates. Snapshot assembly and targeting references remain opaque.

Haddock 2.33.0 has native output limitations: some derived-instance method
self-links lack targets, hidden-module instance attribution links have no
page, and repeated record labels share field anchors within a module. Use
the enclosing record declaration and source links for those fields. Native
declaration coverage does not establish that every generated link works.

The complete [capture example](../examples/capture-graph/Main.hs) and
[typed-value example](../examples/typed-values/Main.hs) use only public
exports. Their source and output are checked against the source archive by
the [consumer check](../scripts/check_sdist.py).

Private graph, framing and transport modules are implementation details.
The source layout does not define visibility: Cabal's `exposed-modules`
controls the installed API. See [status](status.md) for remaining work.
