# Measure capture cost

The benchmark times the public `capture` operation.

- Included: response decoding, graph validation, stored indexes, forcing owned
  values.
- Excluded: endpoint adoption, fixture construction, occurrence counting,
  teardown.
- Each sample uses the default two-second capture timeout.

Run from a provisioned checkout. The driver builds the benchmark and runs
three workloads. It writes raw CSV samples, host context and a JSON summary
to a new output directory.

```console
$ uv run scripts/capture_benchmark/capture_benchmark.py \
    --tmux "$(command -v tmux)" \
    --output .cache/capture-benchmark
```

Repeat `--tmux` to compare binaries in one sweep. The reference run uses the
minimum supported tmux, 3.3a, and the newest release tested, 3.8. Benchmarks
stay out of routine tests.

- The [Haskell harness](../bench/Capture.hs) builds the graph using the public
  API inside `withOwnedServer`. The [driver](../scripts/capture_benchmark/capture_benchmark.py)
  checks each sample and records a case after the scope returns.
- Medium and large cases link three physical windows across sessions. Every
  case keeps two appearances of the initial window.

## Reference run

The [recorded samples](../bench/results/capture-2026-11-08.json) date from
2026-11-08: default `-O1` build, one RTS capability, a four-core CPU quota and
an 8 GiB memory limit on a shared Linux host. The file records the compiler
and Cabal versions. Its `harnessSha256` entry for `bench/capture.py` hashes the
fixture driver at its path then; the driver now lives at
[`scripts/capture_benchmark`](../scripts/capture_benchmark/capture_benchmark.py)
and has changed, so that hash does not match the current file. All six cases
completed setup and teardown.

| tmux | Sessions | Physical windows | Physical panes | Median capture | Maximum capture |
| --- | ---: | ---: | ---: | ---: | ---: |
| 3.3a | 1 | 3 | 6 | 3.1 ms | 5.5 ms |
| 3.3a | 5 | 25 | 75 | 10.5 ms | 12.3 ms |
| 3.3a | 15 | 80 | 250 | 41.4 ms | 49.7 ms |
| 3.8 | 1 | 3 | 6 | 4.7 ms | 5.2 ms |
| 3.8 | 5 | 25 | 75 | 11.7 ms | 12.8 ms |
| 3.8 | 15 | 80 | 250 | 28.3 ms | 29.8 ms |

- Each row has five samples, including the first capture in its Server scope.
- Values round up to a tenth of a millisecond.
- The JSON keeps exact elapsed and acquisition-interval nanoseconds, Haskell
  process CPU time (not the daemon or command clients), cardinalities, source
  identities and host load.

These numbers cover the fixtures above, on this host. Not measured: allocations,
concurrent captures, active selection or geometry changes, long fields,
cancellation latency, other hosts. Compare a change against the raw samples; a
small sweep is not a latency guarantee.
