<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../assets/logo.svg" type="image/svg+xml">
    <img src="../../assets/logo.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Transfer and paste a named buffer

The [program](Main.hs) round-trips binary bytes through a named tmux buffer,
replaces its contents and pastes text to its own pane. The pane disables
terminal echo so the wait observes the application's output.

Run from the repository root.

```console
$ cabal run --verbose=0 paste-buffer
```

Compare the result with [expected.stdout](expected.stdout). Closing the private daemon removes the example's named buffer.
