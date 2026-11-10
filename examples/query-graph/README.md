<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../docs/assets/logo.svg" type="image/svg+xml">
    <img src="../../docs/assets/logo-128.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Query a captured graph

[Main.hs](Main.hs) compares a typed query with an ordinary pane predicate,
traverses relationships and checks cardinality. It distinguishes one physical
pane from that pane's two appearances through window links.

Create the [README's private demonstration server](../../README.md), then run
from the repository root:

```console
$ cabal run --verbose=0 query-graph -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

Compare the result with [expected.stdout](expected.stdout), then follow the
README's teardown commands. The program releases its handles without stopping
the supplied server.

The [query guide](../../docs/query.md) explains pure evaluation, explicit fresh
acquisition, relationship semantics and application error handling. CI executes
the installed program and checks output and owned fixture cleanup.
