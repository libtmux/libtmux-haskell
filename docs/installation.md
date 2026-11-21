# Add the package to a Cabal application

Requirements:

- GHC 9.14 and Cabal within the bounds in the
  [package manifest](../libtmux-haskell.cabal).
- Linux x86_64. The first program needs peer pidfds from Linux 6.5.
  [Host requirements](#native-backend-host-requirements)
- tmux 3.3a or newer.

Opening a Server refuses older observed releases before entering the callback.
An older daemon that rejects the selected client's wire protocol raises
`IncompatibleTmuxClientProtocol`; its release remains unknown to that client.
See [capability discovery](capabilities.md).
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
    libtmux-haskell ^>=0.0.1.0,
    text >=2.1.3 && <2.2
```

Save [Main.hs](../examples/capture-graph/Main.hs) beside the package file, then
update the package index:

```console
$ cabal update
```

Run the program. It starts and retires a private daemon.

```console
$ cabal run --verbose=0 capture-graph
```

- Enable
  [`OverloadedRecordDot`](https://downloads.haskell.org/ghc/latest/docs/users_guide/exts/overloaded_record_dot.html)
  in modules that read observation fields.
- No optics or effect framework is needed.
- The [capture guide](capture.md) covers the object graph, pure lookups and
  scope cleanup.

The API is experimental. It supports private daemons, typed snapshots and
mutations, pane I/O and bounded control notifications. Managed terminal
programs also require tmux 3.8, Linux 6.9 process-group pidfds and the Bash
features in the [program guide](programs.md). See [status](status.md).

Browse the [manual](https://libtmux.org/en/haskell/) and
[`LibTmux.Server` API](https://libtmux.org/en/haskell/latest/reference/libtmux-server/)
for connection, capture and mutation operations.

## Fetch the source from Git

Cabal fetches a source revision from Git until the first Hackage release.
Put the following settings in `cabal.project`.

<!-- example-project: capture-graph -->
```cabal
packages: .
index-state: 2026-11-06T00:00:00Z

source-repository-package
  type: git
  location: https://github.com/libtmux/libtmux-haskell
  tag: 4f60b832f5303f9221251b199e86b5d928757943
```

## Native backend host requirements

The native backend needs:

- Linux x86_64.
- glibc 2.39 or newer, for `pidfd_spawn`.
- A kernel with compatible pidfd operations.
- Exclusive ownership of child reaping.

`withOwnedServer` also needs peer pidfds, available from Linux 6.5, and
a mounted `/proc` with readable process and descriptor information. It checks
host operations before starting tmux. Pure scalar construction and lookup
work without a daemon.
[Linux 6.5 socket options](https://github.com/torvalds/linux/blob/v6.5/include/uapi/asm-generic/socket.h#L128-L129) ·
[Process host contract](https://github.com/libtmux/libtmux-haskell/blob/master/docs/contracts/process.md#launch-and-host-requirements)
