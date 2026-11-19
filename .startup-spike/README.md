# Threaded native guardian proof

This disposable Linux x86_64 model replaces the freshly exec'd guardian with a
raw-syscall helper acquired through atomic `CLONE_PIDFD`. It does not execute a
Haskell scope or establish production readiness. The isolated parent fixture
temporarily acts as a subreaper to collect its own fault-test orphans; that
information never clears candidate debt after guardian loss.

Run the native ownership and host-state cases through the resource wrapper:

```console
$ /home/d/tmp-wave/heavy.sh -- \
    python3 .startup-spike/probe_native_host.py \
    --tmux "$LIBTMUX_TEST_TMUX" \
    --output "$LIBTMUX_GUARDIAN_EVIDENCE"
```

The command compiles a shared library with `-Wall -Wextra -Werror`, audits its
disassembly and runs 19 isolated cases. The audit rejects helper calls outside
the `h_` symbol set, indirect calls and TLS accesses, including libc calls or
stack-protector paths. Compiler suffixes such as `.constprop.0` retain the same
helper classification. Source and native-library SHA256 digests accompany the
audit. Each event phase has the same 900 ms deadline; there are no sleeps.

Each guardian is created by a nonleader OS thread while at least four host
threads exist. The creating thread joins before admission; the guardian must
remain alive. Signals are blocked across raw clone, the helper isolates its
session and resets inherited dispositions, and the host restores its exact
previous mask. The helper closes inherited host descriptors before readiness.
No helper `PDEATHSIG` ties its lifetime to the creating host thread.

The helper sets `PR_SET_CHILD_SUBREAPER` before any configured executable runs
and remains the exclusive reaper. It proxies all test version, startup and
ordinary command clients. Each command uses `CLONE_PIDFD` and the host records
its pending request before sending it. Listener adoption accepts only a current
unreaped direct child, authenticated against the guardian's own kernel child
list and pidfd. Listing never overlaps reaping. The final proof does not rely
on that list being a complete birth journal.

At closure the single-threaded guardian closes birth admission, signals current
child pidfds, reaps and repeats for newly adopted children. It publishes a
terminal proof only after live `wait4(-1, __WALL | WNOHANG)` returns `ECHILD`,
then exits without another fork. The host requires that proof, the helper's
physical exit, every published child pidfd's physical exit and all client pipe
EOFs. Guardian loss without the proof remains debt even after every known
witness later exits.

The ownership cases cover native empty-daemon readiness, both independently
demonstrated launcher counterexamples, adoption after launcher exit, nonleader
thread exec, unpublished child birth, cancellation and helper loss at that gap,
daemon and helper kill after admission, version/client launcher descendants and
an original pane, concurrent contexts and foreign-adoption refusal, plus socket
or directory replacement during physical retirement and exact-name recovery.
Independent child-self pidfds arrive over a separate SCM_RIGHTS channel.

Host cases also cover SIGCHLD `SIG_IGN` and `SA_NOCLDWAIT` refusal before birth,
host mask restoration and child signal state, unchanged host subreaper policy,
an unrelated host child remaining live and collectible only by its fixture,
closure of inherited host descriptors, and closed standard descriptors. The
closed-descriptor fixture explicitly retires or duplicates its own low pidfd
before restoring standard descriptors, so restoration cannot recycle a held
capability.

Source rationale: Linux `find_new_reaper` reparents ordinary orphan descendants
to a living ancestor subreaper. `eligible_child` includes all child kinds under
`__WALL`; `__do_wait` retains `ECHILD` only when no eligible child could later
match. With birth admission closed and no surviving direct child, there is no
surviving ordinary descendant chain that can create another child. Inspected
Linux source is pinned at `ddd664bbff63e09e7a7f9acae9c43605d4cf185f`,
`kernel/exit.c` and `fs/proc/array.c`. The proc iterator's concurrent-removal
warning is why enumeration never overlaps reaping and the final verdict comes
from `wait4`. The raw x86_64 syscall convention follows the preserved R3 helper
layer; the new terminal ownership argument does not use R3 journal balance.
See also the public
[subreaper manual](https://man7.org/linux/man-pages/man2/PR_SET_CHILD_SUBREAPER.2const.html).

Production obligations remain open: Haskell acquisition publication and
exception/cancellation preservation, pending remote births retaining ticket and
budget credits, guardian-forwarded status collection through retry paths, all
owned Process pools including Program inheriting the execution domain, bounded
nonblocking transport, TERM/grace/KILL policy (the model uses immediate
SIGKILL), complete native vector/cwd/refusal semantics and released-endpoint
Haskell CI. The model uses fixed bounds and blocking private transport; it is
an ownership experiment. No pidfd exit-status ioctl support-floor increase is
assumed. Independent external service-manager births and injection into
unrelated processes remain outside its ordinary descendant-tree model.
