<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../docs/assets/logo.svg" type="image/svg+xml">
    <img src="../../docs/assets/logo-128.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Test a pane policy without tmux

[Main.hs](Main.hs) constructs a validated fixture and selects active panes by
width. Its repeated window link demonstrates the difference between physical
entities and contextual appearances. It opens no socket and starts no process.

Run from the repository root:

```console
$ cabal run --verbose=0 offline-graph
```

Compare the result with [expected.stdout](expected.stdout). The
[fixture guide](../../docs/fixtures.md) explains fixture origins and validation;
fixture references cannot target a live server. CI executes this program using
the installed public package and asserts its output.
