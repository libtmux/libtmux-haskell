# capture_benchmark

Measures the public `capture` operation on small, medium and large tmux graphs.
Maintainers run it by hand; it is not part of CI.
[Performance](../../docs/performance.md) describes the workloads, what is
timed and the recorded reference run.

The driver builds the Cabal benchmark once. For each binary and size,
`bench/Capture.hs` creates the graph in `withOwnedServer` and times capture
after setup. The driver validates graph counts and records raw samples after
the scope closes. Use a new output directory.

```console
$ uv run scripts/capture_benchmark/capture_benchmark.py \
    --tmux "$(command -v tmux)" \
    --output .cache/capture-benchmark
```

Each case has 120 seconds for setup, samples and teardown. After a timeout
or nonzero exit, the driver saves the bytes captured from both streams.
Cabal and tool probes have their own [subprocess bounds](../bounded/README.md).

Read setup and case durations from the output:

```console
$ jq -r '.cases[] | [.version, .size, .setupSeconds, .caseSeconds] | @tsv' \
    .cache/capture-benchmark/result.json
```

The tests need neither tmux nor a Haskell build:

```console
$ uv run --locked --offline pytest scripts/capture_benchmark
```
