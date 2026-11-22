# prepare_haddock

Prepares a separate, link-checked copy of the Haddock 2.33.0 HTML for the
library. CI and maintainers run it after `cabal haddock`; the raw output stays
untouched.

The copy repairs record-field, instance-method and source anchors that Haddock
leaves ambiguous, unlinks hidden-module names in instance attributions, and
fails on any remaining missing page, missing anchor or duplicate id. It writes
`navigation.json` with the raw and prepared digest of every file. The output
directory must be new.

```console
$ uv run scripts/prepare_haddock/prepare_haddock.py \
    dist-newstyle/haddock-prepared \
    --build-plan dist-newstyle/cache/plan.json
```

The copy also appends `assets/responsive.css` to `linuwial.css`,
`assets/source-responsive.css` to `src/style.css` and `assets/source-popover.js`
to `src/highlight.js`, so wide tables scroll and source annotations stay on
screen. CI syntax-checks the script with `node --check`:

```console
$ node --check scripts/prepare_haddock/assets/source-popover.js
```

`--raw` selects a Haddock directory instead of a build plan. The [API
guide](../../docs/api.md) explains the corrections and their limits.

The tests build small pages in a temporary directory:

```console
$ uv run --project scripts --locked --offline pytest scripts/prepare_haddock
```
