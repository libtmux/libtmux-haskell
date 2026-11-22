<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../assets/logo.svg" type="image/svg+xml">
    <img src="../../assets/logo.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Configure a session

[Main.hs](Main.hs) checks a local numeric option and registers a rename hook.
The hook records the rename in a user option. The program deletes its session
when it leaves the scope.

Run from the repository root.

```console
$ cabal run --verbose=0 configure-session
```

Compare with [expected.stdout](expected.stdout). Follow the
[options and hooks guide](../../docs/options.md) for scope, inheritance and
error handling.
