<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../docs/assets/logo.svg" type="image/svg+xml">
    <img src="../../docs/assets/logo-128.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Create a detached session

[Main.hs](Main.hs) creates a session with a direct process argv, uses its actual
window and pane references, and refreshes the object graph. It checks duplicate
name rejection and reads the detached values after closing the Server scope.

The program leaves its new session running. Use the
[private demonstration server](../../README.md), then run from the repository
root:

```console
$ cabal run --verbose=0 create-session -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

Compare with [expected.stdout](expected.stdout), then follow the README's
teardown commands. The [creation guide](../../docs/creation.md) explains
process modes, historical identities, deadlines and recovery.
