# Behavior inventory

[python.json](python.json) maps 216 source declarations to proposed native
contracts: the 201 research rows plus 15 inherited option, hook and observed
client methods. Every implementation status remains `UNVERIFIED`.

Each source link identifies the inspected commit and declaration. Python
signatures and version guards are evidence about the reference, not Haskell
signatures or proof that a flag is available on every supported release.
Canonical keys join aliases without requiring duplicate Haskell wrappers.

The [case plan](traceability.json) joins all 177 canonical behaviors to 61
shared scenarios. Each scenario gives its fixture, action, expected result,
counterexample, owning epic task and planned example/test locations. The
inventory's `case_specification` is a JSON Pointer into that file. Aliases
share the canonical case rather than requiring duplicate wrappers or tests.

All case-plan examples and tests are `PLANNED`; their paths name later work,
not existing executable files. Existing private graph and scalar tests are
listed separately as partial evidence. They do not pass the planned public
API scenarios. Detailed operation modes remain in the contracts below.

The [environment contract](environment.md) specifies visibility, removal
markers and byte preservation. Lossless full-listing qualification remains
open; the document does not claim an implemented environment API.

The [observation contract](observations.md) specifies ordinary collections,
contextual multiplicity, pure access and cardinality. Removed Python wrappers
map to native record and list operations rather than duplicate public methods.

The [interaction contract](interactive.md) distinguishes processed requests,
UI termination, attachment and waiting jobs. Source findings require different
pane-number targets and run-shell output contracts across tmux releases.

The [creation contract](creation.md) distinguishes historical creation receipts,
reuse acceptance, current-occupant slots and destructive modes. Relative
insertion or replacement can change topology even when a command fails.

The [option/hook contract](options-hooks.md) distinguishes inheritance,
array keys, partial updates and effective-context hook execution. The
[buffer/configuration contract](buffers-config.md) covers byte transfers,
named deletion, key tables and partial configuration effects.

The [framing refinement](framing.md) records a reproduced scalar-decoding
hazard: successful commands can append after-hook output to their values.
The [private socket pin](socket-pin.md) specifies byte paths, ancestor trust,
link-time adoption and retained cleanup ownership. The
[private process owner](process.md) specifies byte arguments, stream bounds,
atomic child ownership, host requirements and retained cleanup. Public
runtime leases and bootstrap remain separate qualification work.

The [acquisition contract](acquisition.md) separates environment hints,
fresh observations, native diagnostics and raw commands. The
[pane/window contract](pane-commands.md) specifies creation, movement,
rendering, input and UI modes, including partial effects and migration changes.

The native boundary keeps acquisition in `IO`, observations detached, and
physical windows separate from their session links. In particular, floating
pane creation is distinct from tiled splitting, and a physical pane has no
unique session without an occurrence context.

Before an operation passes, replace its proposed API with the implemented
public declaration and record exact input, target, output, completion,
capability and conformance evidence. Interactive commands, client-name
reuse and starting a daemon without creating a session retain explicit
qualification work. This inventory does not establish behavioral parity.
