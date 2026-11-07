# Using libtmux for Haskell

The public package currently provides typed tmux IDs, checked dimensions and
indices, and stable-release parsing. Start with the complete
[typed-value program](../examples/typed-values/Main.hs), then follow the
signatures in the [API guide](api.md).

| Task | Guide |
| --- | --- |
| Add the source package to a Cabal application | [Installation](installation.md) |
| Parse IDs, validate geometry and admit a release | [Typed values](values.md) |
| Browse modules, declarations and source | [API documentation](api.md) |
| Decide whether the current package meets your needs | [Implementation status](status.md) |

The [behavior contracts](contracts/README.md) describe the implementation
scope. They include operations that are not yet public APIs.

Repository setup and test authoring live in
[contributing](../.github/CONTRIBUTING.md) and
[testing](../.github/TESTING.md).
