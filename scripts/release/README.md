# release

Prepares, verifies and uploads the core package and its Haddock archive to
Hackage. The release workflow runs it, and CI runs `prepare`. Maintainers
follow [RELEASE.md](../../.github/RELEASE.md) for the account and tag steps.

| Command | What it does |
| --- | --- |
| `check [--publish [BOOL]] [--tag TAG] [--require-token]` | Prints the Cabal version after checking that it is numeric, has a changelog entry and matches the tag. With `--publish`, also requires a tag on `origin/master`. With `--require-token`, also requires `HACKAGE_AUTH_TOKEN`. |
| `prepare` | Builds the source archive and the documentation archive, writes `SHA256SUMS` and installs the source archive in a temporary consumer. |
| `verify` | Checks the archives, their checksums and their identity. |
| `upload [--publish [BOOL] --tag TAG]` | Uploads a candidate, or publishes a matching tag, then compares what Hackage serves with the archives. |

```console
$ uv run scripts/release/release.py check --publish --tag v0.0.1.0
```

`--publish` takes `true` or `false`, and a bare flag means `true`, so the
release workflow passes its input as a value instead of branching. An empty
`--tag` means no tag, which is how a candidate run from a branch passes it.
Every `cabal`, `git` and built-program call has a time limit, so a hang fails
with the command's name.

`upload` needs `HACKAGE_AUTH_TOKEN` and refuses to overwrite a published
version with different bytes. HTTP 401 means Hackage rejected the token; HTTP
403 means the token's owner lacks uploader or maintainer rights.

The tests replace Cabal and the network with stand-ins:

```console
$ uv run --locked --offline pytest scripts/release
```
