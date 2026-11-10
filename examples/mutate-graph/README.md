<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../docs/assets/logo.svg" type="image/svg+xml">
    <img src="../../docs/assets/logo-128.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Rename captured targets

[Main.hs](Main.hs) selects one physical pane, follows its window reference,
renames the session and window, and changes the pane title. A fresh capture
shows the changes; the original snapshot keeps its old values. The linked
window still has two appearances.

This program changes the supplied server. Use the
[README's private demonstration server](../../README.md), then run from the
repository root:

```console
$ cabal run --verbose=0 mutate-graph -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

Compare the result with [expected.stdout](expected.stdout), then follow the
README's teardown commands. The program releases its connection resources
without stopping the supplied server.

The [mutation guide](../../docs/mutations.md) covers target identity, deadlines,
known and uncertain outcomes, and recovery. CI checks the installed program's
output and observes owned fixture teardown on both tmux endpoints.
