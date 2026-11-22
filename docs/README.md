# Using libtmux for Haskell

Capture a tmux server once, then use the records as ordinary Haskell. Start
with the [capture program](../README.md), then [capture and recovery](capture.md)
and the [API guide](api.md).

| Task | Guide |
| --- | --- |
| Add the source package to a Cabal application | [Installation](installation.md) |
| Capture, filter and traverse the object graph | [Observations and recovery](capture.md) |
| Inspect typed selections and check physical or contextual uniqueness | [Typed queries](query.md) |
| Create a session and operate on its returned references | [Session creation](creation.md) |
| Request absolute pane and window geometry | [Resizing](resizing.md) |
| Run a terminal application, send input and clean up its scope | [Owned programs](programs.md) |
| Transfer a named buffer and paste it to an explicit pane | [Paste buffers](buffers.md) |
| Read and change a scoped option or hook | [Options and hooks](options.md) |
| Check connected-daemon requirements and version refusals | [Capabilities](capabilities.md) |
| Watch a window or wait for pane state | [Control notifications](control.md) |
| Rename captured targets and handle interrupted commands | [Mutations and recovery](mutations.md) |
| Share resources across independent Server scopes | [Shared Runtime](shared-runtime.md) |
| Test application predicates without tmux | [Validated offline fixtures](fixtures.md) |
| Inspect a Haskell application’s tmux daemon from an agent | [MCP setup and discovery](agents.md) |
| Reproduce capture measurements | [Performance](performance.md) |
| Parse IDs, validate geometry and admit a release | [Typed values](values.md) |
| Browse modules, declarations and source | [API documentation](api.md) |
| Preview tmuxp YAML and apply it to a new session | [Workspace loader](workspaces.md) |
| Decide whether the current package meets your needs | [Implementation status](status.md) |

For maintainers:

- Planned native behavior and implementation evidence live in the repository's
  [behavior contracts](https://github.com/libtmux/libtmux-haskell/tree/master/docs/contracts).
- [Native domain model ADR](decisions/0001-native-domain-model.md): physical
  graph, naming, lifecycle and public API decisions.
- [Contributing](../.github/CONTRIBUTING.md) and
  [testing](../.github/TESTING.md): setup and test authoring.
- [Logo assets](../assets/README.md): SVG and PNG marks and kit provenance.
