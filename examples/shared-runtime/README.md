<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../docs/assets/logo.svg" type="image/svg+xml">
    <img src="../../docs/assets/logo-128.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Share a Runtime across handles

[Main.hs](Main.hs) opens independent Server scopes under one Runtime. It closes
one handle and verifies that the other can still capture.
Detached observations remain usable after their handle closes.

Create the [README's private demonstration server](../../README.md), then run
from the repository root:

```console
$ cabal run --verbose=0 shared-runtime -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

Compare the result with [expected.stdout](expected.stdout), then follow the
README's teardown commands. The program releases library resources without
stopping the supplied server.

The [shared Runtime guide](../../docs/shared-runtime.md) explains shutdown,
retained owners and recovery. CI executes the installed program and checks
output and owned fixture cleanup.
