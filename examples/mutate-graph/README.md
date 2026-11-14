<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../docs/assets/logo.svg" type="image/svg+xml">
    <img src="../../docs/assets/logo-128.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Rename captured targets

[Main.hs](Main.hs) selects one pane, then calls
[`renameSession`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-renamesession/),
[`renameWindow`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-renamewindow/) and
[`setPaneTitle`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-setpanetitle/).

- A fresh capture shows the changes; the original snapshot keeps its old values.
- The renamed window still has two appearances.

This program changes the server you give it. Start the
[README's demo server](../../README.md), then run from the repository root:

```console
$ cabal run --verbose=0 mutate-graph -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

Expected output: [expected.stdout](expected.stdout). Then run the README's
cleanup commands; the program leaves your server running.

More: [mutations](../../docs/mutations.md).
