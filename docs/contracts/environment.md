# Environment operations

Proposed contract; implementation and release-matrix qualification are pending.
These five operations cover the environment mixin in the pinned Python
inventory. They operate on an explicit global or exact-session scope through
the client generation. None selects a current session implicitly.

An environment name is a nonempty byte string without NUL or `=`. A value is
a byte string without NUL; newlines, `=`, quotes and invalid UTF-8 are data.
Text helpers perform explicit encoding or return a decoding error. Format
expansion requires an `ExpandedFormat` value; ordinary values stay literal.
An expanded value names an exact session for format context. For session
storage that context must be the same session. Window and pane variables use
that named session's execution-time active context.

Global expansion uses two explicit steps: evaluate with verified context,
then write the resulting literal bytes globally. Preserve partial outcomes
and the race between steps. Baseline `set-environment -g -t ... -F` can write
despite a missing target, so passing `-t` alone cannot establish the context.
The expansion's context receipt still needs protocol qualification. A missing
or unproved context must prevent the dependent write. An exact-pane format
uses the same separate-expansion contract.

## Values

An entry has a visibility (`Visible` or `Hidden`) and a state (`Set bytes`
or `Removed`). Absence is `Nothing`, distinct from all four entry variants.
An empty set value is still present. Hidden entries are omitted from an
ordinary `show-environment` response; empty output cannot establish absence.

| Canonical operation | Input | Result and completion |
| --- | --- | --- |
| `common.set-environment` | Scope, name, literal value or explicit format, visibility | Set command accepted; read the exact name in both visibility modes and return the resulting entry. A literal write must match the requested bytes and visibility. A format write returns the expanded value observed. |
| `common.unset-environment` | Scope, name | Delete the entry using `-u`; verify absence in both visibility modes. This can expose a global value to subsequently created session processes; it does not remove that global entry. |
| `common.remove-environment` | Scope, name | Store a removal marker using `-r`; return its observed visibility. Existing hidden state can survive the transition. This is not deletion. |
| `common.getenv` | Scope, exact name | `Maybe EnvironmentEntry`, after bounded one-shot reads and decoding. A missing session or failed transport is an error, not `Nothing`. |
| `common.show-environment` | Scope | A complete, ordered environment observation, or an explicit acquisition/framing error. No ambiguous listing becomes a map. |

Command completion requires child exit and fully drained pipes. Follow-up
observations describe their capture interval, not durable state or transaction
isolation. A failed verification after an accepted write preserves that partial
outcome. Cancellation never implies that the write was undone.

## Framing

For exact-name reads, remove exactly the command-added final LF, then validate
the complete supplied name and the `=` or removal-marker prefix. Never split
values at embedded newlines. Check ordinary and hidden output separately;
conflicting observations trigger bounded retry, then `CaptureChanged`.
Successful empty output in both modes is also inconsistent, not absence.
`Nothing` requires the command's exact unknown-variable failure, classified
separately from a missing session, failed transport and malformed diagnostics.

tmux 3.3's raw listing has no unambiguous record delimiter. Its shell output
escapes values but leaves names unescaped. The implementation must qualify a
strict parser and verify its candidate names; if it cannot prove the listing
complete, it returns `UnrepresentableListing`. It must never execute that
shell output. Exact-name reads remain available for unusual names.

The inspected tmux 3.8 source has an environment format loop exposing name,
value, hidden and removed fields, plus a byte-length modifier. A length-framed
listing is a candidate backend for that capability. Its first supported
release, escaping, limits and live behavior remain unverified. This candidate
does not raise the library's plain-3.3 floor.

## Required cases

Cover global and session scope; set, empty, missing, hidden and both removal
states; inherited global values; literal format-looking strings; explicit
format expansion; tabs, newlines, quotes and invalid UTF-8; names containing
listing syntax or a leading dash; values ending in semicolons; names changing
during acquisition; session deletion; and
cancellation after dispatch. Assert absence only after a successful lookup
protocol. Verify each capability on every required release where it is claimed.
Argument-vector execution alone does not handle tmux's own command separators;
the transport must prove literal lowering separately.

Source evidence: [Python environment operations](https://github.com/tmux-python/libtmux/blob/957d4bdcfbf978607fb58a6c0f167d74ec3137ec/src/libtmux/common.py#L58),
[baseline output encoding](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-show-environment.c),
and [baseline removal semantics](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/environ.c).
