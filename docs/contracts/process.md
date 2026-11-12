# Private process ownership

This backend owns one-shot child processes. It is private implementation
work, not a public client or a proof that a tmux operation completed.

## Launch and host requirements

Launch uses Linux atomic pidfd creation through `pidfd_spawn`, introduced
in [glibc 2.39](https://sourceware.org/pipermail/libc-announce/2024/000038.html).
The initial stock-glibc backend requires glibc 2.39 or newer. The backend
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
child reserves 4,457,472 bytes: both streams' chunks and final concatenations,
stdin, owned/marshaled vectors, read scratch and bounded stdout-prefix copies.
This conservative allowance can reject earlier than accounting only actual
payload sizes. It is not an RSS limit; Haskell object headers, GC and detached
caller values are separate.

Child and byte leases declare Ordinary or Inspection admission. Ordinary
work stops at fifteen children and leaves the context's configured byte
allowance for inspection. Inspections may borrow unused ordinary capacity,
subject to the same sixteen-child and 128 MiB totals. An inspection still
pending cleanup may hold that capacity; this reserve protects against
ordinary saturation, not arbitrary inspection debt.

Pool construction requires at least 8,652,288 protected bytes: one child's
allowance plus a 4,194,816-byte consumer envelope. The envelope covers both
completed streams, equally bounded decoded copies and the retained stdout
prefix; consumers must enforce those bounds or reserve more. Ordinary
reservations therefore stop at 125,565,440 bytes.
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

Each ticket retains a copied 512-byte stdout prefix independently of its final
result. A short masked transition reads the nonblocking descriptor and
publishes the bounded prefix before checking the stream limit. Cancellation
and overflow therefore preserve already observed evidence. Readiness waits
remain interruptible; stderr never enters this journal. Completing a prefix
does not establish command completion. Runtime creation recovery must still
transfer validated IDs into its own bounded receipt journal.

## Provisional Runtime ownership

The private [Runtime](../../internal/LibTmux/Internal/Runtime.hs) creates a
fresh pin journal, then reserves its pool's client credit in the same STM
transaction that registers cleanup responsibility. Socket adoption starts
after that registration. Exhausted or closed admission therefore refuses
before creating a private socket alias. Only successful adoption on an open
pool can return a handle.

Failed and cancelled adoption retain their pool and pin journal. Cleanup
failure keeps the registry entry and client credit until a successful retry.
The original adoption exception remains primary, including cancellation.
Closing shared admission observes every registered owner; it cannot miss a
pool between reservation and registration. Reports and later admission
remove only entries whose cleanup has completed, so retired handles do not
accumulate in the registry.

The private `ServerOwner` identifies that registered responsibility before a
socket pin exists. `ServerHandle` still requires a complete pin. Separating
registration from acquisition lets an owner-specific exception policy cover
failed or cancelled adoption without requiring a returned handle. Origin and
admission checks precede filesystem acquisition and repeat before publication.

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

Private `shutdownServerHandle` applies the same phase limits to one adopted
handle. Its first STM transaction validates the Runtime, closes only that
pool's admission and publishes `NotDispatched` for its queued reads. This cut
precedes supervisor allocation, so an allocation failure still leaves the
selected handle closed and its queued results available. Concurrent callers
join that handle's owned attempt; cancellation stops only the caller's wait.
Other handles retain admission under the unchanged global resource limits.

Private `inspectServerHandle` reports that pool, its read workers and its
logical operation group. Logical detachment cannot hide a physical owner;
decoder retirement cannot erase uncertain logical responsibility. Admission
requires both the Runtime and selected pool to remain open. Global and scoped
shutdown may overlap; completed owners release their credits once. A foreign
Runtime/handle pair is rejected before either context changes.

Private `runServerScope` preserves the common exception policy for one
`ServerOwner`. Registration and policy installation stay masked; the caller's
outer restore applies to acquisition and application work inside that policy.
Recovery retains the selected target through callback failure, cleanup failure
and cancellation. A provisional adoption can therefore retain a recovery owner
before it publishes a Server handle, while other handles remain usable under
the shared limits.

Inspection, retry and explicit cleanup waiting use the same selected target.
The explicit wait has no deadline; cancellation keeps a reachable owner.
Logical detachment validates the operation's Runtime and group before changing
responsibility. It releases no physical ownership.

This ownership layer is private. The fixed server reads and closed mutations
below bind logical and physical ownership. Public captures and
[rename/title operations](../mutations.md) use the Server scope. Subscription
APIs remain unimplemented. Physical shutdown does not resolve logical unknown
outcomes or establish completion of a daemon job.

## Public scope outcomes

The common Server scope preserves these outcomes:

- Successful callback and cleanup return the callback result.
- Successful callback with failed cleanup reports cleanup failure and retains
  a reachable recovery owner.
- Failed callback with successful cleanup preserves the callback exception.
- Callback and cleanup failure preserve the callback exception as primary,
  with secondary diagnostics and recovery responsibility still reachable.
- Cancellation with incomplete cleanup preserves asynchronous cancellation
  and the specified reachable owner.
- Recovery-worker allocation failure retains existing ownership and reports
  the failed handoff.

A generally blocking uninterruptible region cannot supply bounded cleanup.
Exception-context annotations retain recovery owners. Integrated scope tests
cover cancellation, double failure and failed worker allocation. The public
`tryTmux` specializes base's `tryWithContext`, returning the typed failure together
with its exception context. Retain that context when converting errors;
`cleanupRecoveries`, `captureRecoveries` and `mutationRecoveries` read their
owners from it.
An ordinary typed `try` discards those annotations. The GHC 9.14.1 probe and
the public cleanup-failure integration case qualify the chosen catch boundary.
[base exception API](https://hackage-content.haskell.org/package/base-4.22.0.0/docs/Control-Exception.html#v:tryWithContext).

`withRuntime` supplies caller-owned Runtime scopes to `withServerIn`; the common
`withServer` scope creates and owns its Runtime. See the
[shared Runtime guide](../shared-runtime.md).

Correlate capture
failure with operation ID, endpoint/generation, physical cleanup status,
logical outcome and available recovery or explicit detachment. Batching
alone does not establish logical completion or retire uncertainty.

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

The private Runtime observes server PIDs, stable releases, physical graphs and
the finite Snapshot profile through
the adopted socket pin. An opaque `Request value` retains the decoded result's
type. A closed GADT pairs each fixed format with that type; the owned registry
retains the witness without a cast or an arbitrary decoder callback.

Success requires a fresh nonce frame, empty stderr and successful command-client
exit. PID decoding retains its 32-byte bound and checked positive process-ID
domain. Version decoding accepts at most 64 bytes, requires valid UTF-8 and
uses the existing [version parser](../../src/LibTmux/Version.hs). Stable-version
observation is separate from supported-range admission and feature capability
checks. Decoded values are forced before the read envelope is released.
Extra hook output is a protocol failure. A receipt establishes that read's
result; it does not establish completion of arbitrary daemon work.

Each admitted read reserves a parent byte envelope and registers its owner
before copying or forking. The matching inspection class reserves both the
logical permit and protected parent/child credits. A foreign client is refused
before reservation. A worker claims only its own oldest eligible operation;
STM rollback leaves other operations unchanged.

Tagged graph and Snapshot reads always use ordinary admission. Their registered read
owner retains the 64 MiB graph construction allowance together with the
process-result envelope. Caller cancellation cannot release that allowance
while a worker still constructs or forces the graph. The default graph capture
does not acquire a second copy of it. Scalar comparison capture retains its
separate scoped allowance. These reservations bound admitted work, not RSS;
minimal inspection reads keep their protected capacity.

The process reservation transaction records its Ticket in the Runtime journal
before the native worker can start. The interpreter masks through constructor
return and ownership recognition. Explicit native refusal survives later worker
failure; possible native birth is not a tmux acknowledgment.

PID/version conveniences use a one-second default. Explicit read deadlines have
a ten-second maximum; graph reads require a supplied deadline. One absolute
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

## Closed mutation ownership

The private Runtime binds session renames, window renames and pane-title
changes to the existing native owner. These handlers return synchronously;
configured after-hooks may still wait or fail. This is not a general command,
waiting-job or control-observer interface. The
[public rename/title methods](../mutations.md) validate references and apply a
single deadline across submission and response waiting.

Literal lowering produces one checked argument vector. The complete executable,
socket and command vector is validated before admission. Mutation work uses
the serialized mutation lane and ordinary capacity, preserving inspection
capacity. Its parent envelope includes the copied vector; the retained result
witness contains no original mutation operand or decoder callback.

One nonattaching `-C` client executes the command through the pinned socket.
It sends no control input and invokes no helper commands. Its stdin writer
stays open during normal collection: early EOF can let tmux 3.3a exit before
a waiting after-hook finishes. Existing finite-input requests still write
their bounded bytes and close stdin. Both modes retain the same process,
stream and cleanup ownership.

Completion requires drained bounded streams, empty native stderr, a normal
child exit, the initial matching command acknowledgment and the final bare
control exit. The closed decoder recognizes only that first acknowledgment;
following hook output and notifications remain opaque bytes. Unexpected
leading data, mismatched or truncated framing and abnormal exits retain an
unknown outcome rather than triggering replay.

The detached result distinguishes:

- `Applied`: an empty primary success acknowledgment and successful client exit.
- `Rejected`: a primary error acknowledgment and failed client exit, retaining
  bounded diagnostic bytes.
- `AppliedWithErrors`: a primary success acknowledgment followed by failed
  client exit, retaining bounded following diagnostics. The primary effect
  already happened; this does not imply rollback.

Cancellation of a raw Runtime waiter changes no ownership. The synchronous
public mutation wrapper explicitly requests cancellation when its wait is
interrupted. Request cancellation settles queued work as not dispatched or
accepted work as unknown, and requests native cleanup. Physical cleanup and
logical responsibility remain separate.
Recovery never resubmits the command; explicit logical detachment releases no
native resource and cannot change the original caller outcome. The native
integration cases cover waiting hooks, error after effect, opaque control-shaped
hook data, unrelated display hooks, reserved inspection and later reuse.

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
