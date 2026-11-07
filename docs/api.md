# API documentation

The public modules are:

| Module | Read it for |
| --- | --- |
| [LibTmux.Id](../src/LibTmux/Id.hs) | Distinct entity IDs, canonical parsing, rendering and `IdError` |
| [LibTmux.Value](../src/LibTmux/Value.hs) | Checked dimensions/indices, numeric access and `ValueError` |
| [LibTmux.Version](../src/LibTmux/Version.hs) | Stable-release identity, admission and `VersionError` |

Build the native Haddock browser from a checkout:

```console
$ cabal haddock lib:libtmux-haskell
```

Open the `index.html` path printed by Cabal. Module overviews explain the
types; declaration documentation specifies input domains, results and
errors. The project enables declaration-to-source links, interactive symbol
search and a Hoogle index for this package. The current public functions are
pure: no field access or parser starts a tmux process.

Haddock 2.33.0 generates some derived-instance method self-links without
targets. Follow the instance's class link for its method contract. Package
declaration links, symbol search and declaration-to-source navigation have
been checked separately.

The complete [typed-value example](../examples/typed-values/Main.hs) uses
only these exports. Its source and output are checked against the source
archive by the [consumer check](../scripts/check_sdist.py).

Private graph, framing and transport modules are implementation details.
They do not constitute an available client API; see [status](status.md).
