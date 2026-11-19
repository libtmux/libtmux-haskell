<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../docs/assets/logo.svg" type="image/svg+xml">
    <img src="../../docs/assets/logo-128.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Capture a tmux graph

[Main.hs](Main.hs) opens a private daemon, links one window at two indices,
and prints both links from a detached snapshot after the daemon exits.

Run from the repository root.

```console
$ cabal run --verbose=0 capture-graph
```

Compare the result with [expected.stdout](expected.stdout).

More: [capture and recovery](../../docs/capture.md).
