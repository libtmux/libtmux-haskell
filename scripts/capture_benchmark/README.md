# capture_benchmark

Measures the public `capture` operation on small, medium and large tmux graphs.
Maintainers run it by hand; it is not part of CI.
[Performance](../../docs/performance.md) describes the workloads, what is
timed and the recorded reference run.

For each tmux binary and size, the driver starts an owned daemon, builds the
graph, runs the Haskell workload in `bench/Capture.hs` against it, checks every
sample against the graph it built, and confirms that the daemon and every
tracked pane exited. The output directory must be new.

```console
$ cabal build bench:capture --offline
```

```console
$ uv run scripts/capture_benchmark/capture_benchmark.py \
    --tmux "$(command -v tmux)" \
    --output .cache/capture-benchmark
```

The daemon fixture comes from `examples/capture-graph/run.py`, which still
starts tmux from the shell. It changes when the library can start and stop a
server ([#34](https://github.com/libtmux/libtmux-haskell/issues/34),
[#28](https://github.com/libtmux/libtmux-haskell/issues/28)).

The tests need neither tmux nor a Haskell build:

```console
$ uv run --locked --offline pytest scripts/capture_benchmark
```
