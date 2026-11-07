# Typed tmux values

[Run the complete example](../examples/typed-values/Main.hs) from a checkout:

```console
$ cabal run --verbose=0 typed-values
```

Program output:

<!-- example-output: typed-values -->
```text
("3.3","@17",120)
```

The program parses supplied text and constructs values. Its only `IO` prints
the result; it neither inspects an installed tmux binary nor contacts a server.

## IDs and indices describe different things

[`SessionId`](../src/LibTmux/Id.hs), [`WindowId`](../src/LibTmux/Id.hs) and [`PaneId`](../src/LibTmux/Id.hs) are distinct types. Their parsers require
the corresponding `$`, `@` or `%` prefix, canonical decimal spelling and the
native unsigned 32-bit range. Leading zeroes and whitespace are rejected.
Use the rendering functions when producing external target text.

An ID alone carries no endpoint or server lifetime. Parsing `@17` does not
prove that a window exists. The ID API does not yet provide generation-bound
references for external operations.

[`WindowIndex`](../src/LibTmux/Value.hs) identifies a window link's position within a session.
[`PaneIndex`](../src/LibTmux/Value.hs) identifies a pane's position within its window. Neither is an
entity ID. A physical window may have several links, including multiple
indices in the same session.

## Validate values where they enter the program

Constructors return `Either`: dimensions must be positive; indices must be
nonnegative. Their numeric accessors return `Integer`, so reading a value
does not narrow it to a machine-sized integer.

[`mkDimension`](../src/LibTmux/Value.hs) checks the mathematical domain. A particular tmux command can
impose a smaller numeric range; successful construction does not establish
that command's capability or maximum.

## Release admission has a limited meaning

[`parseVersion`](../src/LibTmux/Version.hs) accepts stable releases and the output format of `tmux -V`,
including one final LF. Development versions and trailing data are rejected.
[`requireSupported`](../src/LibTmux/Version.hs) rejects versions older than plain tmux 3.3.

These functions validate the supplied release identity. They do not inspect
the host or qualify all features of that release. See
[implementation status](status.md) for the boundary between the exposed
package and the transport work.

The [API guide](api.md) links the public modules and their error types.
