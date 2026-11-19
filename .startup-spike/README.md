# Compiled Haskell guardian membership proof

This experiment binds the qualified native guardian to the existing private
Process worker. It does not wire a public owned-server Runtime or claim that
production transport is ready. The collector and prepared-ownership code is
also isolated in two private core commits for reconciliation with streaming.

Hosted entry point after the project's GHC, Cabal and released tmux setup:

```console
$ python3 .startup-spike/run_membership.py \
    --output "$RUNNER_TEMP/guardian-haskell-proof" \
    --capabilities 2
```

Local heavy commands require the task's resource wrapper exactly once. The
entry point performs a strict C syntax check, an offline integration build,
targeted disassembly audit of the helper linked into the real Haskell test
executable, then the eight focused cases. It retains build/test logs, a
receipt and source/executable SHA256 digests. The isolated test helper
propagates the actual GHC capability count; every new case asserts it.

The tests pair state and reservation assertions with physical pidfd witnesses.
A fixture child opens its own pidfd and transfers it independently over
SCM_RIGHTS before the relevant assertions. Cases cover:

- Unpublished child birth, guardian loss, the same ticket and byte/child credits
  retained after the independently known child later exits.
- A live guardian's full subtree proof and physical exit before unpublished
  ownership and its reservations disappear; the original exception survives.
- Real guardian-collected SIGKILL status through Process.cleanup's fallback,
  with one collection and independent physical child exit.
- Binding before the first reservation and a protected serialized inspection
  envelope; refused and repeated binding create no native client.
- Sixteen live children through two pools and one shared budget/domain,
  cancelled observers, the seventeenth dispatch refused before transport,
  exact physical exit and collection before credits return.
- Version and ordinary tmux clients using the bound backend while a borrowed
  daemon remains physically alive on the same socket inode after cleanup.
- A reply dispatched between the waiter's predicate check and socket wait,
  requiring completion without another shared socket event.
- Guardian exit after publishing full proof but before a follow-up control
  send; peer closure is classified by its real verdict rather than EPIPE.

Historical controls remain separate stashes and evidence. The initial three
Haskell cases compiled and failed at the intended physical/reservation/status
assertions. The dispatched-response and STOP/peer-exit orderings each have a
separate deterministic RED. Missing full proof still retains ownership; a
closed peer never supplies that proof by itself.

Core design: capture the execution backend in the same transaction as the
child lease, journal a Prepared obligation before its effect, and keep that
ticket/lease when provisional retirement fails. A known delegated child keeps
its real pidfd and authoritative collector, including cleanup retries. Charge
one extra bounded vector envelope before serialized transport copying, protect
the same allowance for inspection, and erase copied fields after send.

The raw guardian is unchanged from source SHA256
`aa798fa04a614e4ad41926a168ce7e2a5ded73bf8a69ba73fa3ca3974f986936`,
qualified on both released endpoints from a threaded native host. It uses a
private subreaper, exclusive reaping and live ECHILD after closed birth
admission. The test adapter uses one target-aware dispatcher, condition
subscriptions and monotonic event deadlines bounded to 900 ms. No sleeps or
global PID/argv/UID discovery occurs.

Adapter shortcuts remain explicit: fixed sixteen request slots for a whole
fixture, canonical argv0=file and cwd=/, bounded blocking host calls, immediate
SIGKILL, and full-domain retirement for unpublished cleanup. It is not a
production implementation. Before wide integration, implement and prove
reusable bounded request slots/transport, per-request cancellation without
ending a live server, complete launch-refusal/vector/cwd semantics, context
storage accounting, and publication/recovery of the guardian itself. Bind every
owned client and Program Runtime to the same domain and preserve their current
behavior. Public startup, daemon identity/readiness, namespace cleanup and the
complete Haskell endpoint matrix still need integration proof.
