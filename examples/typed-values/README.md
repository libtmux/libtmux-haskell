<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../docs/assets/logo.svg" type="image/svg+xml">
    <img src="../../docs/assets/logo-128.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Parse tmux values

[Main.hs](Main.hs) parses a window ID with
[`parseWindowId`](https://libtmux.org/en/haskell/latest/reference/libtmux-id-v-parsewindowid/) and a tmux release with
[`parseVersion`](https://libtmux.org/en/haskell/latest/reference/libtmux-version-v-parseversion/), builds a checked dimension
with [`mkDimension`](https://libtmux.org/en/haskell/latest/reference/libtmux-value-v-mkdimension/), and prints all three.
It opens no socket and starts no process.

Run from the repository root:

```console
$ cabal run --verbose=0 typed-values
```

Expected output: [expected.stdout](expected.stdout).

More: [typed values](../../docs/values.md).
