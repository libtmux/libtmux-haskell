# Start a private server and retire a daemon

[`withOwnedServer`](../src/LibTmux/Server.hs) starts a tmux daemon of its own,
passes the callback a [`Server`](../src/LibTmux/Server.hs) for it, and retires
that daemon when the scope closes. [`killServer`](../src/LibTmux/Server.hs)
retires the daemon behind a Server you adopted. `withServer` and
`withServerIn` only adopt: closing their scope never stops a daemon.

| Entry | Starts a daemon | Stops it |
| --- | --- | --- |
| `withOwnedServer` | Yes, with a socket of its own | When the scope closes |
| `withServer`, `withServerIn` | No | No |
| `killServer` | No | Immediately, for the owned or adopted daemon |

Put tmux 3.3a or newer on `PATH`, then run the
[owned-server program](../examples/owned-server/Main.hs) from a
[provisioned checkout](../.github/CONTRIBUTING.md#toolchain). The
[README](../README.md#start-and-stop-a-server) shows its source and output:

```console
$ cabal run --verbose=0 owned-server
```

## What an owned scope does

- Creates a private directory under `/tmp` and starts the daemon on a socket
  inside it. The caller supplies no socket and no directory.
- Runs the callback with the caller's masking state. Its result, exception or
  cancellation leaves the scope with its original class.
- After the callback, signals the daemon through a process descriptor
  (SIGTERM, then SIGKILL) and treats it as stopped only when that descriptor
  reports exit. A missing socket or a finished tmux client proves nothing.
- Removes its socket and directory while their identities still match. A
  replaced name or an unexpected lock file keeps its cleanup owner for retry.
  A retained `Server` then raises `ServerClosed` from every operation.

The daemon reads no configuration file. Its global `exit-empty` option is off,
so it stays up while it has no sessions. Pane processes receive SIGHUP when
the daemon exits.

## Choose the executable and deadline

Start from `defaultOwnedServerConfig`. `tmuxExecutable` defaults to `tmux`,
resolved once through `PATH`. `operationTimeout` defaults to two seconds and
must be positive and at most ten; it bounds the version check and each
`capture`. An invalid value or a missing executable raises
`InvalidConfiguration` before the scope creates a directory or runs a process.

## Failures and uncertainty

- Cleanup runs after callback failure or cancellation; the original exception
  keeps its class.
- A known startup failure raises `OperationFailed`; catch it with `tryTmux`
  like any other operational error.
- Cleanup that fails after a successful callback raises `CleanupFailed` with
  the cleanup status and cause, as `withServer` does. The exception context
  keeps the unfinished owner when the daemon's exit was not observed within the
  bounded wait. Use `cleanupRecoveries` on the context from `tryTmux` or
  `tryWithContext`, then `inspectCleanup` to read its state and `resumeCleanup`
  for another bounded attempt. Inspection contacts no daemon.
- `awaitCleanup` waits for the daemon's process descriptor when the owner holds
  one, or for the start client's exit when it does not, then retries once.
  After a start that found no listener there is nothing to wait for: the retry
  fails and the owner stays, because no listener and a finished client do not
  prove the daemon gone. Each retry sends SIGTERM and then SIGKILL again to an
  owned daemon. Cancellation keeps the recovery reachable.
- A failed `killServer` keeps one recovery per daemon, however many handlers
  the exception passes through.

## Retire an adopted daemon

`killServer` signals the daemon whose socket the Server pinned. On Linux 6.5 or
newer, opening a Server holds that daemon's process descriptor and checks that
the daemon reports the same process ID. The check reads `#{pid}` through
`run-shell -C`, the way the version check does, so a daemon with
`after-display-message`, `after-run-shell` or `command-error` hooks runs none
of them during adoption.

Retirement uses the descriptor independently of command lanes or a responsive
daemon. A socket rebound after adoption refuses instead of stopping another
server. The call returns after observing exit and closes that Server's admission;
later operations raise `ServerClosed`.
`withServer config killServer` adopts a daemon and retires it in one step.

Adoption stays possible where no descriptor can be verified: an older kernel, a
forwarded or activated socket whose listener is not the daemon, or a daemon
that does not answer within `captureTimeout`. The callback still runs, and
`killServer` raises the failure that prevented it.

When the callback leaves, that Server's admission closes first, then the
descriptor is released. A `killServer` call that arrives after this raises
`ServerClosed` and cannot turn the release into a termination; a call admitted
before keeps its authority and finishes. Other handles of a shared `Runtime`
stay admitted.

## Limits

- Owned servers and `killServer` need Linux with pidfd support for sockets,
  kernel 6.5 or newer, in addition to the
  [native backend requirements](installation.md#native-backend-host-requirements).
- Retirement stops the daemon, not processes that outlive it. A background job
  started by a hook or `run-shell` can keep running.
- Only tmux 3.3a and 3.8 are tested; other releases from 3.3a are admitted.
- A caller-owned socket is not an option here. Use `withServer` for a daemon
  that something else started.
