<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../assets/logo.svg" type="image/svg+xml">
    <img src="../../assets/logo.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Rename captured targets and move a pane

[Main.hs](Main.hs) calls
[`renameSession`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-renamesession/),
[`renameWindow`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-renamewindow/) and
[`setPaneTitle`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-setpanetitle/).
It splits a worker pane, moves it into a vacant window and brings it back.
Each step resolves the same pane in a fresh snapshot.

The program creates its own daemon. Run from the repository root.

```console
$ cabal run --verbose=0 mutate-graph
```

Compare the result with [expected.stdout](expected.stdout).

[Pane relocation and recovery](../../docs/mutations.md#move-a-running-pane).
