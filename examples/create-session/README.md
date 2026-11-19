<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../docs/assets/logo.svg" type="image/svg+xml">
    <img src="../../docs/assets/logo-128.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Create a session, window and pane

[Main.hs](Main.hs) creates a session with a direct process argv, uses its actual
window and pane references, and checks the environment of the new session.
It adds a window and splits an explicit pane. It
links the new window at two indices, selects a pane, tiles the window and
unlinks the second index. It sends input to the split pane, waits for fresh text from the running process, checks
duplicate name rejection and removes its new targets.
It reads the detached graph after closing the Server scope.

Use the [private demonstration server](../../README.md), then run from the
repository root:

```console
$ cabal run --verbose=0 create-session -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

Compare with [expected.stdout](expected.stdout), then follow the README's
teardown commands. The [creation guide](../../docs/creation.md) explains
process modes, historical identities, deadlines and recovery.
