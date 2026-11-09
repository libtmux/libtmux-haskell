# Add the package to a Cabal application

Use GHC 9.14.1, GHC2024 and Cabal 3.18.2.0. The package targets this compiler
series on Linux x86_64 only. Install the pinned tools through the
[contributor setup](../.github/CONTRIBUTING.md#toolchain) if needed.

The public observation work currently lives on the development branch below.
It is a moving input while its draft PR is under review; use an immutable
commit when selecting a reviewed build for an application:

<!-- example-project: capture-graph -->
```cabal
packages: .
index-state: 2026-11-06T00:00:00Z

source-repository-package
  type: git
  location: https://github.com/libtmux/libtmux-haskell
  tag: feat/capture-recovery
```

Add the library to the executable's dependencies. The
[example package](../examples/capture-graph/libtmux-capture-graph.cabal) is a
complete starting point:

<!-- example-package: capture-graph -->
```cabal
cabal-version: 3.18
name: libtmux-capture-graph
version: 0.0.0
build-type: Simple
license: MIT

executable capture-graph
  main-is: Main.hs
  default-language: GHC2024
  ghc-options: -Wall -Werror
  build-depends:
    base >=4.22 && <4.23,
    filepath >=1.5.4 && <1.6,
    libtmux-haskell ^>=0.1.0.0,
    text >=2.1.3 && <2.2
```

Save [Main.hs](../examples/capture-graph/Main.hs) beside the package file, then
download the package index before the first build:

```console
$ cabal update
```

Build and run the example against an existing endpoint, replacing the socket
and executable paths with yours:

```console
$ cabal run --verbose=0 capture-graph -- /tmp/tmux-1000/default /usr/bin/tmux
```

The [capture guide](capture.md) explains the object graph, pure lookups and
scope cleanup. Its owned fixture creates a repeatable server for the
[README example](../README.md). Enable `OverloadedRecordDot` in application
modules using observation fields. No optics or effect framework is required.

The package has no Hackage release yet. The development source provides the
observation API; commands and workspace tooling remain under development.
Check [status](status.md) before choosing it for automation.

## Native backend host requirements

The native backend targets Linux x86_64 with glibc 2.39 or newer
for `pidfd_spawn`, compatible kernel pidfd operations, and exclusive child
reaping ownership. Missing host operations fail before launch. This is
separate from pure scalar construction and lookup. See the
[process host contract](contracts/process.md#launch-and-host-requirements).
