# ADR 0001 qualification

This record separates the accepted architecture from implementation evidence.
The [decision](0001-native-domain-model.md) governs new work. Public graph,
Server and query APIs remain unqualified.

## Review reconciliation, 2026-11-08

Four external reviews agreed on Server, detached observations, physical links,
generation-scoped identity and ordinary IO. The author then checked the
contested transport and Haskell claims against pinned source and owned probes.
The complete research report has SHA-256
`5a8b0ed0df7c952129669dbb98b0b1cf553158d13a4e966e9a2b13f9e8d61d43`.
The reviews and raw experiment records remain in the accompanying research
archive. These measurements qualify bounded experiments, not the public API.

- Across the required thirteen tmux releases, 74 fixed/seeded non-NUL samples
  per release passed the revised escape decoder: 962 round trips. Three real
  path fixtures per release distinguished invalid bytes from literal escapes.
  tmux 3.4, 3.5 and 3.5a otherwise conflate byte FF with literal backslash-377.
  The original review decoder failed ten 3.4 samples because it omitted dollar
  escapes. Other locales and libbsd-linked builds remain unqualified.
- Paired window renames produced 232 disagreements in 240 separate-read
  observations across 3.3, 3.4 and 3.8. One window-loop expansion produced
  none. This tests tmux-owned names, not atomicity of OS-derived fields.
- All thirteen releases allowed an after-display hook to change a name between
  two commands of one invocation. Appended commands need a consistency
  contract even when they use one child process.
- Invalid argv bytes remained in the owned process. tmux 3.7 through 3.8
  reported an empty current command. Earlier supported releases returned raw
  or escaped bytes according to their output path.
- A separate GHC 9.14.1 consumer changed a checked value to zero through an
  exported record label despite its hidden constructor. This rejects that
  proposed convenience; it is not a defect in the current `Dimension` API.
- A small exception-context probe preserved asynchronous exception
  classification. Integrated cancellation, allocation failure and recovery
  ownership are separate remaining gates.

The byte and tearing probes took 8.177 seconds including setup and cleanup;
the small GHC consumer took 0.962 seconds. They used cached executables,
explicit UTF-8 clients and the C locale. Owned daemon/pane exit was observed.
Cached binary hashes were recorded; no upstream rebuild provenance is claimed.

Sources: [tmux 3.4 output conversion][print], [3.4 dollar escapes][dollar],
[3.8 command-name cleaning][names], [Linux format inputs][osdep],
[3.3 command hooks][hooks], [GHC field exports][fields],
[base exceptions][exceptions] and [glibc 2.39][glibc].

## Superseded recommendations

Per-field capture remains a comparison implementation with scalar tearing
and incomplete observation coverage. It cannot serve as an unconditional
correctness oracle. The private scalar transport now preserves the observed
bytes under the qualified profiles below; field-specific public values remain
unimplemented.
Qualify batching before choosing parallel hydration. One child does not remove
payload, deadline or ownership limits, and one expansion does not promise a
globally atomic snapshot. Preserve unknown logical work until a separate
completion or explicit-detachment rule applies.

Use lossless field representations where tmux permits non-text data. Keep one
graph hierarchy and explicit conversion. Preserve checked dimensions without
Num or writable value fields. GHC compatibility expansion remains excluded.
Existing indexed lookups and NFData forcing already address those review
requests; the remaining issue is public consumer qualification.

## Native scalar qualification, 2026-11-08

The private [frame decoder](../../internal/LibTmux/Internal/Frame.hs) now
protects literal backslashes and validates octal, C-style and dollar escapes.
[Runtime](../../internal/LibTmux/Internal/Runtime.hs) uses it for entity
fields and checks the decoded target receipt. Numeric topology and version
reads retain their raw-frame decoder. Encoded stdout and decoded payload have
separate limits; the process reservations are unchanged.

The [live scalar tests](../../test/integration/FrameIntegrationTest.hs) passed
on every required release under C and C.UTF-8 locales with explicit UTF-8
clients. Each cell round-trips 73 fixed/seeded non-NUL values and three actual
byte-path fixtures. These are bounded samples, not an exhaustive byte-string
proof. Pure properties cover generated octal payloads; targeted cases reject
malformed escapes, encoded NUL and decoded nonce collisions. The live hook
test still rejects extra output. The test fixture observes additional pane
exit even when its callback throws cancellation at entry.

The locale matrix took 13.95 seconds including startup and cleanup. The full
integration matrix at one and two runtime capabilities, type contracts,
package checks, Haddock and source-archive consumer completed in 133.39
seconds. These are verification timings under the shared resource limiter,
not capture benchmarks. Cached executable hashes and command logs accompany
the research evidence. Other locales and libbsd-linked builds remain
unqualified. This result does not qualify complete record framing, a public
capture consumer or cancellation during an accepted capture read.

## Private lossless field model

Window names now use an owned byte value with explicit, fallible text
conversion. Current commands use PosixString and current paths use PosixPath.
Session names and pane titles keep their declared text contract. None of
these private field types changes the current exposed scalar modules.

The live regression starts a foreground shell with invalid argv bytes and
waits for that shell's event receipt after exec. The original capture failed
with InvalidFieldEncoding PaneCommand. The updated test checks exact reported
command/path values after resource closure and raw window names on releases
that accept them. It also checks the later command-name normalization instead
of inventing the bytes tmux discarded.

The full integration suite passes on all thirteen required releases with one
and two runtime capabilities under C.UTF-8. The focused lossless-field case
also passes on each release under C. Specifications, units, type contracts,
package checks, docs, Haddock and the existing archive consumer pass. The
complete driver took 137.54 seconds including setup and cleanup under the
shared resource limiter. Independent source review passes this private
increment; neither these checks nor the timing qualify complete public capture,
creation-to-receipt cancellation, accepted-read cancellation or benchmarks.

## Remaining gates

- Qualify complete record framing on every required release, preserving the
  scalar byte, limit, target and hook checks above. Cover exact field order,
  duplicate links, empty results and client acquisition. Record the supported
  locale/build profile rather than extrapolating from one build.
- Acquire ServerInfo and attached clients and separate private topology rows
  from hydrated records. Define repeated-link consistency, upstream field
  normalization, empty-server behavior and complete-profile coverage.
- Qualify the common Server scope under callback/cleanup double failure,
  accepted-read cancellation and recovery-worker allocation failure. Capture
  failures must identify their recovery operation. Repeated malformed results
  must be recoverable before a later successful capture on the same Runtime.
- Define concurrent capture admission. The prototype reserves 64 MiB per
  capture against 125,566,976 ordinary bytes after inspection reserve, so it
  admits at most one full capture envelope. That reservation is not RSS.
  Its numeric comparison also includes selection and geometry; document which
  changes invalidate each acquisition strategy.
- Provide validated offline fixtures whose references cannot target tmux.
  Qualify reference equality across captures, missing/foreign lookup,
  reconstruction instances, roles and installed record import/update behavior.
- Execute installed programs for capture/navigation after closure, query and
  cardinality before mutation, and accepted-read cancellation/recovery. Combine
  operational, query and cardinality errors in a complete application example.
- Measure small, medium, large and repeatedly linked native captures, including
  active selection/resize, invalid bytes, full forcing, concurrent admission,
  cancellation and maximum server pause. Research shell timings do not qualify
  native defaults.

## Delivery and review

Use the existing draft PR for logical commits and current-source verification.
Keep Hspec/QuickCheck specifications separate from the Tasty suite assembly.
Run the exact release matrix and source-archive consumer checks before public
export. Preserve failed and unrun gates in the review record. Shared docs,
workspace, events, commands and query implementation remain part of the full
suite; the current native increment does not claim their completion.

MCP is excluded from implementation and scoring. Every other requested quality
dimension still needs evidence and the adoption review before merge/release.
No numeric score or architectural approval waives a failing mandatory gate.

[print]: https://github.com/tmux/tmux/blob/3.4/server-client.c#L3274-L3284
[dollar]: https://github.com/tmux/tmux/blob/3.4/utf8.c
[names]: https://github.com/tmux/tmux/blob/3.8/names.c
[osdep]: https://github.com/tmux/tmux/blob/3.8/osdep-linux.c
[hooks]: https://github.com/tmux/tmux/blob/3.3/cmd-queue.c
[fields]: https://downloads.haskell.org/ghc/9.14.1/docs/users_guide/exts/field_selectors.html
[exceptions]: https://hackage-content.haskell.org/package/base-4.22.0.0/docs/Control-Exception.html
[glibc]: https://sourceware.org/pipermail/libc-announce/2024/000038.html
