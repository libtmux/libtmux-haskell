# check_sdist

Builds the core source archive and runs the public consumers from it, outside
the checkout. CI and maintainers run it before a release.

It checks that:

- every archived file is identical to its checkout file and no member path
  escapes the archive;
- each declared example builds and prints its expected output from the archive
  alone;
- the public `>>>` Haddock examples run against the archived library;
- the public mutation and creation tests pass against the archived library,
  without its internal modules, and end with no fixture daemon or client still owned:
  the generated runner exits 3 and names any owner left, and the check also
  rejects any stderr output;
- every declared example also builds and passes against the one source revision
  that `cabal.project.vcs` offers for installation, which must be an ancestor
  of `HEAD`.

The archive and installation-pin groups use separate Cabal projects. Each
builds its declared consumer packages together with at most two parallel jobs,
then executes and checks every program separately. Components keep their own
source directories and declared dependencies.

It first runs the `check_docs` checks. It needs Cabal, a provisioned dependency
store, the full Git history for the installation pin, and the tmux executable
named by `LIBTMUX_TEST_TMUX` for the examples and public command tests.

```console
$ uv run scripts/check_sdist/check_sdist.py
```

Each `cabal`, `git` and example run has a time limit from
[bounded](../bounded/README.md), which also stops the command's children. A hang
fails with the command's name. The whole step took 82 s at most in CI, which is
below the 120 s `QUICK` limit and a seventh of the 600 s `BUILD` limit; an
example's own run follows its catalogue `timeout`. The example runner starts
under the interpreter that runs this script.

The tests cover the archive-member and Haddock-example checks, which need no
build:

```console
$ uv run --locked --offline pytest scripts/check_sdist
```
