# Using libtmux for Haskell

Capture a tmux server once, then use the records as ordinary Haskell. Start
with the [capture program](../README.md), then [capture and recovery](capture.md)
and the [API guide](api.md).

| Task | Guide |
| --- | --- |
| Add the source package to a Cabal application | [Installation](installation.md) |
| Capture, filter and traverse the object graph | [Observations and recovery](capture.md) |
| Inspect typed selections and check physical or contextual uniqueness | [Typed queries](query.md) |
| Rename captured targets and handle interrupted commands | [Mutations and recovery](mutations.md) |
| Share resources across independent Server scopes | [Shared Runtime](shared-runtime.md) |
| Test application predicates without tmux | [Validated offline fixtures](fixtures.md) |
| Reproduce capture measurements | [Performance](performance.md) |
| Parse IDs, validate geometry and admit a release | [Typed values](values.md) |
| Browse modules, declarations and source | [API documentation](api.md) |
| Decide whether the current package meets your needs | [Implementation status](status.md) |

For maintainers:

- [Behavior contracts](contracts/README.md): implementation scope, including
  operations that are not public APIs yet.
- [Native domain model ADR](decisions/0001-native-domain-model.md): physical
  graph, naming, lifecycle and public API decisions.
- [Contributing](../.github/CONTRIBUTING.md) and
  [testing](../.github/TESTING.md): setup and test authoring.
