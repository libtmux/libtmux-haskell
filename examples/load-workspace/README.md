# Preview a workspace and apply it

[Main.hs](Main.hs) parses two windows and prints their count. It creates a
private tmux daemon, applies the plan, and counts the resulting panes.

Run from the repository root.

```console
$ cabal run --verbose=0 load-workspace
```

See [workspace planning and recovery](../../docs/workspaces.md).
