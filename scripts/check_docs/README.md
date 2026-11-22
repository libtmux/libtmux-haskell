# check_docs

Checks the example catalogue, the source and output shown in documents, and
local guide links. CI and maintainers run it after editing a guide, an example
or the CI workflow.

It rejects an undeclared example program, an unregistered Haskell fence in the
README, manual or maintainer guides, a displayed snippet that differs from its
source, a missing local link or image, and a catalogue entry whose workflow job,
step or command no longer exists in `.github/workflows`.

```console
$ uv run scripts/check_docs/check_docs.py
```

`--run` also executes each documented command from the checkout and compares
its exit status, stdout and stderr. A command that outlives its limit fails
with its example's identifier and its whole process group stops. The limit is
120 s unless the catalogue entry sets `timeout`, up to 900 s. The slowest
`--run` step in CI took 10 s ([measurement](../bounded/README.md)). Provision
the examples first:

```console
$ uv run scripts/check_docs/check_docs.py --run
```

The tests plant each defect in a disposable copy of the checkout and expect
the check to fail:

```console
$ uv run --project scripts --locked --offline pytest scripts/check_docs
```
