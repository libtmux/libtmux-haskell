# Scalar and record framing

The capture protocol must preserve observed field bytes across the required
tmux releases, reject unrelated hook output and stay within declared bounds.
The [ADR qualification record](../decisions/0001-native-domain-model-qualification.md)
separates measured research from Haskell implementation acceptance.

## One evaluation, one envelope

For a closed catalogue field, generate a fresh 256-bit nonce in IO, encoded
as 64 lowercase ASCII hexadecimal digits. Expand the field once between
fixed prefix and suffix bytes containing that nonce. Require the prefix at
byte zero and suffix plus command-added LF at EOF. Consume boundaries
sequentially so they cannot overlap on an empty payload. Reject a nonce in
the decoded payload, missing boundaries or extra bytes. Copy accepted bytes
before releasing transport ownership.

Every scalar command client uses `-u`. That flag is necessary but does not
make every release print raw bytes. tmux 3.4, 3.5 and 3.5a pass output through
vis escaping. An invalid byte can otherwise become indistinguishable from a
literal backslash followed by its octal spelling. Qualify the selected
server locale and bundled/libbsd vis implementation explicitly.

Protect literal backslashes before tmux prints a byte-bearing field, using
its substitution modifier. Decode the resulting doubled backslashes and
supported vis escapes after frame validation. tmux 3.4 also escapes certain
dollar sequences. Raw-output releases still need doubled-backslash decoding.
Reject malformed escapes and NUL values; never guess that an undecodable
response is plain text. Keep the raw-frame decoder available only for
formats proved line/escape-safe, such as numeric topology and release IDs.

Bound encoded stdout, stderr and decoded payload separately. Escaping can
increase wire length, so the process-output limit may reject a value smaller
than the decoded ceiling. Do not silently raise child reservations or claim
all maximum decoded values fit an existing envelope. Avoid retaining oversized
backing slices. Declared Text conversion is a later field-specific decision;
window names and current commands can require lossless values.

A nonce collision fails explicitly and never triggers mutation replay. The
nonce comes from the library after earlier input, not from caller data. It is
a correlation marker under the trusted local-daemon/configuration contract,
not authentication.

Do not compute length by expanding a field twice. Built-in callbacks can
observe changing OS state between evaluations. A custom-entry cache does not
make every built-in field stable. A length from one evaluation need not
describe another evaluation's bytes.

## Hooks, context and complete captures

Leave configured hooks intact. They can mutate, wait, fail or emit output
during an observational command. Extra output fails strict framing; a hook
failure remains a command failure even if a frame was printed first. A
no-output hook can change state between commands in the same invocation.

Include and validate actual context IDs where target fallback is possible.
Every field needs a mapping and capability check; an unsupported format
becoming empty is not supported absence. Preserving reported bytes does not
recover upstream sanitization, such as rejected command names on tmux 3.7+.

The complete capture needs a bounded, tagged, nonce-qualified record protocol
with an exact field sequence, empty results, client coverage and duplicate-link
validation. Expand each byte-bearing field once in its tagged unit. Qualify
that protocol before replacing per-field capture; scalar decoder success alone
is insufficient. Separate coherent tmux-owned graph observations from
OS-derived values and the tmux 3.3 client-listing fallback. Do not promise a
globally atomic Snapshot.

Arbitrary option listings, binary buffer output and raw commands retain their
separate contracts. This protocol does not establish completion of a mutation
or a configured daemon-side job.

## Evidence and supersession

Earlier endpoint probes covered tmux 3.3 and 3.8 and established hook-output
rejection and scalar boundaries. Their raw-byte result does not generalize
to intermediate releases. The [review reconciliation](../decisions/0001-native-domain-model-qualification.md)
records the thirteen-release byte probe, the additional tmux 3.4 dollar case,
scalar tearing and remaining build/locale qualifications.

Retain those failed assumptions as evidence. Require native decoder properties,
real-tmux byte/path cases, limits, context receipts, hook errors and cancellation
before promoting the transport. Batching does not remove deadlines, server-pause
measurements or unresolved operation ownership.

Sources: [3.3 scalar command](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd-display-message.c),
[3.4 print conversion](https://github.com/tmux/tmux/blob/3.4/server-client.c),
[3.4 vis wrapper](https://github.com/tmux/tmux/blob/3.4/utf8.c),
[3.8 command-name cleaning](https://github.com/tmux/tmux/blob/3.8/names.c),
and [Linux field callbacks](https://github.com/tmux/tmux/blob/3.8/osdep-linux.c).
