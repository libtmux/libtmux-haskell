# ci_tmux

Builds and caches the exact tmux releases CI uses. CI runs it; maintainers
rarely need to. [tmux-releases.json](../../.github/tmux-releases.json) pins each
release's source archive by SHA-256.

| Command | What it does |
| --- | --- |
| `matrix` | Writes the pinned releases to `$GITHUB_OUTPUT` for the job matrix. |
| `plan VERSION` | Writes the cache key, prefix and binary path to `$GITHUB_OUTPUT`. |
| `prepare VERSION` | Validates the cached build, or rebuilds it from the verified archive. |

```console
$ uv run scripts/ci_tmux/ci_tmux.py matrix
```

A cached executable is reused only if its record, SHA-256 and reported version
match, and its cache path holds no symlink. The cache key includes this
script's hash, so changing the script rebuilds every cached tmux once.

This logic is shared with other ports, which carry their own copies; it moves
to shared tooling under [libtmux-haskell#38](https://github.com/libtmux/libtmux-haskell/issues/38).

The tests copy the executable named by `CI_TEST_TMUX` and run `tmux -V` on it.
They start no server:

```console
$ CI_TEST_TMUX="$(command -v tmux)" uv run --locked --offline pytest scripts/ci_tmux
```
