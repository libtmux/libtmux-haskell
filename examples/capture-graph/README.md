<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../docs/assets/logo.svg" type="image/svg+xml">
    <img src="../../docs/assets/logo-128.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Capture a tmux graph

[Main.hs](Main.hs) captures a server once, closes the handle, then reads the
detached result with [`withServer`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-withserver/) and
[`capture`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-capture/).

- Filters panes by width.
- Follows session-to-window links.
- Reports one window linked at two indices as two appearances.

Start the [README's demo server](../../README.md), then run from the
repository root:

```console
$ cabal run --verbose=0 capture-graph -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

Expected output: [expected.stdout](expected.stdout). Then run the README's
cleanup commands; the program leaves your server running.

More: [capture and recovery](../../docs/capture.md).
