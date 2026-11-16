<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../docs/assets/logo.svg" type="image/svg+xml">
    <img src="../../docs/assets/logo-128.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Own a private server

[Main.hs](Main.hs) starts a tmux server of its own with `withOwnedServer`,
creates a session in it, captures the graph and leaves the server stopped when
the scope closes. It takes no arguments and needs no running server.

Put a tmux 3.3a or newer executable on `PATH`, then run from the repository
root:

```console
$ cabal run --verbose=0 owned-server
```

Compare with [expected.stdout](expected.stdout). The
[lifecycle guide](../../docs/lifecycle.md) explains ownership, cancellation and
`killServer`.
