# Implementation status

The API is experimental. Start from the public operations and the tested
configuration below.

| Component | Available to consumers |
| --- | --- |
| Entity ID parsing/rendering | Yes, through `LibTmux.Id` |
| Checked dimensions and indices | Yes, through `LibTmux.Value` |
| Release parsing, ordering and minimum-version admission | Yes, through `LibTmux.Version` |
| Server, complete captures and generation-bound references | Implemented through `LibTmux.Server` and `LibTmux.Snapshot` |
| Bounded scope cleanup and correlated recovery | Implemented; keep exception context when catching failures |
| Validated offline fixtures | Implemented through `LibTmux.Snapshot.Fixture` |
| Shared Runtime ownership | Implemented through `withRuntime` and `withServerIn`; see [the complete program](shared-runtime.md) |
| Typed predicates, relationships, ordering and cardinality | Implemented through `LibTmux.Query`; see [the complete program](query.md) |
| Session/window rename and pane title | Implemented through `LibTmux.Server`; see [the complete program](mutations.md) |
| Detached session creation on an existing daemon | Implemented through `LibTmux.Server` and `LibTmux.Creation`; see [the complete program](creation.md) |
| Window creation and exact contextual pane splits | Implemented through `createWindow`, `splitPane` and `WindowSlot`; see [the complete program](creation.md) |
| Remove a session, window or pane | Implemented through `LibTmux.Server`; see [target removal](creation.md#remove-a-target) |
| Input to any pane on the selected daemon | Implemented with `sendKeys`; see [pane input](mutations.md#send-input-to-a-pane) |
| Bounded visible and history text | Implemented with `capturePane`; see [pane capture](mutations.md#read-pane-text) |
| Presence and baseline-qualified waits on pane text | Implemented with `waitForText`; see [text waits](mutations.md#wait-for-pane-text) |
| Scoped terminal applications, input, rendered output and leader exit | Initial Linux slice through `LibTmux.Program`; [requirements and limits](programs.md) |
| Contextual links, selection and named layouts | Implemented through `WindowSlot`; see [window links and focus](creation.md#link-select-and-arrange-windows) |
| Named global and session environment entries | Implemented through `getEnvironment`, `setEnvironment`, `markEnvironmentRemoved` and `unsetEnvironment` |
| Named binary buffers and explicit pane paste | Implemented through `loadBuffer`, `readBuffer` and `pasteBuffer`; see [paste buffers](buffers.md) |
| Absolute pane/window width, height or both | Implemented through `resizePane` and `resizeWindow`; see [resizing](resizing.md). Other resize modes remain open. |
| Built-in options and hooks by daemon release | Implemented through `LibTmux.Options`; see [options and hooks](options.md) |
| Scoped scalar settings and built-in hooks | `readOption`, `setOption`, `readHook` and `setHook`; see [scope and values](options.md#select-a-store) |
| Start and retire a private daemon | `withOwnedServer`; see [server scopes](capture.md#open-a-server) |
| Explicit daemon retirement | `killServer`; see [generation checks](capture.md#retire-a-server-early) |
| Query interchange and backend optimization | Not implemented |
| Bounded control notifications and optional pane output records | `withControl`; see [control scope](control.md) |
| Agent discovery and pane inspection | `libtmux-mcp` adapter; see [MCP setup](agents.md) |

The [capture program](../examples/capture-graph/Main.hs) exercises the public
interface. Additional commands, interchange and event contracts remain separate
qualification work.
The repository's [contract notes](https://github.com/libtmux/libtmux-haskell/tree/master/docs/contracts)
record the remaining native operations.

## Package policy

The core favors GHC boot libraries and ordinary `IO`. Additional dependencies
need a concrete requirement. See the
[package and dependency policy](../.github/CONTRIBUTING.md#package-and-dependency-policy).

## Tested configurations

- CI runs the [recorded toolchain](../.tool-versions) on Linux x86_64, with one
  and two RTS capabilities.
- It runs tmux 3.3a, the minimum, and 3.8, the newest release tested. Other
  releases from 3.3a onward are admitted but not run, and releases after 3.8
  are untested.
- It exercises owned fixtures, scalar framing, socket pins, public capture and
  mutations, scope recovery and process ownership.
- That covers the implemented subset, not the whole tmux API.

See the [workflow](../.github/workflows/ci.yml) and
[test guide](../.github/TESTING.md).

[Performance](performance.md) measures capture on small, medium and large
graphs on both endpoints. Not measured yet: allocation, concurrency and
cancellation latency.
