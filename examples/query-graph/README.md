<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../docs/assets/logo.svg" type="image/svg+xml">
    <img src="../../docs/assets/logo-128.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Query a captured graph

[Main.hs](Main.hs) runs a typed query with
[`runQuery`](https://libtmux.org/en/haskell/latest/reference/libtmux-query-v-runquery/), then compares it with a plain pane
predicate.

- Traverses relationships and checks cardinality.
- Tells one physical pane from its two appearances through window links.

Start the [README's demo server](../../README.md), then run from the
repository root:

```console
$ cabal run --verbose=0 query-graph -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

Expected output: [expected.stdout](expected.stdout). Then run the README's
cleanup commands; the program leaves your server running.

More: [typed queries](../../docs/query.md).
