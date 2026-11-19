# Refresh the option and hook catalogue

This generator reads `options-table.c` from the exact tmux commits and digests
in [sources.json](sources.json). The C preprocessor expands tmux's hook macros.
The script reads the resulting names, types, scopes, array flags and choices.
It keeps removal and type changes across releases, so a daemon's catalogue
matches its release.

Pass a tmux git checkout containing the recorded commits. The generator uses
the local objects and a C preprocessor.

```console
$ uv run scripts/generate_options/generate_options.py \
    --tmux "$TMUX_SOURCE"
```

CI runs the same command with `--check` and fails on a changed source digest
or stale Haskell output. When adding a release, review its table and
conditional definitions and update the pinned git commit and source digest
before regenerating.
