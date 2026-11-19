<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../docs/assets/logo.svg" type="image/svg+xml">
    <img src="../../docs/assets/logo-128.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Own a terminal application

[Main.hs](Main.hs) runs literal argv, drives an interactive application, cancels
and retries an observation, and bounds an owning run. It checks exit status,
rendered output and preservation of the borrowed session and panes.

Run from the repository root with tmux 3.8 or newer on `PATH`, Linux 6.9
process-group pidfds and the Bash builtins described in the program guide.

```console
$ cabal run --verbose=0 managed-program
```

The example retires its private daemon automatically.
[Expected output](expected.stdout) · [Program guide](../../docs/programs.md)
