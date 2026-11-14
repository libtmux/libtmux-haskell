# Add the package to a Cabal application

Requirements:

- A current GHC and Cabal, within the bounds in the
  [package manifest](../libtmux-haskell.cabal).
- Linux x86_64; see [host requirements](#native-backend-host-requirements).
- tmux 3.3a or newer.
- To reproduce the tested toolchain, see
  [contributor setup](../.github/CONTRIBUTING.md#toolchain).

Add `libtmux-haskell` to your executable's dependencies and
[fetch the Git source](#fetch-the-source-from-git) with a `cabal.project`.
The [example package](../examples/capture-graph/libtmux-capture-graph.cabal) is
a complete starting point:

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
update the package index:

```console
$ cabal update
```

Start the [demo server](../README.md) from the README, then run:

```console
$ cabal run --verbose=0 capture-graph -- \
    "$LIBTMUX_DEMO_DIR/s" \
    "$(command -v tmux)"
```

- Enable
  [`OverloadedRecordDot`](https://downloads.haskell.org/ghc/latest/docs/users_guide/exts/overloaded_record_dot.html)
  in modules that read observation fields.
- No optics or effect framework is needed.
- The [capture guide](capture.md) covers the object graph, pure lookups and
  scope cleanup.

The API is experimental. The package provides observation and rename/title
operations. Creation, pane input and events remain under development.
Check [status](status.md) before choosing it for automation.

Browse the [manual](https://libtmux.org/en/haskell/) and
[`LibTmux.Server` API](https://libtmux.org/en/haskell/latest/reference/libtmux-server/)
for connection, capture and mutation operations.

## Fetch the source from Git

The package is not on Hackage yet, so Cabal fetches the release from Git. Use
this `cabal.project`:

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

The native backend needs:

- Linux x86_64.
- glibc 2.39 or newer, for `pidfd_spawn`.
- A kernel with compatible pidfd operations.
- Exclusive ownership of child reaping.

A missing host operation fails before launch. Pure scalar construction and
lookup do not need them. See the
[process host contract](contracts/process.md#launch-and-host-requirements).
