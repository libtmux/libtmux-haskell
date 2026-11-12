# Creation, lifecycle and contextual mutations

Proposed contracts; runtime qualification is incomplete. Source inspection
covers tmux 3.3 and 3.8. Owned-server probes confirm the reuse receipts and
name/link cases described below, not the whole lifecycle or mutation protocol.

## Startup and liveness

Plain `startDaemonAt` takes an unresolved endpoint and returns `StartAccepted`
after command completion. It creates no implicit session, changes no lifetime
option and does not use foreground `-D`. Success does not promise that an
empty daemon remains alive or return a pinned client. This is an explicit
startup operation; ordinary pinned operations keep the no-start flag.

Liveness must distinguish a live empty pinned daemon, confirmed retirement,
and transport failure. A failed `list-sessions` call alone proves neither
death nor an empty server. `requireAlive` raises the concrete unavailable
error only when death is established; it must preserve unrelated acquisition
errors and cancellation.

Killing a server is an explicit operation on the pinned generation. Retire
its references and report the established completion/uncertainty evidence.
Client close remains a separate operation that releases library resources.

First-session bootstrap is separate from ordinary creation through an
existing client. It retains the actual created session ID, proves the live
creating connection with fresh nonce challenges, pins the socket, and checks
the same daemon/session before admitting dependent mutations. Failure returns
known creation receipts and uncertainty without automatic replay or rebinding.

## Private receipt protocol

The [private command protocol](../../internal/LibTmux/Internal/Command.hs)
decodes the IDs printed by a detached `new-session -P -F` through an existing
pin. A nonce binds the daemon PID, session, initial window/pane and link index
to one response. Primary rejection, successful creation, following hook
errors and incomplete native completion remain distinct. The decoder retains
a complete receipt when the supplied following bytes are truncated or exceed
its limits. The process owner's [bounded stdout journal](process.md#streams-and-bounds)
retains observed prefix bytes after cancellation and stream overflow.

The [owned-server cases](../../test/integration/CommandIntegrationTest.hs)
cover duplicate names, control-shaped hook output and deletion after the
receipt. A hook barrier permits pidfd tracking before deletion or command-client
cancellation.

The [private Runtime](../../internal/LibTmux/Internal/Runtime.hs) admits checked
detached-session options in its serialized mutation lane. Its creation request
pairs the usual operation receipt with an independent journal of observed IDs.
Native registration publishes the bounded stdout-prefix reference in the same
transaction as child ownership. The journal retains neither the native ticket
nor caller arguments, environment or complete output. It remains readable after
native cleanup and Runtime closure.

The [Runtime cases](../../test/integration/RuntimeCreationTest.hs) distinguish
known creation, primary rejection, hook errors and uncertain completion. They
retain observed IDs through cancellation, deadline and output overflow, and
exercise explicit recovery without replay. Queue cancellation and allocation
failure do not invent a creation receipt. Launch cwd and environment are
explicit inputs; they do not silently inherit the read transport's fixed
context. First-server bootstrap and a public creation operation remain open.

## Creation and reuse

| Intent | Input and result |
| --- | --- |
| Create session | Pinned client and checked options; detached by default. Return the actual created session/window/pane receipt. Attachment is a separate terminal-owning mode. |
| Replace session | Explicit old session reference and new-session options. Report ordered destruction and creation outcomes. If the daemon retires between them, creation is not silently redirected to a new daemon. |
| Create window | Placement, collision policy, creation options and operation-specific selection policy. Return actual session/index/window/pane IDs from the creation receipt. |
| Reuse or create window | Explicit reuse selector and selection request. Return `Created receipt` or `ReuseAccepted selector policy`; reuse supplies no invented reference. |

Window placement is `NextFree SessionRef`, `At WindowSlot`, `Before WindowSlot`
or `After WindowSlot`. Relative wrappers retain their anchor context. Keep
reuse and replacement mutually exclusive. Cwd, environment, shell/native argv,
geometry and names retain their checked input domains and capability checks.

Both probed releases return empty output when `new-window -S` reuses a window,
even with `-P -F`. With `-d`, reuse also skips selection. Explicit-index reuse
fails on an occupied slot in 3.3 but can succeed in 3.8. Name matching counts
links: two links to one physical window can be ambiguous.

Creation expands the window name as a tmux format in both releases. Reuse
matching differs: 3.3 compares the raw argument, while 3.8 expands/cleans it.
A uniform literal-name reuse mode still needs a proved lowering. Argument
separation alone is insufficient. Unsupported guarantees fail before dispatch.

A `Created` receipt records creation, not current liveness. Its `-P` output
precedes after-new-window hooks, which can destroy the new object before the
caller receives it. Preserve that receipt if subsequent verification fails.
Only line-safe IDs and indices belong in the receipt; read names separately.

The pinned Python new-session wrapper does not implement `-A` reuse and ignores
its variadic arguments. Native session reuse is a separate possible extension,
not inherited parity. Do not add it by interpreting ignored arguments.

## Slots, groups and partial effects

`WindowSlot` means the occupant of an exact session/index at execution time.
Move, swap, unlink and selection use that explicit context. A physical window
ID alone does not choose which link to move. Linking uses a source slot, or a
separately qualified session-plus-window target. An expected-window variant
requires an atomic check; a preflight lookup cannot establish that guarantee.

| Operation | Scope and evidence |
| --- | --- |
| Select | One slot's current occupant; verify the session's later selection only as an observation. |
| Move/link | Explicit source context and destination placement/collision policy; retain possible insertion and group effects on failure. |
| Swap | Two explicit slots and a swap-specific selection mode; same physical window can make this a no-op. |
| Renumber | One exact session; this is separate from move, matching `move-window -r`. |
| Unlink | One slot, with tmux's link-protection policy or explicit permission to remove the last link. Session-group/reference counts determine protection. |

Relative insertion can shift indices before spawning or linking later fails.
Replacement can remove a destination link before allocation or fork failure;
the displaced physical window may remain through another link. Session groups
can propagate changes beyond the named session or reject a move/swap between
group members. Report attempted operations, known receipts, errors and unknown
effects without inventing per-step success or promising rollback.

Selection flags are requests with command-specific behavior. Replacing the
current link can force selection despite detached/no-select flags. Swap's
`-d` path also changes selected slots. Do not expose a generic “preserve
selection” guarantee across these commands.

## Destruction variants

| Intent | Required distinction |
| --- | --- |
| Kill one session | Exact session reference; other linked sessions/windows can survive. |
| Kill other sessions | Exact survivor session, with operation-specific completion evidence. |
| Kill session group | Capability-gated group semantics; the flag is absent from 3.3. |
| Clear session alerts | `-C` clears alerts without killing. It is a separate operation, not a kill modifier. |
| Kill physical window | Removes that window across its links. |
| Native bulk window kill | Retains tmux's session-context rule: **a repeated target window can also be killed**. It must not promise that the target survives. |
| Kill one pane | Exact physical pane; removal is distinct from proof that all descendant OS processes exited. |
| Kill other panes | Target pane is the survivor, so target absence is the wrong postcondition. |

These intents are sum-type modes, not freely combined booleans. Intermediate
capability boundaries and exact group/selection behavior remain qualification
work. Cases must include replacement/fork failure, last-session retirement,
repeated links, session groups, alert clearing, hooks that destroy creations,
missing receipts, and cancellation after dispatch.

Sources: [baseline new-window](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-new-window.c),
[3.8 new-window](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-new-window.c),
[spawn ordering](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/spawn.c),
[move/link](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-move-window.c),
[kill/unlink](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-kill-window.c),
and [session kill/clear](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-kill-session.c).
