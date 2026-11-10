# Measure capture cost

The capture benchmark measures the public `capture` operation, including
response decoding, graph validation, stored indexes and forcing owned values.
Endpoint adoption, fixture construction, derived occurrence counting and
teardown stay outside that timing. Each sample uses the default two-second
capture timeout.

Build the optional benchmark after provisioning the selected Haskell tools
and dependencies:

```console
$ cabal build bench:capture --offline
```

Run the three workloads against a selected tmux binary. The output directory
must be new; it receives raw CSV samples, host context and a JSON summary:

```console
$ python3 bench/capture.py \
    --tmux "$(command -v tmux)" \
    --output .cache/capture-benchmark
```

Repeat `--tmux` to compare binaries in one sweep. The reference run uses the
support endpoints, 3.3a and 3.8. Benchmarks form a separate tier and do not run
in routine test loops or add intermediate releases to CI.

The [Haskell harness](../bench/Capture.hs) uses the public interface.
The [fixture driver](../bench/capture.py) owns a foreground daemon and tracks
every created pane with a pidfd. It verifies graph cardinalities and observes
owned exits before accepting a result. Medium and large cases link three
physical windows across sessions; every case also retains two appearances
of the initial window.

## Reference run

The [recorded samples](../bench/results/capture-2026-11-08.json) were measured
on 2026-11-08 with GHC 9.14.1, Cabal 3.18.2.0, the library's default `-O1`
build and one RTS capability. The shared Linux host used a four-core CPU quota
and an 8 GiB process-group memory limit. Setup and teardown completed for all
six cases.

| tmux | Sessions | Physical windows | Physical panes | Median capture | Maximum capture |
| --- | ---: | ---: | ---: | ---: | ---: |
| 3.3a | 1 | 3 | 6 | 3.1 ms | 5.5 ms |
| 3.3a | 5 | 25 | 75 | 10.5 ms | 12.3 ms |
| 3.3a | 15 | 80 | 250 | 41.4 ms | 49.7 ms |
| 3.8 | 1 | 3 | 6 | 4.7 ms | 5.2 ms |
| 3.8 | 5 | 25 | 75 | 11.7 ms | 12.8 ms |
| 3.8 | 15 | 80 | 250 | 28.3 ms | 29.8 ms |

Each row contains five samples, including the first capture in its Server
scope. Values are rounded up to a tenth of a millisecond. The JSON retains
exact elapsed and acquisition-interval nanoseconds, Haskell process CPU time,
cardinalities, source identities and host load. Haskell CPU time excludes
the daemon and command-client processes.

These measurements qualify the stated fixtures on this host. Allocations,
concurrent captures, active selection or geometry changes, long fields,
cancellation latency and other hosts remain separate qualification work.
Use the raw samples when comparing a change; a successful small sweep does
not establish a service-level latency guarantee.
