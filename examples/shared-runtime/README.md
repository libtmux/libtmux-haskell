<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../docs/assets/logo.svg" type="image/svg+xml">
    <img src="../../docs/assets/logo-128.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Share a Runtime across handles

[Main.hs](Main.hs) opens independent Server scopes under one
[`withRuntime`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-withruntime/) with
[`withServerIn`](https://libtmux.org/en/haskell/latest/reference/libtmux-server-v-withserverin/).

- Closes one handle; the other still captures.
- Detached observations stay usable after their handle closes.

Run from the repository root.

```console
$ cabal run --verbose=0 shared-runtime
```

Expected output: [expected.stdout](expected.stdout). Then run the README's
cleanup commands; the program leaves your server running.

More: [shared Runtime](../../docs/shared-runtime.md).
