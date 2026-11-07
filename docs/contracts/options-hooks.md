# Options and hooks

Proposed contracts from pinned Python and tmux 3.3/3.8 source. Runtime,
intermediate capability boundaries and lossless listing remain unqualified.

## Scope and values

Use `ServerOptions`, `GlobalSessionOptions`, `SessionOptions SessionRef`,
`GlobalWindowOptions`, `WindowOptions WindowRef` and `PaneOptions PaneRef`.
There is no global-pane store. Built-in names select their supported scope;
user `@` options use the explicit scope flags. Window storage is physical,
while value-format evaluation can require a separate session/link context.

Require complete canonical built-in names and catalogue-checked values.
Unknown options remain explicit raw values or decoding errors. Never infer
types from spelling: user values `001` and `on` remain strings. Names are
format-expanded even without `-F`; literal names and keys need proved format
encoding or a documented restricted grammar. Value-format expansion is a
separate mode and may start `#()` jobs.

| Operation | Inputs and result |
| --- | --- |
| Set | Scope, checked name/key, value and `Replace`, type-specific `Append`, or `SetIfNoLocalOverride`. Return processing evidence, with any later readback identified as an observation. |
| Unset | `RemoveLocalOverride`, `ResetGlobalBuiltinDefault`, `RemoveArrayEntry`, or `RemoveWindowAndPaneOverrides`. These have different inheritance and partial-effect rules. |
| Read one | `LocalOnly` or `Effective`, retaining origin, presence and scalar/array shape. Missing local override differs from empty value. |
| List | Bounded named entries, explicit origin/keys and optional hook inclusion. Reject ambiguous framing; never silently omit unknown entries. |

Omitted values that toggle or cycle are separate operations. Python's required
value argument does not require exposing native omission as an accidental
`Nothing`. `-o` checks a local entry/index, not its inherited value. Quiet
mode suppresses selected failures; it cannot promise `Applied`,
`AlreadyPresent` or `IgnoreAllErrors` from exit status alone.

## Arrays and inheritance

tmux 3.3 arrays have nonnegative numeric indices. The inspected 3.8 source
also accepts nonempty string keys. Preserve `NumericIndex` and `NamedKey`:
all-digit keys normalize to unsigned integers, with checked overflow;
numeric keys sort before named keys. Validate the bracket/name grammar too.
The first release supporting named keys still needs qualification.

A local array shadows the entire inherited array. A missing local index does
not inherit that index independently. Unindexed append fills the lowest free
numeric index. Indexed string append concatenates; indexed command/hook
assignment replaces its command list even with `-a`.

Whole-array replacement clears before parsing and assigning. A failure can
leave an empty or partial local array that hides the parent. Prefer ordered
keyed writes for exact element boundaries and preserve per-step outcomes.
Neither one command nor a multi-entry update implies rollback.

Unsetting a local option restores inheritance; unsetting a whole built-in in
a global/server store restores its default. `-U` can remove pane overrides
before removing the window override. Its partial effects remain visible.

## Reading faithfully

Bulk `show-options -A` includes inherited built-ins, but only local user
options. Targeted effective lookup can therefore return an option absent
from that bulk listing. A missing array entry prints an empty value; enumerate
keys to distinguish a hole from a present empty string. Do not invent origin
from an empty-array line that lacks an inherited marker.

Baseline quoted values use tmux C/octal escaping, not POSIX shell quoting.
`-v` is only suitable for a known scalar, with a qualified output protocol.
The 3.8 format metadata can expose keys, presence and inheritance; its arbitrary
fields still need framing. Unusual baseline user names can make the default
listing ambiguous. Return `UnrepresentableListing` or bounded raw output.

`after-show-options` can append output, fail, wait or mutate state. Follow the
[framing contract](framing.md); command EOF and a trailing LF do not separate
the requested value from hook output. No read API disables user hooks.

## Hooks

Built-in hooks are ordered keyed command entries. Custom `@` hooks contain
string command source. They are not interchangeable array representations.
Hook storage rejects `ServerOptions`, including for custom hooks; the native
hook commands have no server-store flag. Use explicit supported storage scope,
command plan versus raw tmux source, and modes:

| Operation | Contract |
| --- | --- |
| Set | Replace one entry, append an entry, or create a local empty hook. |
| Unset | Remove one key or the local override; the latter can restore inheritance. |
| Read/list | Preserve keys, order, empty arrays and exact command-source serialization. Distinguish local enumeration from effective lookup. |
| Batch update | `PatchEntries`, `ReplaceWithLocalEntries`, or `RemoveOverride`; ordered outcomes and undispatched remainder on failure. |
| Run | Explicit effective-context semantics and foreground completion evidence, with the target limitation below. Missing hooks can succeed without running anything. |

Python's clear-first batch unsets the override; an empty batch consequently
restores inheritance. A native replace-with-empty operation must instead
install an empty local hook. Do not combine unset/run/append booleans.

`set-hook -R` runs before scope resolution. Global/storage flags do not mean
“run exactly this stored scope.” An invalid target can fall back to another
context during hook insertion. Reject a requested strict no-fallback guarantee
until an atomic lowering is proved; preflight cannot close that race. Captured
commands executed directly are a different operation. Custom-hook parse errors
may be logged without a failing exit; a successful return is not execution proof.

Raw tmux command source can expand variables, tilde and assignments while
parsing. Registration differs from running the later action. Modern event and
format-monitor hook flags are separate capabilities, with their own lifetimes;
baseline hook-array support does not qualify them.

Conformance must cover inheritance, holes/empty arrays, named keys, failed
replacement, quiet rejection, pane-override removal, hook fallback, hook output,
partial batches and cancellation. No runtime case is passed by this document.

Sources: [3.3 set/unset](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-set-option.c),
[3.3 arrays/scopes](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/options.c),
[3.8 arrays](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options.c),
[baseline listing](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-show-options.c),
and [hook insertion](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/notify.c).
