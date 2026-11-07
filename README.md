# libtmux for Haskell

Implementation is in progress. The intended suite provides a native Haskell
library, a workspace loader and an MCP executable over one tmux core.
Package, runtime and release qualification are incomplete.

The compiler baseline is GHC 9.14.1 with GHC2024 and Cabal 3.18.2.0. Only
that modern stable series is targeted. The required tmux matrix starts at
plain 3.3 on Linux x86_64; no supported-release claim is made yet.

See [contributing](CONTRIBUTING.md) for setup and fixture isolation and the
[behavior inventory](docs/contracts/README.md) for implementation scope.
