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

The program creates its own daemon. Run from the repository root.

```console
$ cabal run --verbose=0 mutate-graph
```

Compare the result with [expected.stdout](expected.stdout).

More: [mutations](../../docs/mutations.md).
