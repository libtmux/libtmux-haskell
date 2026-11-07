# Acquisition and server diagnostics

These are proposed native contracts from the pinned Python and tmux 3.3/3.8
sources. They are not implemented or runtime-qualified. Remaining output,
encoding and capability questions are implementation gates, not permission to
omit required operations.

External acquisition and mutation use explicit `IO`, the pinned generation,
no-start transport and bounded ownership. Validate mutually exclusive modes,
checked values and capabilities before dispatch. Preserve asynchronous
cancellation. Completion means command processing, including documented no-ops;
it does not prove target survival, application consumption or later UI action.
Retain primary receipts if a later observation fails. Errors can follow partial
effects; uncertain outcomes are never automatically replayed.

Physical references identify entities. Explicit context identifies a session,
window link or native current occupant where required. A bare pane/window ID
does not select a unique session. Contextual preflight is not a reservation.

## Required modes

| Contract / source operation | Input and target | Result and completion |
| --- | --- | --- |
| A1 — `server.from-env`; `session/window/pane.from-env` | Supplied environment mapping, or an explicit `IO` environment read. Parse `TMUX` from the right into three components; require numeric entity IDs rather than Python's prefix-only pane check. | Pure parsing returns endpoint/entity **hints**, not a connected client or authenticated server lifetime. Connecting and acquiring observations are separate `IO`. Missing/malformed environment is an error. Session/link context must be supplied or returned as alternatives; do not invent a unique session from a multiply linked pane. |
| A2 — `session/window/pane.refresh`, their `from-*-id` operations | Pinned client plus typed ID/ref. Refresh takes a physical entity, or a separately declared contextual slot/occurrence. | Return a new detached observation; retain the old value. Missing ID is `TargetMissing`, inconsistent capture is an acquisition error. Physical window/pane lookup must normalize physical data while preserving separate occurrences; contextual lookup returns ambiguity instead of Python's preferred-link heuristic. |
| A3 — `client.refresh`, `client.from-client-name` | Pinned client plus exact observed name/tty selector. | Return a fresh `ObservedClient` with observation time and current-name-occupant semantics. A matching name does not prove the same client lifetime. Zero matches is missing; duplicates are ambiguous. No strong client identity or continuous attachment claim. |
| A4 — `server/session/window/pane.cmd` | One explicit native argv request or explicit tmux command sequence; caller supplies operation-specific target options. Entity convenience forms must disclose which argv they construct. | Return bounded raw stdout/stderr and exit/dispatch evidence. Nonzero status remains available; typed wrappers classify failures. No inferred per-command success for a sequence, transaction, read-only status, or process completion. Unknown commands use conservative waiting admission; they may outlive the caller. |
| A5 — `server.has-session` | `ExactName`, `SessionId`, or an explicitly native tmux selector; pinned endpoint. | Return `Bool` only after successful acquisition or a qualified missing-target classification. Connection, permission, ambiguous-selector, and decoding errors remain errors. Exact-name matching can use a validated capture; do not reduce every nonzero exit to `False`. |
| A6 — `server.list-commands` | All commands, or exact registered name/alias. | Prefer acquire-all then exact local matching for a consistent finite catalogue. Return definitions or raw documented command output; unknown exact name yields no match. Native selector mode is separate: 3.3 uses exact matching and succeeds empty, while 3.8 resolves command prefixes and errors for unknown/ambiguous input. Keep `-N` despite the native command's start-server flag. |
| A7 — `server.list-clients` | Pinned endpoint; no implicit session filter. | Preserve the source's rendered-output operation as diagnostic bytes, distinct from typed client acquisition. Native listings include attached clients, not all transient command clients. Typed acquisition needs its own framing and observed-client lifetime contract. |
| A8 — `server.server-access` | `ListAccess`, `AddUser user permission`, `SetUserPermission user permission`, or `DenyUser user`; explicit read-only/write permission. | List returns diagnostic output unless a structured codec is qualified; mutations return completion. Add errors if already present; setting permission may add an absent user. Unknown user, server owner/root, incompatible modes, and denied permissions are errors. Denial can disconnect matching clients; completion is not proof every connection has closed. Group access is a separately gated extension. |
| A9 — `server.show-messages` | Log, jobs, terminals, or jobs-plus-terminals; explicit native client selector when required. | Return diagnostic bytes. Logs/jobs are server data, not a per-client log collection. 3.3 requires client resolution; 3.8 permits failure and a missing terminal selector can broaden to all terminals. A strict client-scoped variant must refuse until supported; an explicit best-effort native-selector variant must disclose fallback. Remove the copied AllClients/AllExcept target contract. |
| A10 — `server.show-prompt-history`, `server.clear-prompt-history` | All histories or a checked prompt type; pinned endpoint. | Show returns rendered diagnostic bytes, preserving headers/newlines; clear returns processing completion. Invalid type is an error. Clearing command-prompt history does not clear a pane shell's history. |

## Acquisition boundaries

Environment parsing returns hints. It does not authenticate a daemon or mint
live references. Read process environment in a separately named `IO` operation;
parse a supplied mapping purely. Stored session IDs from `TMUX` can be stale;
resolve current occurrences explicitly and preserve ambiguity from linked windows.

Rendered client listings and typed observed-client acquisition are distinct.
The native list includes attached clients, not every transient command client.
Declare that scope when documenting completeness. A client name/tty remains a
current-occupant selector, even when a later observation has the same spelling.

Raw commands explicitly retain native targeting and effect semantics. They
cannot inherit a typed command's stronger guarantee from the receiver name.
Unknown waiting behavior uses conservative admission; nonzero exits remain
available rather than becoming empty collections or `False`.

Sources: [Python environment parsing entry point](https://github.com/tmux-python/libtmux/blob/957d4bdcfbf978607fb58a6c0f167d74ec3137ec/src/libtmux/server.py#L203),
[3.3 target resolution](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-find.c),
[client listing](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-list-clients.c),
and [modern diagnostics](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-show-messages.c).
