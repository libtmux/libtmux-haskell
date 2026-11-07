# Add the package to a Cabal application

Use GHC 9.14.1, GHC2024 and Cabal 3.18.2.0. The package targets this compiler
series on Linux x86_64 only. Install the pinned tools through the
[contributor setup](../.github/CONTRIBUTING.md#toolchain) if needed.

Pin the source revision in your application's `cabal.project`:

<!-- example-project: typed-values -->
```cabal
packages: .
index-state: 2026-11-06T00:00:00Z

source-repository-package
  type: git
  location: https://github.com/libtmux/libtmux-haskell
  tag: f910d69f92a156df3390956470a1a3cd8a69e0fe
```

Add the library to the executable's dependencies. The
[example package](../examples/typed-values/libtmux-typed-values.cabal) is a
complete starting point:

<!-- example-package: typed-values -->
```cabal
cabal-version: 3.18
name: libtmux-typed-values
version: 0.0.0
build-type: Simple
license: MIT

executable typed-values
  main-is: Main.hs
  default-language: GHC2024
  ghc-options: -Wall -Werror
  build-depends:
    base >=4.22 && <4.23,
    libtmux-haskell ^>=0.1.0.0
```

Save [Main.hs](../examples/typed-values/Main.hs) beside the package file, then
download the package index before the first build:

```console
$ cabal update
```

Build and run the example:

```console
$ cabal run --verbose=0 typed-values
```

The [typed-value guide](values.md) explains the output and what each check
establishes. This example requires no running tmux server.

The source revision above contains the current public scalar API. Native
client operations, workspace tooling and MCP require further implementation;
check [status](status.md) before choosing the package for automation.
