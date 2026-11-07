# Implementation status

Use the current package for typed input values. The public library cannot
yet observe or mutate a tmux server.

| Component | Available to consumers |
| --- | --- |
| Entity ID parsing/rendering | Yes, through `LibTmux.Id` |
| Checked dimensions and indices | Yes, through `LibTmux.Value` |
| Stable-release parsing and minimum-version admission | Yes, through `LibTmux.Version` |
| Client, complete captures and generation-bound references | In progress |
| Typed query evaluation and commands | Not implemented |
| Control events, streams and cancellation API | Not implemented |
| Workspace library/CLI | Planned as a separate Cabal package using the core |
| MCP integration | Excluded from this port |

The internal graph, socket pin and child-ownership experiments have separate
tests. Their passing results do not establish a public automation interface.
The [behavior inventory](contracts/README.md) records the intended scope.

## Package policy

The core favors GHC boot libraries and ordinary `IO`. Additional dependencies
need a concrete requirement; JSON/YAML loading and command-line concerns
belong in the workspace package. MCP is outside this port's scope. See the
[package and dependency policy](../.github/CONTRIBUTING.md#package-and-dependency-policy).

## Compatibility evidence

CI uses GHC 9.14.1, GHC2024 and Cabal 3.18.2.0 on Linux x86_64. Its current
integration subset exercises owned fixtures, scalar framing and private
socket pins on exact tmux releases 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a,
3.6b, 3.7, 3.7a, 3.7b, 3.7c and 3.8.

The [workflow](../.github/workflows/ci.yml) and
[test guide](../.github/TESTING.md) describe those checks. This is evidence
for the implemented subset, not complete tmux API compatibility.

No package-performance benchmark results are published. Test and private
probe durations do not measure an installed public transport.
