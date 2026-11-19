# Configure a session

[Main.hs](Main.hs) checks a local numeric option and registers a rename hook.
The hook records the rename in a user option. The program deletes its session
when it leaves the scope.

Start the [private demonstration server](../../README.md) and run from the
repository root.

```console
$ cabal run --verbose=0 configure-session -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

Compare with [expected.stdout](expected.stdout). Follow the
[options and hooks guide](../../docs/options.md) for scope, inheritance and
error handling.
