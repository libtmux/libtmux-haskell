# release

Prepares, verifies and uploads the core package and its Haddock archive to
Hackage. The release workflow runs it, and CI runs `prepare`. Maintainers
follow [RELEASE.md](../../.github/RELEASE.md) for the account and tag steps.

| Command | What it does |
| --- | --- |
| `check [--tag TAG]` | Prints the Cabal version after checking that it is numeric, has a changelog entry and matches the tag. |
| `prepare` | Builds the source archive and the documentation archive, writes `SHA256SUMS` and installs the source archive in a temporary consumer. |
| `verify` | Checks the archives, their checksums and their identity. |
| `upload [--publish --tag TAG]` | Uploads a candidate, or publishes a matching tag, then compares what Hackage serves with the archives. |

```console
$ uv run scripts/release/release.py check --tag v0.0.1.0
```

`upload` needs `HACKAGE_AUTH_TOKEN` and refuses to overwrite a published
version with different bytes. HTTP 401 means Hackage rejected the token; HTTP
403 means the token's owner lacks uploader or maintainer rights.

The tests replace Cabal and the network with stand-ins:

```console
$ uv run --locked --offline pytest scripts/release
```
