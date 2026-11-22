<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../assets/logo.svg" type="image/svg+xml">
    <img src="../../assets/logo.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Query a captured graph

[Main.hs](Main.hs) runs a typed query with
[`runQuery`](https://libtmux.org/en/haskell/latest/reference/libtmux-query-v-runquery/), then compares it with a plain pane
predicate.

- Traverses relationships and checks cardinality.
- Tells one physical pane from its two appearances through window links.

Run from the repository root.

```console
$ cabal run --verbose=0 query-graph
```

Expected output: [expected.stdout](expected.stdout). Then run the README's
cleanup commands; the program leaves your server running.

More: [typed queries](../../docs/query.md).
