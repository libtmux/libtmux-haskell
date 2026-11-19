# Private lifetime guardian model

This disposable model tests Linux descendant ownership. It does not execute a
Haskell scope or qualify a production implementation. Its parent fixture is an
isolated subreaper solely to collect its own fault-test orphans. That fixture
information never changes a candidate verdict after guardian loss.

Run one endpoint through the required resource wrapper:

```console
$ /home/d/tmp-wave/heavy.sh -- \
    python3 .startup-spike/probe_guardian.py \
    --tmux "$LIBTMUX_TEST_TMUX" \
    --output "$LIBTMUX_GUARDIAN_EVIDENCE"
```

The runner compiles a fresh single-threaded helper and isolates every case in a
separate fixture process. Every wait uses descriptor readiness, inotify,
signalfd, pipe EOF or a collected status; there are no sleeps. A phase exceeding
900 ms fails and the isolated fixture retires only its own kernel children.

The helper sets `PR_SET_CHILD_SUBREAPER` and a waitable SIGCHLD policy before any
configured executable runs. It remains the sole reaper. A command birth uses
`CLONE_PIDFD`; the host journals its pending request before sending it. The
helper also accepts only listeners that match its own unreaped kernel children.
Its `/proc/self/task/<tid>/children` reads provide signal authority only for
those actual children. No global PID, argv, UID or socket-prefix search occurs.

At closure, the single-threaded helper closes birth admission, signals child
pidfds, reaps and repeats for newly adopted descendants. It publishes a terminal
proof only after a live `waitpid(-1, __WALL | WNOHANG)` returns `ECHILD`, then exits
without another fork. The host requires that proof, the helper's physical exit,
and physical exit through every held published child pidfd. Helper loss without
the proof leaves debt even after every known witness later exits.

The model covers both independently demonstrated launcher counterexamples,
adoption after parent exit, nonleader thread exec, unreported child birth,
cancel and helper kill at that gap, daemon and helper kill after admission,
version and ordinary client launcher children, an original pane, concurrent
contexts and refusal of foreign adoption, configuration isolation, and socket
or directory replacement while physical ownership ends. Independent child-self
pidfds arrive over a separate SCM_RIGHTS channel. Replacement names retain
namespace debt until the exact original identities are restored.

Source rationale: Linux `PR_SET_CHILD_SUBREAPER` reparents orphan descendants to
the nearest living ancestor subreaper. The exclusive-reaper policy prevents a
listed direct child's PID from recycling before pidfd acquisition. Kernel
`eligible_child` treats `__WALL` as all child kinds; `__do_wait` preserves
`ECHILD` only when no eligible child can later match. With birth admission
closed and no surviving direct child, there is no surviving ordinary descendant
chain that can create another child. This is an ownership argument based on the
live kernel hierarchy, rather than a claim that every physical birth was
journaled. It assumes an ordinary OS descendant tree: spawning through an
independent external service manager or injection into unrelated processes is
outside this model.

Inspected source: Linux checkout `ddd664bbff63e09e7a7f9acae9c43605d4cf185f`,
`kernel/exit.c` (`find_new_reaper`, `eligible_child`, `__do_wait`) and
`fs/proc/array.c` (`get_children_pid`, `children_seq_show`). The proc iterator
explicitly warns about concurrent child removal. This helper never reaps while
reading or authenticating that list and never enables automatic reaping;
newly adopted entries can be found in subsequent closure waves. The final
verdict comes from `waitpid`, not from a possibly incomplete proc listing.
The public manual documents the subreaper behavior:
[PR_SET_CHILD_SUBREAPER](https://man7.org/linux/man-pages/man2/PR_SET_CHILD_SUBREAPER.2const.html).

Production obligations still open: raw post-clone safety when invoked from
threaded Haskell (this model is a freshly exec'd helper), safe atomic host
acquisition and cancellation publication, bounded nonblocking transport and
status forwarding, TERM/grace/KILL policy (the model uses immediate SIGKILL),
integration with every owned Process pool including Program's separate Runtime,
and full Haskell exception/recovery/released-endpoint CI proof. No support-floor
increase from pidfd exit-status ioctls is assumed.
