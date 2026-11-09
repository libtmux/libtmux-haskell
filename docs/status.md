# Implementation status

Use the current source for detached observations and typed input values.
The package is unpublished. Public mutation commands are not implemented.

| Component | Available to consumers |
| --- | --- |
| Entity ID parsing/rendering | Yes, through `LibTmux.Id` |
| Checked dimensions and indices | Yes, through `LibTmux.Value` |
| Stable-release parsing and supported-range admission | Yes, through `LibTmux.Version` |
| Server, complete captures and generation-bound references | Implemented through `LibTmux.Server` and `LibTmux.Snapshot` |
| Bounded scope cleanup and correlated recovery | Implemented; keep exception context when catching failures |
| Validated offline fixtures | Implemented through `LibTmux.Snapshot.Fixture` |
| Shared Runtime ownership | In progress |
| Typed query evaluation and commands | Not implemented |
| Control events, streams and cancellation API | Not implemented |
| Workspace library/CLI | Planned as a separate Cabal package using the core |
| MCP integration | Excluded from this port |

The [capture program](../examples/capture-graph/Main.hs) exercises the public
interface. Query, mutation, event and workspace contracts remain separate
qualification work.
The [behavior inventory](contracts/README.md) records the intended scope.

## Package policy

The core favors GHC boot libraries and ordinary `IO`. Additional dependencies
need a concrete requirement; JSON/YAML loading and command-line concerns
belong in the workspace package. MCP is outside this port's scope. See the
[package and dependency policy](../.github/CONTRIBUTING.md#package-and-dependency-policy).

## Compatibility evidence

CI uses GHC 9.14.1, GHC2024 and Cabal 3.18.2.0 on Linux x86_64. Its current
integration subset exercises owned fixtures, scalar framing, private socket
pins, public capture, scope recovery and process ownership with one and two
RTS capabilities on exact tmux
releases 3.3a and 3.8. The supported range includes all intermediate releases;
CI tests its endpoints.

The [workflow](../.github/workflows/ci.yml) and
[test guide](../.github/TESTING.md) describe those checks. This is evidence
for the implemented subset, not complete tmux API compatibility.

No package-performance benchmark results are published. Test and private
probe durations do not measure an installed public transport.
