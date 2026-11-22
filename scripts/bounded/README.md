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

## Hosted timings

Each CI step can run several individually bounded commands. These step times
come from the [bounded-script check on November 19](https://github.com/libtmux/libtmux-haskell/actions/runs/44483048346).

| Step | Seconds |
| --- | ---: |
| Isolated source-archive consumer (`check_sdist`) | 87 |
| Prepare checked Hackage archives (`release prepare`) | 13 |
| Documented example command (`check_docs --run`) | 17 |
| Public type contracts (`check_types`) | 8 |

Read the longest step times across recent successful master runs with `gh`.

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
$ uv run --project scripts --locked --offline pytest scripts/bounded
```
