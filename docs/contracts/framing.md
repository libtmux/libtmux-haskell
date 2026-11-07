# Scalar output and hooks

Proposed transport refinement. The owned research probe reproduces the issue
and checks the candidate on official tmux 3.3 and 3.8. It is not a qualified
Haskell transport or a complete capture protocol.

## One evaluation, one envelope

Removing the final LF from `display-message -p` is insufficient. Both tested
releases append output from an `after-display-message` hook to the same stdout.
A successful exit can therefore contain the requested scalar and extra text.
The library must not silently store that text as part of the observation.

For a closed catalogue field, generate a fresh 256-bit nonce in `IO`, encoded
as 64 lowercase ASCII hex digits. Expand the field once between fixed prefix
and suffix bytes containing that nonce. Require the prefix at byte zero and
the suffix plus command-added LF at EOF. Consume the two boundaries sequentially
so they cannot overlap on an empty payload. Reject a nonce within the payload,
missing boundaries, or any extra bytes. Copy the accepted payload before
releasing the transport buffer. Bound the complete response, framing overhead
and stderr separately; the scalar limit applies to the decoded payload.

Every scalar command client explicitly uses `-u`. Without that client flag,
tmux can sanitize non-ASCII bytes according to locale before printing a
structurally valid frame. The probe checks altered output without `-u` and
exact preservation with it under `LC_ALL=C` on both releases.

This preserves embedded and trailing newlines, invalid UTF-8 and other
non-NUL bytes. Conversion to a declared text field is a later checked decode.
An accidental nonce collision is an explicit framing failure; it must not
trigger automatic mutation replay. The nonce comes from the library after
earlier input, never from caller data. It is a correlation marker under the
trusted local-daemon/configuration contract, not authentication.

Do not compute a length by expanding a field twice. In tmux 3.3,
`format_find` invokes built-in table callbacks for each occurrence. OS-derived
values can change between evaluations. The separate cache for custom format
entries does not make every built-in field stable. A length computed from one
evaluation need not describe a second evaluation's bytes.

## Hooks and target context

Leave configured hooks intact. A hook can mutate state, wait, fail or emit
output during an otherwise observational command. Extra output fails the
strict decoder; a hook failure remains a command failure even if a scalar
frame was printed first. No-output hooks can still change state, so the
result is an observation during an interval, not a transaction.

Framing alone does not prove target identity. The final protocol must include
and validate line-safe actual context IDs where the command permits target
fallback. Each required field also needs a mapping and capability check;
an unsupported format becoming an empty string is not supported absence.
The probe uses a known live pane and a stored user option, so it does not
qualify either of those conditions.

Topology listings need their own bounded, nonce-qualified record protocol,
including empty results and unexpected hook output. Arbitrary option listings,
binary buffer output and raw commands retain their separate contracts. This
single-scalar candidate must not be generalized to them without evidence.

## Evidence and supersession

The research artifacts `probes/scalar-hooks.py` and
`data/implementation/scalar-hooks.json` preserve the command bytes, binary
digests, stdout/stderr, exit codes and observed daemon/pane exits. The candidate
recovers a value containing embedded/trailing LF, tab, quotes, backslashes,
format syntax, semicolon, Unicode and an invalid UTF-8 byte. It rejects appended
hook output, overlapping boundaries and an intentionally injected nonce
collision on both releases. The original probe/result remain as `scalar-hooks-v1`
artifacts; they inherited locale and lacked the overlap rejection.

This refines the approved architecture's scalar-final-LF rule. The architecture
already requires unexpected hook output to fail; the earlier decoder rule
could not enforce it. Its approved historical digest remains intact. Final
adoption requires independent review, Haskell decoder tests, limits, context
receipts, command errors, cancellation and the complete compatibility matrix.

Sources: [3.3 scalar command](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-display-message.c),
[format lookup](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/format.c),
and [registered after-hooks](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/options-table.c).
