# Contributing

This repository is a stub for a Haskell port of libtmux. It contains
contributor instructions and toolchain pins. Package manifests, source,
tests, and CI belong to a later implementation request.

Read [AGENTS.md](AGENTS.md) for change discipline and
[WRITING.md](WRITING.md) for prose and commit conventions.

## Toolchain

Target the newest stable GHC series only. As verified on 2026-11-06, that
is [GHC 9.14.1](https://downloads.haskell.org/ghc/9.14.1/docs/users_guide/9.14.1-notes.html),
paired with [Cabal 3.18.2.0](https://downloads.haskell.org/cabal/cabal-install-3.18.2.0/).
[.tool-versions](.tool-versions) pins both tools.

Use the [GHC2024 language edition](https://downloads.haskell.org/ghc/9.14.1/docs/users_guide/exts/control.html#extension-GHC2024),
the newest stable edition despite its year suffix. When implementation
starts, declare `default-language: GHC2024` in every Haskell component and
bound `base` to the 4.22 series shipped with GHC 9.14.

Older GHC versions, compatibility shims, and older-compiler CI jobs are
outside the support scope. Future stable-series upgrades replace this
baseline after verification instead of expanding the support matrix.
The current stub has no components, so compilation remains unverified.

Install [GHCup](https://www.haskell.org/ghcup/install/) and the system
dependencies it lists for your platform. From the repository root, install
the pinned compiler:

```console
$ ghcup install ghc 9.14.1
```

Install the pinned Cabal client:

```console
$ ghcup install cabal 3.18.2.0
```

Select those versions through GHCup or your existing tool manager and make
`ghc-9.14.1` and `cabal` available on `PATH`. Confirm the selected versions:

```console
$ ghc-9.14.1 --numeric-version
```

```console
$ cabal --numeric-version
```

Keep the installation commands in sync with `.tool-versions`. Installation
and dependency downloads happen before timed checks.

## Scaffold checks

Check whitespace in tracked changes:

```console
$ git diff --check
```

Review new, untracked files directly; `git diff` does not inspect them.
Check staged changes before committing:

```console
$ git diff --cached --check
```

Check relative documentation links, the `CLAUDE.md` symlink target, and the
actual changed tree. Report `PASS`, `FAIL`, `PARTIAL`, or `UNVERIFIED` with
the commands and whole-command times. Build and runtime checks are not
applicable until implementation exists; a scaffold check is not evidence
of a working library.

## Test loops

As implementation checks are added, time each command from startup through
setup and cleanup. Libraries should aim for the stretch budgets.

| Loop | Budget | Stretch | Scope |
| --- | --- | --- | --- |
| Inner | Under 5 seconds | Under 2 seconds | Tests for changed code |
| Mid | Under 30 seconds | Under 10 seconds | Unit suites, lint, generated-file checks |
| Outer | Under 5 minutes | Under 60 seconds | Type checks, builds, integration, matrices |

Run the inner loop after edits, the mid loop before handoff, and the outer
loop before commits or pull requests. Keep network access, installations,
production builds, browser launches, sleeps, and broad scans out of the
inner and mid loops.

Treat timeouts or waits over one second as structural bugs. Investigate
them and use events or subscriptions instead of sleeps. Tag slow checks
with a one-line reason and place them in the outer loop. Fix an over-budget
loop before adding tests; do not raise its budget.

Benchmarks are a separate tier: under ten minutes per run and under one
hour for a sweep. Reduce workload sizes when needed.

## Testing tmux behavior

Future tmux tests and examples must use an isolated server. Give each run
a unique socket and temporary directory with a `libtmux-haskell-` prefix.
Clear inherited `TMUX` and `TMUX_PANE`, and address the owned socket
explicitly. Keep socket paths short enough for Unix socket limits.

Clean up only the server, clients, processes, and files owned by that run,
including after failure or cancellation. Verify that the owned server exits.
Never use or stop the default tmux server.

Record the exact tmux version and platform for each check. The intended
floor is tmux 3.3a on Linux; plain 3.3 is below it. Support claims require
evidence from the named matrix cells. Skipped or untested cells remain open.
