<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../assets/logo.svg" type="image/svg+xml">
    <img src="../../assets/logo.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Create a session, window and pane

[Main.hs](Main.hs) starts a private daemon and uses returned references to
create, link and select its windows and panes. It sends input to the split
pane, waits for fresh text, then removes its targets and retires the daemon.
The detached graph remains available after retirement.

Run from the repository root.

```console
$ cabal run --verbose=0 create-session
```

Compare with [expected.stdout](expected.stdout).
[Creation guide](../../docs/creation.md)
