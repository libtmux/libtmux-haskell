<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../docs/assets/logo.svg" type="image/svg+xml">
    <img src="../../docs/assets/logo-128.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Capture a tmux graph

[Main.hs](Main.hs) captures an existing server, closes its handle, then filters
detached panes and follows session-to-window links. One physical window linked
at two indices produces two contextual appearances.

Create the [README's private demonstration server](../../README.md), then run
from the repository root:

```console
$ cabal run --verbose=0 capture-graph -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

Compare the result with [expected.stdout](expected.stdout), then follow the
README's teardown commands. The program releases its own handle; it does not
stop the server you supplied.

Read the [capture and recovery guide](../../docs/capture.md) for lookup errors,
connection-scoped references and cancellation. CI executes the installed program
against an owned fixture and verifies output and process cleanup.
