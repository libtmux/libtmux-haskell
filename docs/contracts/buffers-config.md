# Buffers, key bindings and configuration

Proposed contracts from pinned Python and tmux 3.3/3.8 source. These operations
remain unimplemented and unqualified. All effects use the pinned generation,
bounded processes and explicit targets/modes.

## Buffers

`NamedBuffer`, `TopAtDispatch` and `NewAutomaticBuffer` are distinct choices.
A name selects its current contents, not a persistent buffer incarnation.
Automatic creation can evict old automatic buffers under `buffer-limit` and
does not return a generated name. Looking up “top” afterward cannot establish
creation identity. Choose an explicit fresh name when a reusable selector is
required.

| Operation | Inputs, results and completion |
| --- | --- |
| Set | NUL-free command data; explicit named/automatic selection and replace/append. Empty input succeeds without changing a buffer. |
| Read | Explicit named/top selector; return exact `ByteString` from an unattached one-shot client. Preserve trailing LF and invalid UTF-8. |
| Delete | Explicit named/top selector and qualified capability. Named deletion is unsafe in the inspected 3.3 handler. |
| Load | Bounded caller bytes through stdin, or explicit tmux file mode. Wait for file-read callback and command completion. Empty input succeeds without replacing/creating. |
| Save | Raw stdout acquisition, or explicit file overwrite/append. Report processing and partial-write uncertainty; no atomic publication or fsync guarantee. |
| List | Framed bounded metadata with explicit ordering, or raw formatted output. Display samples are escaped/truncated previews, not contents. |

Named append creates a missing buffer. Append without a name does not append
to the top buffer. `set-buffer` uses `strlen`; binary replacement must use the
bounded `load-buffer -` path. tmux supplies no atomic arbitrary-binary append
through that command; read/modify/write is a separate racy composition.

In tmux 3.3, `delete-buffer -b missing` falls back to the top buffer and can
delete unrelated data. The inspected 3.8 source rejects the missing name.
Refuse strict named deletion on an unqualified implementation. A preflight
lookup cannot make the old handler safe. Establish the first fixed release
and test disappearance/reuse before enabling it. Even the fixed operation
selects the name's current contents.

Ordinary unattached clients use raw byte file transfer; attached/control
clients take different paths. Output framing must account for after-hooks
without trimming actual buffer bytes. Default list order is recency; newer
sort modes require capabilities or explicit local sorting. Buffer names and
format output need qualified framing. `after-list-buffers` can add output or
effects; it must not become a metadata row.

Load/save paths are tmux formats and may start `#()` jobs. Relative paths use
the command-client working directory, and file I/O may be delegated back to
that client. Do not label every path as server-local or expand a home directory
implicitly. A bounded caller-file import reads with a byte cap then feeds
stdin; checking size before tmux reads a mutable path is insufficient.

## Key bindings

`bindKey` accepts a checked key, `RootTable`, `PrefixTable` or named table,
command plan/raw tmux source, optional note and repeat policy. It installs or
replaces a binding; the eventual key press runs the action in its later
context. Raw parsing can have parse-time effects. Native note-only updates
are a separate optional operation, not a binding-created guarantee.

`unbindKey` selects `OneKey table key` or `AllKeysInTable table`. Native `-a`
without `-T` clears only the default prefix table. A missing explicit table
can return an internal command error with empty stderr under quiet mode; never derive success or
`AlreadyAbsent` from suppressed diagnostics.

Keep raw listings separate from structured binding observations. Baseline
padded command output loses notes and does not safely quote arbitrary table
names; it is not a complete export. Newer `-F` metadata still needs framing.
The notes view is a distinct projection. Preserve the no-start policy on
`list-keys`, which can otherwise start a daemon. Its after-hook can emit data
or run work after the listing.

## Configuration

`sourceConfig` selects `Execute` or `ParseOnly`, literal caller file versus
explicit glob/format path versus bounded stdin bytes, missing-file policy
and diagnostics. tmux always glob-expands path arguments. Use proved glob
escaping or feed exact file bytes through stdin for a literal file.

Parse-only suppresses configuration command execution and parser assignments.
It does not make an unrestricted path-format expansion effect-free: that
earlier expansion can start jobs. Parser conditional expansion disables jobs,
which is a separate rule. Quiet mode suppresses unmatched paths, not every
read/parse error. Verbose output is diagnostic data.

Execution is not transactional. Earlier files, commands or assignments can
take effect before a later failure. Return known progress and uncertainty,
not invented per-line success. Foreground waiting work uses the waiting lane;
background descendants require separate completion evidence. Cancellation
retains unknown job debt and never triggers automatic replay.

tmux 3.3 has no `source-file -t`; newer context flags need qualification.
An explicit config profile requires targeted commands. Unrestricted config
execution explicitly accepts tmux's native context semantics. Neither a
context flag nor a preflight proves arbitrary commands target only one object.
Modern recursion limits do not establish a baseline total-work bound.

Conformance must cover disappearing/reused names, NUL/newlines, empty input,
partial writes, path globs/format expansion, odd table names, hook output,
parse-only behavior, partial execution, waiting work and cancellation.

Sources: [3.3 buffer mutation](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-set-buffer.c),
[3.8 named lookup](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-set-buffer.c),
[binary transfer](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-save-buffer.c),
[key listing](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-list-keys.c),
and [configuration execution](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-source-file.c).
