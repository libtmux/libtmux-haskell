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
  without its internal modules;
- every declared example also builds and passes against the one source revision
  that `cabal.project.vcs` offers for installation, which must be an ancestor
  of `HEAD`.

Each source gets one workspace outside the checkout, with its own build
directory and one `cabal.project` that lists the source's archive and every
package to build against it: the declared examples and, for the archive, the
public command package. One `cabal build` builds all their executables, so
Cabal solves and configures each source once. The script then runs each example
and compares its exit status, stdout and stderr with the catalogue. A workspace
never lists the checkout or the other source.

It first runs the `check_docs` checks. It needs Cabal, a provisioned dependency
store, the full Git history for the installation pin, and the tmux executable
named by `LIBTMUX_TEST_TMUX` for the examples and public command tests.

```console
$ uv run scripts/check_sdist/check_sdist.py
```

The tests cover the archive-member and Haddock-example checks and, with a
recording stand-in for `cabal`, the workspace layout and example failures. They
need no build:

```console
$ uv run --locked --offline pytest scripts/check_sdist
```
