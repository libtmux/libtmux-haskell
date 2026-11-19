# Measure capture cost

The benchmark times serial calls to `capture`, including response decoding,
graph validation, indexes and forcing the returned values. Each call uses
the default two-second timeout. Daemon setup, graph construction, occurrence
counting and teardown run outside the measured interval.

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

The November 19 run used an `-O1` build, one RTS capability, a four-core CPU
quota and an 8 GiB memory cap on a shared Linux host. Every case completed
with its private daemon retired. Each row includes five samples, starting
with the first capture in the scope.
[Raw samples and source hashes](../bench/results/capture-2026-11-19.json)

| tmux | Sessions | Physical windows | Physical panes | Median capture | Maximum capture |
| --- | ---: | ---: | ---: | ---: | ---: |
| 3.3a | 1 | 3 | 6 | 7.7 ms | 14.3 ms |
| 3.3a | 5 | 25 | 75 | 22.5 ms | 32.1 ms |
| 3.3a | 15 | 80 | 250 | 52.6 ms | 56.3 ms |
| 3.8 | 1 | 3 | 6 | 8.0 ms | 20.2 ms |
| 3.8 | 5 | 25 | 75 | 27.2 ms | 29.7 ms |
| 3.8 | 15 | 80 | 250 | 60.7 ms | 65.2 ms |

A second run of the same executable produced case medians from 3.5 ms to
40.2 ms. The JSON records elapsed and acquisition-interval nanoseconds,
Haskell process CPU time, cardinalities, binary hashes and host state. Use
those fields to compare measurements across runs.
[November 8 historical receipt](../bench/results/capture-2026-11-08.json)
