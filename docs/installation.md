# Add the package to a Cabal application

The [package manifest](../libtmux-haskell.cabal) declares the language edition
and dependency compatibility bounds. Use a current GHC and Cabal that satisfy
those bounds. The native backend requires Linux x86_64; see its
[host requirements](#native-backend-host-requirements).
[Contributor setup](../.github/CONTRIBUTING.md#toolchain) links the CI pins for
reproducing the tested configuration.

Add `libtmux-haskell` from
[Hackage](https://hackage.haskell.org/package/libtmux-haskell) to the
executable's dependencies. The
[example package](../examples/capture-graph/libtmux-capture-graph.cabal) is a
complete starting point:

<!-- example-package: capture-graph -->
```cabal
cabal-version: 3.18
name: libtmux-capture-graph
version: 0.0.0
build-type: Simple
license: MIT
extra-doc-files: README.md

executable capture-graph
  main-is: Main.hs
  default-language: GHC2024
  ghc-options: -Wall -Werror
  build-depends:
    base >=4.22 && <4.23,
    filepath >=1.5.4 && <1.6,
    libtmux-haskell ^>=0.0.1.0,
    text >=2.1.3 && <2.2
```

Save [Main.hs](../examples/capture-graph/Main.hs) beside the package file, then
download the package index before the first build:

```console
$ cabal update
```

Use the [private demonstration server](../README.md) from the README, then
run the Haskell executable:

```console
$ cabal run --verbose=0 capture-graph -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

The [capture guide](capture.md) explains the object graph, pure lookups and
scope cleanup. Its owned fixture creates a repeatable server for the
[README example](../README.md). Enable
[`OverloadedRecordDot`](https://downloads.haskell.org/ghc/9.14.1/docs/users_guide/exts/overloaded_record_dot.html)
in application
modules using observation fields. No optics or effect framework is required.

The API is experimental. The package provides observation and rename/title
operations. Creation, pane input and events remain under development.
Check [status](status.md) before choosing it for automation.

Browse the [manual](https://libtmux.org/en/haskell/) and
[`LibTmux.Server` API](https://libtmux.org/en/haskell/latest/reference/libtmux-server/)
for connection, capture and mutation operations.

## Use the release source directly

To use the same release from Git instead of the package index, use this
`cabal.project`:

<!-- example-project: capture-graph -->
```cabal
packages: .
index-state: 2026-11-06T00:00:00Z

source-repository-package
  type: git
  location: https://github.com/libtmux/libtmux-haskell
  tag: v0.0.1.0
```

## Native backend host requirements

The native backend targets Linux x86_64 with glibc 2.39 or newer
for `pidfd_spawn`, compatible kernel pidfd operations, and exclusive child
reaping ownership. Missing host operations fail before launch. This is
separate from pure scalar construction and lookup. See the
[process host contract](contracts/process.md#launch-and-host-requirements).
