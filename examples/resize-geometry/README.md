# Resize panes and windows

[Main.hs](Main.hs) creates a disposable session with three panes, requests
absolute widths, heights and combined sizes, and prints fresh geometry. It
checks an invalid size and preserves the original windows and sessions.

Start the [private demonstration server](../../README.md), then run from the
repository root:

```console
$ cabal run --verbose=0 resize-geometry -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

Compare with [expected.stdout](expected.stdout). The program removes its new
session; follow the README's teardown for the borrowed server. The
[resizing guide](../../docs/resizing.md) explains validation, native layout
constraints and recovery.
