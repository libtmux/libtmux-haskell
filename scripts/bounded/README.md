# bounded

Runs the support scripts' external commands under a time limit. When the limit
passes, or the script is interrupted, it kills the command's whole process
group, so a `ghc` below a `cabal` or a tmux server below an example runner
cannot outlive the limit. `subprocess.run(timeout=)` kills only the direct
child. Every script that starts `cabal`, `git`, `ghc` or a built program
imports it, and a test fails when one calls `subprocess` directly.

| Name | What it does |
| --- | --- |
| `run(args, timeout=...)` | Like `subprocess.run`, in a new process group. |
| `output(args, timeout=...)` | Returns the text of a command that must succeed. |
| `QUICK` | 120 s, for `git`, `cabal sdist`, index updates, version queries and built programs. |
| `BUILD` | 600 s, for `cabal build`, `cabal haddock` and `ghc` compilations. |

## What the limits sit above

The slowest script step in the 25 most recent successful `ci.yml` runs on
`master` took 82 s (run 43735981925, "Isolated source-archive consumer", which
includes every build that script runs), measured on 2026-11-16. No single
command in a step is slower than the step, so `QUICK` is above every command and
`BUILD` is above the longest build by a factor of seven. Rerun the measurement
to refresh it:

```console
$ gh run list \
    --repo libtmux/libtmux-haskell \
    --workflow ci.yml \
    --branch master \
    --status success \
    --limit 25 \
    --json databaseId \
    --jq '.[].databaseId' \
  | xargs -I{} gh run view {} \
    --repo libtmux/libtmux-haskell \
    --json databaseId,jobs \
    --jq '.databaseId as $run | .jobs[] | select(.name == "checks") | .steps[] | select(.name | test("consumer|Hackage archives|type contracts|example command")) | [((.completedAt | fromdate) - (.startedAt | fromdate)), $run, .name] | @tsv' \
  | sort -rn \
  | head -4
```

The tests start a command that starts a child and check that both die:

```console
$ uv run --locked --offline pytest scripts/bounded
```
