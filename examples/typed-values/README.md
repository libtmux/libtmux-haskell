<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../docs/assets/logo.svg" type="image/svg+xml">
    <img src="../../docs/assets/logo-128.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Parse tmux values

[Main.hs](Main.hs) parses a window ID and supported tmux release, constructs a
checked dimension and prints their values. It opens no socket and starts no
process.

Run from the repository root:

```console
$ cabal run --verbose=0 typed-values
```

Compare the result with [expected.stdout](expected.stdout). The
[value guide](../../docs/values.md) explains checked construction and error
results. CI executes this program using the installed public package and
asserts its output.
