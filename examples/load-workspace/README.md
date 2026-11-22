<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../assets/logo.svg" type="image/svg+xml">
    <img src="../../assets/logo.png" width="128" height="128" alt="libtmux for Haskell">
  </picture>
</div>
<!-- /libtmux-logo -->

# Preview a workspace and apply it

[Main.hs](Main.hs) parses two windows and prints their count. It creates a
private tmux daemon, applies the plan, and counts the resulting panes.

Run from the repository root.

```console
$ cabal run --verbose=0 load-workspace
```

See [workspace planning and recovery](../../docs/workspaces.md).

To run outside the repository, copy this README, [Main.hs](Main.hs) and the
[package manifest](libtmux-load-workspace.cabal) into a new directory.
Copy [cabal.project.vcs](cabal.project.vcs) there as `cabal.project`.
The project fetches both the core and companion packages. Run the same
command from that directory after `cabal update` has populated the index.
