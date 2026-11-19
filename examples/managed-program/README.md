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

Put tmux 3.8 or newer on `PATH`,
Linux 6.9 process-group pidfds and the required Bash builtins, then run from the
repository root:

```console
$ cabal run --verbose=0 managed-program
```

Compare with [expected.stdout](expected.stdout), then follow the README's daemon
teardown commands. The [program guide](../../docs/programs.md) describes scope
ownership, bounds, cancellation, startup requirements and recovery.
