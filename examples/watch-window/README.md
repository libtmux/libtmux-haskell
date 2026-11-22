<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../assets/logo.svg" type="image/svg+xml">
    <img src="../../assets/logo.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Observe a window rename

[Main.hs](Main.hs) observes a rename in a bounded control stream. It then
asks a split pane to exit and waits until the graph confirms its removal.

Run from the repository root.

```console
$ cabal run --verbose=0 watch-window
```

Compare with [expected.stdout](expected.stdout). The program retires the
control client before removing its session. See [control notifications](../../docs/control.md)
for queue limits and outcomes.
