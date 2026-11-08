# Private process ownership

This backend owns one-shot child processes. It is private implementation
work, not a public client or a proof that a tmux operation completed.

## Launch and host requirements

Launch uses Linux atomic pidfd creation through `pidfd_spawn`. The backend
resolves that operation and the cwd/closefrom spawn actions dynamically.
Missing operations and incompatible SIGCHLD policies refuse before birth.
There is no numeric-PID signaling or post-spawn pidfd lookup fallback.
An unavailable kernel operation remains a launch refusal. Dynamic lookup
alone does not establish compatibility with an older loader or libc.

The host must preserve its SIGCHLD policy through child retirement and must
not reap library-owned children. Ignoring SIGCHLD or setting SA_NOCLDWAIT
is refused. A status consumed by another reaper becomes explicit lost-status data;
it cannot become a successful exit. Spawn success transfers ownership but
does not prove exec or tmux completion.

Arguments, environment and cwd use explicit bytes. Vectors reject NULs,
relative executable/cwd paths, malformed environment entries, more than
4,096 combined arguments/environment entries, and more than 64 KiB of
encoded strings and pointer storage. No shell parses those vectors.

## Streams and bounds

Parent streams are nonblocking. Read/write readiness uses the GHC event
manager. Stdout and stderr use pipes; stdin uses a Unix stream socket with
the unused directions shut down. Its child endpoint is blocking. Sending
uses MSG_NOSIGNAL without changing the host's handlers, masks or pending
signals. Closing the sole parent writer delivers EOF. Child stdin is a
socket, not a promise of pipe-identical behavior for arbitrary programs.

Each pool admits at most 16 jobs, leaving its final position for inspection.
Ordinary work stops one position below the pool capacity; a capacity-one
pool is inspection-only. Each job accepts at most 64 KiB of stdin
and retains at most 1 MiB each of stdout and stderr. Accepted byte slices
are copied before worker ownership. Failed signals retain eight recent
errors and a saturating total count; the retained list is forced when
updated.

A shared context limits all its pools to eight clients, sixteen pending
children and 128 MiB of reserved payload capacity. Reservation and ticket
registration are one STM transaction before copying or forking. Each captured
child reserves 4,456,448 bytes: both streams' chunks and final concatenations,
stdin, owned/marshaled vectors and read scratch. This conservative allowance
can reject earlier than accounting only actual payload sizes. It is not an
RSS limit; Haskell object headers, GC and detached caller values are separate.

Child and byte leases declare Ordinary or Inspection admission. Ordinary
work stops at fifteen children and leaves the context's configured byte
allowance for inspection. Inspections may borrow unused ordinary capacity,
subject to the same sixteen-child and 128 MiB totals. An inspection still
pending cleanup may hold that capacity; this reserve protects against
ordinary saturation, not arbitrary inspection debt.

Pool construction requires at least 8,650,752 protected bytes: one child's allowance plus a
4,194,304-byte consumer envelope. The envelope covers both completed streams
and equally bounded decoded copies; consumers must enforce those bounds or
reserve more. Ordinary reservations therefore stop at 125,566,976 bytes.
This bounded profile does not guarantee admission of a maximum-size capture.

Constructors require caller masking through cleanup/registry installation.
A pool's client lease survives pin-cleanup failure and is released only after
successful retry. Child and byte leases survive cancelled waiters and failed
cleanup. [Cancellation and retirement](#cancellation-and-retirement) describe
the physical obligations that must finish before their release.

Completion forces both strict output buffers before publication. Publishing
and removing the pool's entry transfers the detached result into the caller's
ticket and releases its child allowance atomically; awaiting is optional.
Pools must not retain an uncharged terminal-result cache. An internal consumer
must reserve a separate parent envelope before dispatch for data retained
through decoding, then transfer that charge or release it on external delivery.

This context is a private prerequisite. Full Runtime supervision, dispatch
integration, deadlines and shared accounting in future capture/subscription
consumers remain unimplemented.

## Logical admission

The separate [STM scheduler](../../internal/LibTmux/Internal/Scheduler.hs)
retains at most 64 logical operations, including uncertain work. Ordinary
operations can occupy 63 slots; inspection can use the remaining capacity.
Dispatch permits cover one mutation, four waiting jobs and four reads.
Ordinary scalar reads can use three read permits, preserving one for
inspection. The oldest eligible operation dispatches; a saturated class
does not obstruct another eligible class. Open dispatchers retry in STM;
closed admission wakes them with a closed result.

Observed progress, the first caller outcome and retained responsibility
are separate. A closed response does not prove operation completion.
Unknown outcomes and connection retirement retain their lane permits:
closing a connection can leave a daemon job alive. Later completion or
proven non-dispatch retires responsibility without rewriting an earlier
outcome. Cancelling a waiter changes none of these states.

Explicit detach releases uncertain logical responsibility and preserves
the last observation. It closes no native resource. Detaching a mutation
permits its successor despite possible continuing external effects.
Closing admission settles queued work as not dispatched and returns active
handles for supervision. Retired handles retain metadata without retaining
the scheduler's live-operation registry.

This scheduler reserve is logical. The process budget separately protects
physical-child and byte capacity for inspection. Runtime integration must
map these classes, charge consumer envelopes and supervise ownership across
both layers. The scheduler performs no tmux IO, supplies no external
completion evidence and does not implement the Runtime's shutdown phases.
The [scheduler tests](../../test/SchedulerTest.hs) qualify these state
transitions separately from the native process tests below.

## Cancellation and retirement

A masked launch transition journals every owned descriptor before pending
Haskell cancellation can be delivered. A masked status transition caches
the consumed result before delivery. Repeated waiters read that cache.
Signaling and pidfd retirement share a lock so a delayed signal cannot use
a descriptor number after closure and reuse.

Cancelling a waiter does not cancel the owned launch. The pool retains its
socket pin and cleanup obligations. Closing admission reports pending debt;
failed cleanup remains retryable. An action failure stays primary while a
simultaneous cleanup failure is retained separately. Cancellation cannot
establish that an external command had no effect.

Tests exercise actual launch/consume return boundaries through test-only C
gates. Isolated helper processes test unavailable symbols, kernel refusal
and host signal policies. Other cases check raw bytes, high inherited file
descriptors, observed EAGAIN, stream bounds, repeated waiters, failed worker
creation, partial stream startup and binary tmux buffer round trips. The
[test guide](../../.github/TESTING.md) distinguishes this private evidence
from the remaining public runtime and command gates.
