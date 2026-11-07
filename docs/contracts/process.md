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

Each pool admits at most 16 jobs. Each job accepts at most 64 KiB of stdin
and retains at most 1 MiB each of stdout and stderr. Accepted byte slices
are copied before worker ownership. Failed signals retain eight recent
errors and a saturating total count; the retained list is forced when
updated. These local bounds do not implement the planned runtime's shared
byte budget, lane admission or shutdown deadline.

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
