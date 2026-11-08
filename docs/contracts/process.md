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

## Provisional Runtime ownership

The private [Runtime](../../internal/LibTmux/Internal/Runtime.hs) constructs a
fresh pin owner and reserves its pool's client credit in the same STM
transaction that registers cleanup responsibility. Socket adoption starts
after that registration. Exhausted or closed admission therefore refuses
before creating a private socket alias. Only successful adoption on an open
pool can return a client.

Failed and cancelled adoption retain their pool and pin journal. Cleanup
failure keeps the registry entry and client credit until a successful retry.
The original adoption exception remains primary, including cancellation.
Closing shared admission observes every registered owner; it cannot miss a
pool between reservation and registration. Reports and later admission
remove only entries whose cleanup has completed, so retired clients do not
accumulate in the registry.

Runtime close requests cleanup for all registered pools and reports ordinary
request failures. Waiting propagates a failed cleanup restart before awaiting
workers that could not start. It can also throw a retained pin-cleanup failure,
and has no hard deadline. Existing pool workers own physical cleanup; the
registry adds no process-global state or detached reaper. It does not issue
`kill-server` or establish completion of daemon-side work.

The separate `shutdown` operation closes admission and shares one owned
attempt among concurrent callers. Caller cancellation stops that caller's
wait; the Runtime worker continues. It allows up to 250 ms for graceful
cleanup, requests cancellation of remaining command clients, then allows up
to 250 ms for physical retirement. Each phase ends early when cleanup
completes. Cancellable monotonic timers bound STM observation, without
polling or fixed sleeps.

The returned report can remain incomplete. Phase expiration never deletes
an owner, releases its credit or proves the daemon-side outcome. Existing
pool workers continue cleanup; a later shutdown can retry a finished
attempt. Supervisor allocation failure closes admission, reports the
exception and leaves owners available for retry. The Runtime retains only
the current attempt's completion latch.

This ownership layer is private. The fixed server reads below bind logical and
physical ownership. Other command bindings, capture and subscription consumers
remain unimplemented. Physical shutdown does not resolve logical unknown
outcomes or establish completion of a daemon job.

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
physical-child and byte capacity for inspection. Each Runtime command binding
must map these classes, charge consumer envelopes and supervise ownership across
both layers. The scheduler performs no tmux IO, supplies no external
completion evidence and does not implement the Runtime's shutdown phases.
The [scheduler tests](../../test/SchedulerTest.hs) qualify these state
transitions separately from the native process tests below.

## Framed server read ownership

The private Runtime observes server PIDs and stable release identities through
the adopted socket pin. An opaque `Request value` retains the decoded result's
type. A closed GADT pairs each fixed format with that type; the owned registry
retains the witness without a cast or an arbitrary decoder callback.

Success requires a fresh nonce frame, empty stderr and successful command-client
exit. PID decoding retains its 32-byte bound and checked positive process-ID
domain. Version decoding accepts at most 64 bytes, requires valid UTF-8 and
uses the existing [version parser](../../src/LibTmux/Version.hs). Stable-version
observation is separate from minimum-version admission and feature capability
checks. Decoded values are forced before the read envelope is released.
Extra hook output is a protocol failure. A receipt establishes that read's
result; it does not establish completion of arbitrary daemon work.

Each admitted read reserves a parent byte envelope and registers its owner
before copying or forking. The matching inspection class reserves both the
logical permit and protected parent/child credits. A foreign client is refused
before reservation. A worker claims only its own oldest eligible operation;
STM rollback leaves other operations unchanged.

The process reservation transaction records its Ticket in the Runtime journal
before the native worker can start. The interpreter masks through constructor
return and ownership recognition. Explicit native refusal survives later worker
failure; possible native birth is not a tmux acknowledgment.

Reads have a one-second default deadline and a ten-second maximum. One absolute
monotonic expiration governs queueing, submission and validated-result
eligibility. It is sampled before submission and immediately before the final
publication transaction; this does not promise real-time OS scheduling. Scoped
timers retire on early completion. Queued cancellation can prove non-dispatch.
Active expiration or cancellation publishes uncertainty and requests physical
cancellation, retaining outstanding responsibility.

Cancelling an outcome waiter changes no ownership. Late framed proof or genuine
pre-exec refusal may retire logical responsibility without replacing its first
outcome. Explicit detach releases only uncertain logical metadata. Unawaited
completed reads leave no live Runtime entry or retained Ticket.

An interrupted interpreter keeps its parent envelope while its Ticket can still
publish buffers. Recovery consumes or validates that result without resubmitting
the command. Interrupted recovery retains a failed owner for cleanup retry;
known allocation failure is reported before an unstarted-worker join.

Reports distinguish physical pool debt, charged read workers and unresolved
logical handles. Shutdown settles queued reads while active reads may finish
during grace. Its empty shortcut and timed phases include unfinished read
workers. Metadata alone does not prolong those physical phases. After
independent worker and process cleanup, explicit inspection can still show
uncertain logical responsibility requiring proof or detach.

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
