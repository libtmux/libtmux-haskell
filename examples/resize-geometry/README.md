<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../assets/logo.svg" type="image/svg+xml">
    <img src="../../assets/logo.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Resize panes and windows

[Main.hs](Main.hs) creates a disposable session with three panes, requests
absolute widths, heights and combined sizes, and prints fresh geometry. It
checks an invalid size and preserves the original windows and sessions.

Run from the repository root.

```console
$ cabal run --verbose=0 resize-geometry
```

Compare with [expected.stdout](expected.stdout). The program removes its new
session before the daemon retires. The
[resizing guide](../../docs/resizing.md) explains validation, native layout
constraints and recovery.
