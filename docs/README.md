# Using libtmux for Haskell

Capture an existing tmux endpoint, then process detached records with ordinary
Haskell. Start with the complete [capture program](../README.md), then read
[observation and recovery semantics](capture.md) and the [API guide](api.md).

| Task | Guide |
| --- | --- |
| Add the source package to a Cabal application | [Installation](installation.md) |
| Capture, filter and traverse the object graph | [Observations and recovery](capture.md) |
| Inspect typed selections and check physical or contextual uniqueness | [Typed queries](query.md) |
| Share resources across independent Server scopes | [Shared Runtime](shared-runtime.md) |
| Test application predicates without tmux | [Validated offline fixtures](fixtures.md) |
| Reproduce capture measurements | [Performance](performance.md) |
| Parse IDs, validate geometry and admit a release | [Typed values](values.md) |
| Browse modules, declarations and source | [API documentation](api.md) |
| Decide whether the current package meets your needs | [Implementation status](status.md) |

The [behavior contracts](contracts/README.md) describe the implementation
scope. They include operations that are not yet public APIs.

The accepted [native domain model ADR](decisions/0001-native-domain-model.md)
records the physical graph, naming, lifecycle and public API decisions.

Repository setup and test authoring live in
[contributing](../.github/CONTRIBUTING.md) and
[testing](../.github/TESTING.md).
