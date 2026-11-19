# bounded

Runs the support scripts' external commands in separate Linux process groups.
On a timeout, interruption or checked failure, it signals the processes still
in the command's group. A pidfd reports exit while the unreaped leader still
reserves the group ID. Timed-out commands report any captured output bytes.
A test checks that scripts use this wrapper to launch external commands.

| Name | What it does |
| --- | --- |
| `run(args, timeout=...)` | Like `subprocess.run`, in a new process group. |
| `output(args, timeout=...)` | Returns the text of a command that must succeed. |
| `QUICK` | 120 s, for `git`, `cabal sdist`, index updates, version queries, one `ghc -fno-code` check and built programs. |
| `BUILD` | 600 s, for `cabal build` and `cabal haddock`. |

## What the limits sit above

CI runs each script as one step. The slowest run of each step among the 25 most
recent successful `ci.yml` runs on `master`, measured on 2026-11-16:

| Step | Seconds | Run |
| --- | --- | --- |
| Isolated source-archive consumer (`check_sdist`) | 82 | 43735981925 |
| Prepare checked Hackage archives (`release prepare`) | 14 | 43728718382 |
| Documented example command (`check_docs --run`) | 10 | 43781053429 |
| Public type contracts (`check_types`) | 9 | 43781053429 |

No command is slower than its step, and the 82 s step includes every build in
the script. `QUICK` is above every command, and `BUILD` is above the longest
build by a factor of seven. Rerun the measurement to refresh the table:

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
  | awk -F'\t' '!seen[$3]++'
```

The tests start a command that starts a child and check that both die:

```console
$ uv run --locked --offline pytest scripts/bounded
```
