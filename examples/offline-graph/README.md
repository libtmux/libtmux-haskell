<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../docs/assets/logo.svg" type="image/svg+xml">
    <img src="../../docs/assets/logo-128.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Test a pane policy without tmux

[Main.hs](Main.hs) builds a fixture with
[`validateFixture`](https://libtmux.org/en/haskell/latest/reference/libtmux-snapshot-fixture-v-validatefixture/) and selects
active panes by width.

- Opens no socket and starts no process.
- Links one window twice, so physical entities and appearances differ.
- Fixture references never target a live server.

Run from the repository root:

```console
$ cabal run --verbose=0 offline-graph
```

Expected output: [expected.stdout](expected.stdout).

More: [offline fixtures](../../docs/fixtures.md).
