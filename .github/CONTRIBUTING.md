# Contributing

The native Haskell implementation is in progress. Version admission, typed
IDs, checked scalar values and the owned tmux fixture have tests. The
complete public API, installed consumers and compatibility matrix remain
unqualified.

Read [AGENTS.md](../AGENTS.md) for change discipline and
[WRITING.md](WRITING.md) for prose and commit conventions.

## Package and dependency policy

This repository develops a native core and plans a workspace library/CLI. MCP is
outside this port's scope; do not add an MCP package, SDK or protocol layer.
This is a project scope decision, not a claim about every available SDK.

Keep the existing `libtmux-haskell` core package at the repository root.
When workspace implementation starts, add `libtmux-haskell-workspace` under
`packages/workspace/`, with a library and a thin executable in the same
Cabal package. Register it explicitly in the root `cabal.project`.
[Multi-package Cabal projects](https://cabal.readthedocs.io/en/stable/cabal-project-description-file.html#specifying-the-local-packages)
resolve local package dependencies together. The workspace depends on the
core's public API and any additional libtmux core packages it needs; the
core must not depend on workspace code. Add another package only for a
separate consumer boundary, dependency set or distribution requirement.
Each published package owns its metadata, tests and `CHANGELOG.md`.

Prefer the selected GHC's boot libraries, native types and ordinary `IO`.
Use `base`, `bytestring`, `containers`, `stm`, `text` and `unix` where they
fit. An external dependency must solve a concrete need with less ownership
and maintenance burden than local code, support the selected compiler, and
have a recorded purpose in the resolved dependency plan. Keep effect
frameworks optional. Keep workspace file-format and CLI dependencies out
of the core; keep test libraries out of runtime dependencies. Do not replace
working scoped concurrency or process code merely to reduce a dependency
count. Qualify cancellation and cleanup before changing those boundaries.

## Toolchain

Target the newest stable GHC series only. As verified on 2026-11-06, that
is [GHC 9.14.1](https://downloads.haskell.org/ghc/9.14.1/docs/users_guide/9.14.1-notes.html),
paired with [Cabal 3.18.2.0](https://downloads.haskell.org/cabal/cabal-install-3.18.2.0/).
[.tool-versions](../.tool-versions) pins both tools.

Use the [GHC2024 language edition](https://downloads.haskell.org/ghc/9.14.1/docs/users_guide/exts/control.html#extension-GHC2024),
the newest stable edition despite its year suffix. Every component uses
`default-language: GHC2024` and bounds `base` to the 4.22 series shipped
with GHC 9.14.

Older GHC versions, compatibility shims, and older-compiler CI jobs are
outside the support scope. Future stable-series upgrades replace this
baseline after verification instead of expanding the support matrix.

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

## Checks

Download and build dependencies before timed checks:

```console
$ cabal build all --only-dependencies
```

Run public specifications and properties without network access. Strict mode
rejects pending/focused examples and empty selections:

```console
$ cabal test specs --offline --test-show-details=direct --test-options='--strict --fail-on=empty'
```

Run the Tasty unit tree, including direct QuickCheck graph properties:

```console
$ cabal test unit --offline --test-show-details=direct
```

The two runners have separate executables. Read [testing](TESTING.md)
for specification authoring, generation/shrinking, and suite assembly.

Check the example catalogue, displayed source/output and local guide links
without compiling or contacting a server:

```console
$ python3 scripts/check_docs.py
```

Verify that deliberate documentation defects are rejected:

```console
$ python3 scripts/test_check_docs.py
```

Run the exact documented checkout commands after provisioning. The outer
check compares exit status, stdout and stderr:

```console
$ python3 scripts/check_docs.py --run
```

Run the outer integration tier against an explicitly selected tmux binary.
These tests start real daemons and check teardown:

```console
$ LIBTMUX_TEST_TMUX="$(command -v tmux)" cabal test integration --offline --test-show-details=direct
```

Check the public scalar API's positive and intended negative compilation
cases in the outer tier. The runner requires Bash and `jq`, and checks the
specific GHC diagnostic rather than accepting any compiler failure:

```console
$ scripts/check-types
```

Check package metadata:

```console
$ cabal check
```

Build API documentation after provisioning its dependency variants. Cabal
gives documentation-enabled dependencies separate store identities; this
step supplements the ordinary dependency build above:

```console
$ cabal build all --enable-documentation --only-dependencies
```

```console
$ cabal haddock lib:libtmux-haskell --offline
```

Create the source archive for isolated consumer verification:

```console
$ cabal sdist all
```

Build and execute every declared consumer and the public Haddock examples
from the archive outside the checkout:

```console
$ python3 scripts/check_sdist.py
```

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
the commands and whole-command times. Passing a subset of tests does not
qualify the complete library or compatibility matrix.

## Test loops

Time each command from startup through setup and cleanup. Libraries should
aim for the stretch budgets.

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

tmux tests and examples must use an isolated server. Give each run
a unique socket and temporary directory with a `libtmux-haskell-` prefix.
Clear inherited `TMUX` and `TMUX_PANE`, and address the owned socket
explicitly. Keep socket paths short enough for Unix socket limits.

Clean up only the server, clients, processes, and files owned by that run,
including after failure or cancellation. Verify that the owned server exits.
Never use or stop the default tmux server.

The fixture owns a foreground `tmux -D` process and waits for socket
readiness through filesystem events. This test setup disables tmux's
ordinary empty-server exit policy; it is not a public startup API contract.
It starts `/bin/cat -` directly and observes that initial pane process's exit
through a Linux pidfd after daemon teardown. The fixture exit watch needs
`pidfd_open` support (Linux 5.3 or newer). The private process suite additionally requires the
[atomic-launch host operations](../docs/contracts/process.md#launch-and-host-requirements).

Callback success, failure and cancellation are covered. Startup checkpoints
also cover cancellation before session dispatch and after its response but
before pane tracking. The latter uses a separate test-owned pidfd to observe
the original pane's exit. Cancellation during daemon acquisition or during
`new-session` before its response, and additional descendants, remain separate
qualification work. No numeric PID is used to signal a pane.

Private socket-pin cases also require writable `/dev/shm` on a different
filesystem from `/tmp` for the cross-device refusal check. They create and
remove only owned directories there. The fixture, scalar decoder and pin
checks are prerequisites; passing them does not qualify public commands,
byte-safe process arguments, bootstrap or runtime child ownership.

Record the exact tmux version and platform for each check. The required
floor is plain tmux 3.3 on Linux x86_64. Qualify exact releases
3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c and
3.8. Capability-specific flags do not raise that floor. Support claims
require evidence from every named cell; skipped or untested cells remain
open. Test rejection of older releases separately.
