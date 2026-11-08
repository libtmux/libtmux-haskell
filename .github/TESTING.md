# Specifications, properties and suites

Hspec expresses the public ID, value and version requirements. QuickCheck
generates inputs and shrinks counterexamples. Tasty assembles the internal
unit and owned-tmux integration trees, including direct QuickCheck properties.

The `specs` executable uses Hspec 2.11.18 and QuickCheck 2.19.0.0. The `unit`
and `integration` executables use Tasty 1.5.5; `unit` also uses
tasty-quickcheck 0.11.1. GHC 9.14.1 and GHC2024 apply to every component.
As checked on 2026-11-07, the published tasty-hspec adapter excludes this GHC
and QuickCheck combination in its [bounds][adapter]. These runners therefore
remain separate executables.

## Author specifications

[IdSpec](../test/specs/IdSpec.hs), [ValueSpec](../test/specs/ValueSpec.hs) and
[VersionSpec](../test/specs/VersionSpec.hs) name observable requirements with
`describe` and `it`, followed by ordinary expectations. Boundary examples
retain exact error assertions. [Main](../test/specs/Main.hs) assembles those
specifications through Hspec's native runner.

Run them with strict qualification policies:

```console
$ cabal test specs --offline --test-show-details=direct --test-options='--strict --fail-on=empty'
```

## Design properties

[IdProperties](../test/specs/IdProperties.hs) is independent of the runner.
Its generator deliberately samples zero, the native maximum and interior
integers. Its shrinker stays in that domain. `checkCoverage` makes missing
boundary coverage fail. The property checks numeric meaning as well as
canonical spelling; separate examples cover rejected external strings.

[GraphProperties](../test/GraphProperties.hs) generates bounded link/pane
counts and checks every expected occurrence pair. Shrinking preserves a
nonempty pane set and repeated links. Keep pure properties separate from
live resource tests; generated cases must not repeatedly start daemons.

## Assemble heterogeneous suites

The [unit runner](../test/Main.hs) combines HUnit examples and a QuickCheck
provider in one Tasty tree. The [integration runner](../test/integration/Main.hs)
combines fixture, scalar-framing, private-pin and process-owner cases. Tasty owns their
selection, scheduling and reporting. Select a focused inner loop with its
name filter; leave real process tests in the outer tier.

```console
$ cabal test unit --offline --test-show-details=direct
```

Integration selects an explicit tmux binary and owns every daemon and socket:

```console
$ LIBTMUX_TEST_TMUX="$(command -v tmux)" cabal test integration --offline --test-show-details=direct
```

Startup cancellation cases stop before session dispatch or after its response
but before the fixture tracks its pane. A separate test-owned pidfd observes
pane exit directly after daemon cleanup. Another case holds after-new-session
in an owned wait channel, then cancels before the command client completes.
The creation command may already have emitted receipt bytes. Strict output
readers have nested scopes so cancellation joins them before handle cleanup;
a reader waiting for EOF cannot prevent child termination. Earlier daemon
acquisition, cancellation before creation or its first output, and arbitrary
descendants remain unqualified. These cases do not establish the public
client's bootstrap or cancellation contract.

## CI and caches

The [workflow](../.github/workflows/ci.yml) checks only the selected modern
compiler. It runs specifications, properties, public type contracts, package
metadata, Haddock and an isolated archive consumer. Each required tmux release
then runs the integration subset with one and two RTS capabilities on its
own runner under `C.UTF-8`. Scalar framing also runs under `C`: raw native
arguments store invalid bytes and literal escape sequences in owned options,
then compare decoded output with the original fixed and seeded values.
The checks include tmux 3.4 dollar escaping and the Runtime's entity-field
binding. tmux's command-input normalization remains separate from output
decoding. The lossless observation case waits on a FIFO receipt after the
owned process has adopted its raw argv, captures without replacing bytes,
and reads retained command/path/name values after cleanup. It checks tmux's
release-specific name normalization and runs under both locale profiles.
The final
`required` job fails if any planned job fails, cancels or skips.

Cabal caches contain the dependency store and package index. tmux cache keys
include its pinned archive, runner image/version, architecture, compiler,
library packages and build recipe. A restored executable must match its
recorded hash and version; invalid cache content is rebuilt. The owned
integration suite must pass before a fresh tmux build is saved.

These checks qualify the existing implementation subset. The complete
capture/runtime/workspace and release gates remain separate work.

## Executable documentation

The [catalogue](../examples/catalogue.json) is the source of runnable program
paths, displayed assets and execution provenance. The documentation check
rejects unregistered programs and Haskell fences, including nested guides.
Its regression cases introduce missing examples, stale snippets and invalid
catalogue entries in disposable copies.

CI runs the literal checkout command and then builds the same public program
from the source archive in an independent application. Both check exit
status, exact stdout and empty stderr. The archive consumer also executes
the `>>>` examples from the public module documentation. Keep all these
routes passing when changing an example, manifest or public signature.

A real-tmux capability program must include its own setup and cleanup,
explicit target, feature floor and observable result. Run it end to end;
a compile-only test or a private test helper does not qualify the shared
[showcase](https://github.com/libtmux/docs/issues/243).

[adapter]: https://hackage-content.haskell.org/package/tasty-hspec-1.2.0.4/revision/8.cabal


## Private process tests

The [logical scheduler tests](../test/SchedulerTest.hs) run in the unit tier.
They cover inspection reserves, lane saturation, first-outcome publication,
retained uncertainty, foreign handles, queued refusal and closure. Scoped
workers exercise outcome-waiter cancellation and dispatcher shutdown. STM
retry assertions avoid waiting when work should already be eligible; a
500 ms per-case watchdog bounds unexpected deadlocks. No sleep schedules
a race. These cases do not establish external tmux completion or a physical
resource reserve for inspection.

Select the focused unit group:

```console
$ cabal test unit \
    --offline \
    --test-show-details=direct \
    --test-options=--pattern=logical
```

The integration tier compiles two owned C helpers once per run, using `cc`.
The build cleans its temporary directory on compilation failure or
cancellation. Helpers test the same production C source; symbol injection,
native-call gates and writer observations remain in test support.

The process group exercises real pending Haskell interruption at launch and
status consumption, failed-signal bounds, byte-slice detachment, descriptor
retirement, raw vectors, inherited descriptor closure, output overflow and
observed socket backpressure. Signal policies run in isolated helper
processes. They never change the Haskell test runner's host policy. Binary
load-buffer/save-buffer cases use the owned private tmux pin; empty stdin
checks EOF independently.

Shared-context cases hold fifteen ordinary native launches and one inspection
across two pools and reject the seventeenth before dispatch. Another case fills
ordinary child and payload reservations, then executes an inspection against
the owned tmux daemon and compares its PID with an independent receipt. It
checks retained parent bytes, cancelled waiters and eventual zero credits.
A small-pool case checks that ordinary work leaves its final position usable
by inspection. They also check total byte exhaustion, constructor
handoff under actual pending cancellation, retryable pin cleanup and a consumer
envelope retained after unawaited result publication. Pure budget tests cover
exact limits, overflow refusal, atomic reservation and repeated release. These
are [private ownership contracts](../docs/contracts/process.md#streams-and-bounds),
not evidence for a complete public Runtime or total-process memory cap.

The provisional Runtime cases check that eight client credits prevent a ninth
endpoint adoption, and that close sees acquisition before client publication.
Cancellation during partial pin acquisition preserves its exception and retains
an obstructed cleanup journal. A second healthy client still cleans up; removing
the obstacle allows retry to retire the first owner and its credit. Repeated
real PID inspections check pin targeting, complete streams and registry reuse.
An injected cleanup-restart failure must throw before a 250 ms watchdog,
retain the failed child and client credits, and allow a later successful retry.
The phased shutdown cases hold an actual native launch across both 250 ms
phases. Cancelling one caller leaves a single shared attempt running; its
incomplete report retains client, child and byte credits until gate release.
A monotonic measurement rejects collapsed phases. A real waiting command can
finish normally during grace, while pin-only cleanup needs no fixed delay.
Refusing the supervisor allocation closes admission and permits a later retry
without stranding its completion latch. Each case verifies physical cleanup;
an independent command checks that the owned tmux daemon remains usable.
These cases qualify [private physical ownership](../docs/contracts/process.md#provisional-runtime-ownership),
not logical dispatch integration, operation deadlines or daemon-job completion.

The [Runtime read cases](../test/integration/RuntimeReadTest.hs) bind fixed
framed PID and stable-version observations to logical admission and physical ownership. They cover
foreign-context refusal, queued and active deadlines, cancelled outcome waiters,
late native refusal, constructor handoff, interpreter recovery and cleanup-fork
refusal. Actual PID receipts exercise inspection's protected child and parent
credits. Contaminated framing cannot become success. Close settles queued work,
allows graceful reads and preserves unresolved metadata after physical cleanup.
Version values agree with the selected fixture binary's independent release
receipt and survive cleanup. Mixed PID/version requests share queued cancellation
and expiry checks. The result type is preserved through the owned registry.
These are [private read contracts](../docs/contracts/process.md#framed-server-read-ownership),
not qualification of other commands, capture or the public Client.

A deliberately held signal has a 250 ms watchdog to detect premature pidfd
retirement. Native gate observations also have bounded watchdogs. These
checks synchronize through STM, descriptors and RTS status; they do not
schedule races with sleeps. They belong in the outer tier because they
launch helpers and real tmux daemons. Run the full suite with both one and
two RTS capabilities before promoting ownership changes. The
[process contract](../docs/contracts/process.md) records the required host
operations and remaining runtime limits.
