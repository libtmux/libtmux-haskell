# Observe a window rename

[Main.hs](Main.hs) creates a session, opens a bounded control stream,
renames its window and prints the matching event.

Run from the repository root.

```console
$ cabal run --verbose=0 watch-window
```

Compare with [expected.stdout](expected.stdout). The program retires the
control client before removing its session. See [control notifications](../../docs/control.md)
for queue limits and outcomes.
