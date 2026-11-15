# check_types

Checks the public API's type contracts with `ghc -fno-code` against the built
library. CI and maintainers run it after changing the public API.

Each case under `test/compile-pass` must compile. Each case under
`test/compile-fail` must fail with the GHC error code and message fragment
declared in `check_types.py`, so a case cannot pass by failing for another
reason.

```console
$ uv run scripts/check_types/check_types.py
```

The command builds `lib:libtmux-haskell` offline, then reads
`dist-newstyle/cache/plan.json` to pass GHC the exact `base`, `text` and
library units. It needs Cabal and a provisioned dependency store.

A new case file must be listed in `ACCEPTED` or `REJECTED`; the tests fail on
an unlisted file.

The tests replace Cabal with a stand-in, so they need no GHC:

```console
$ uv run --locked --offline pytest scripts/check_types
```
