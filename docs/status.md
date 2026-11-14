# Implementation status

Use the current source for detached observations and typed input values.
The API is experimental. Public mutations currently cover session/window
rename and pane titles, with generation checks and correlated recovery.

| Component | Available to consumers |
| --- | --- |
| Entity ID parsing/rendering | Yes, through `LibTmux.Id` |
| Checked dimensions and indices | Yes, through `LibTmux.Value` |
| Stable-release parsing and supported-range admission | Yes, through `LibTmux.Version` |
| Server, complete captures and generation-bound references | Implemented through `LibTmux.Server` and `LibTmux.Snapshot` |
| Bounded scope cleanup and correlated recovery | Implemented; keep exception context when catching failures |
| Validated offline fixtures | Implemented through `LibTmux.Snapshot.Fixture` |
| Shared Runtime ownership | Implemented through `withRuntime` and `withServerIn`; see [the complete program](shared-runtime.md) |
| Typed predicates, relationships, ordering and cardinality | Implemented through `LibTmux.Query`; see [the complete program](query.md) |
| Session/window rename and pane title | Implemented through `LibTmux.Server`; see [the complete program](mutations.md) |
| Creation, pane input and contextual window operations | Not implemented |
| Query interchange and backend optimization | Not implemented |
| Control events, streams and cancellation API | Not implemented |

The [capture program](../examples/capture-graph/Main.hs) exercises the public
interface. Additional commands, interchange and event contracts remain separate
qualification work.
The [behavior inventory](contracts/README.md) records the intended scope.

## Package policy

The core favors GHC boot libraries and ordinary `IO`. Additional dependencies
need a concrete requirement. See the
[package and dependency policy](../.github/CONTRIBUTING.md#package-and-dependency-policy).

## Compatibility evidence

CI uses the [recorded toolchain](../.tool-versions) on Linux x86_64. Its current
integration subset exercises owned fixtures, scalar framing, private socket
pins, public capture/mutations, scope recovery and process ownership with one and two
RTS capabilities on exact tmux
releases 3.3a and 3.8. The supported range includes all intermediate releases;
CI tests its endpoints.

The [workflow](../.github/workflows/ci.yml) and
[test guide](../.github/TESTING.md) describe those checks. This is evidence
for the implemented subset, not complete tmux API compatibility.

A [capture baseline](performance.md) records small, medium and large owned
graphs on both tmux endpoints. It measures the public API with raw samples
and host context. Allocation, concurrency and cancellation-latency
qualification remain open.
