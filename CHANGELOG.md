# Changelog

## Unreleased

### Added

- Start an empty private daemon with `withOwnedServer`. Scope exit waits for
  its descendants and retires its directory. Use `killServer` for explicit
  retirement of the admitted daemon, including through a borrowed handle with
  a verified process descriptor. Both paths require Linux peer pidfds.
  ([#34], [#28])
- Create sessions with `createSession`, windows with `createWindow`, and panes
  with `splitPane`. Keep the returned references for later commands. Creation
  recovery preserves identities reported before a deadline, cancellation or
  failed hook. ([#19], [#33], [#26])
- Remove an exact pane, window or session with `killPane`, `killWindow` or
  `killSession`. Removing a physical window removes all its links. ([#28])
- Link, unlink and select exact session/index slots. Select a pane through
  its slot and apply a named layout to the physical window. ([#12])
- Use `sendKeys` for literal text or validated named keys on an explicit
  `PaneRef`. Read visible or historical rows with `capturePane`, including
  blank rows and optional ANSI styling. ([#24], [#25])
- Use `waitForText` for text already present or newly observed since a
  baseline. Timeout and pane exit retain the last complete capture when
  available. ([#47])
- Use `waitForPaneState` to wait for pane removal, retained death or focus through
  a selected session/window slot. A match includes the snapshot that confirms
  it. Timeout, control overflow and daemon loss have distinct outcomes.
- Observe native changes through `withControl` and a bounded STM queue. The
  stream reports overflow, daemon exit and malformed framing, and keeps a
  cleanup owner if retirement cannot finish. ([#48])
- Run an application with literal argv using `withProgram` or `runProgram`.
  Observe its rendered output and leader exit, send input, and recover
  incomplete cleanup. Program operations require tmux 3.8, Linux 6.9
  process-group pidfds and the Bash features described in the guide. ([#41])
- Check the connected release with `serverCapabilities`. `capabilityRegistry`
  lists the Haskell gates for Program, control and raw paste. Older daemons
  that refuse the client's protocol raise `IncompatibleTmuxClientProtocol`.
  ([#15], [#48])
- Read and change individual global and session environment entries, preserving
  empty values, removal markers and absence. Load, read and paste
  named buffers as bytes up to 64 KiB. ([#12])
- Look up built-in options and hooks by daemon release. Read or change a
  scalar option at an explicit store, or set numeric entries of a built-in
  hook and inspect its native listing. ([#29], [#30], [#31], [#32])
- Resize panes and windows to an absolute width, height or both. The library
  refuses axes above 10000 cells before dispatch. Capture the resulting
  geometry to observe tmux's layout constraints. ([#27])
- Capture session groups, unzoomed layouts, zoom state, contextual link
  flags, base-screen cursors, pane modes and client tty sizes. ([#12])

### Changed

- Import `LibTmux.Query.Fields` for row-prefixed tokens such as `paneActive`
  and `sessionWindowLinks`. It replaces the eight row-specific field modules
  and preserves field types, relationships and requirement names. ([#12])
- Import `LibTmux.Recovery` to inspect and resume retained operations. Catch
  contextual library failures with `tryTmux`. Match configuration, target,
  operand and observation failures by constructor. `OperationFailed`
  retains the underlying synchronous exception. ([#12])
- Provide the metadata fields when building `Session`, `Window`, `WindowLink`,
  `Pane`, `Client` or `Fixture.AttachedClient` values offline. Client tty
  height is optional. ([#12])
- Expect `CreatedEntities` in derived `Show` output for `CreatedSession`,
  `CreatedWindow` and `CreatedPane`. Their references identify the actual
  new entities and their parents. ([#19], [#33], [#26])
- Admit tmux 3.3a and later releases, including patch letters. `parseVersion`
  also recognizes `next-X.Y`, `X.Y-rc` and numbered release candidates.
  Use `renderVersion` for user-facing text. ([#15])
- Find session, window and pane operations by task in their API reference
  directories. ([#52])

### Fixed

- Preserve the capture deadline result and original read receipt when the
  runtime deadline arrives before the capture timer. ([#12])
- Decode an overlapping command's complete reply when tmux 3.3a appends a
  client-detached notification after its exit record. ([#48])
- Refuse insertion after index 2147483647 before dispatch, where tmux 3.3a
  can terminate the daemon. ([#33])
- Refuse invalid creation contexts and oversized command operands before
  dispatch. ([#19])

## 0.0.1.0

- Capture detached tmux observations and navigate them after closing the
  Server scope. Typed references preserve generation and link context. ([#4])
- Share a `Runtime` across independent Server scopes and retain incomplete
  cleanup after failure or cancellation. Build validated offline snapshots
  with `LibTmux.Snapshot.Fixture`. ([#4])
- Filter and order observations with typed queries. Use `exactlyOne` and
  `atMostOne` when the operation needs a unique target. ([#6])
- Rename sessions and windows and set pane titles through `LibTmux.Server`,
  with generation checks, deadlines and correlated recovery. ([#10])
- Follow Cabal examples for capture, queries and a shared Runtime. ([#9])

[#4]: https://github.com/libtmux/libtmux-haskell/pull/4
[#6]: https://github.com/libtmux/libtmux-haskell/pull/6
[#9]: https://github.com/libtmux/libtmux-haskell/pull/9
[#10]: https://github.com/libtmux/libtmux-haskell/pull/10
[#12]: https://github.com/libtmux/libtmux-haskell/issues/12
[#15]: https://github.com/libtmux/libtmux-haskell/issues/15
[#19]: https://github.com/libtmux/libtmux-haskell/pull/19
[#24]: https://github.com/libtmux/libtmux-haskell/issues/24
[#25]: https://github.com/libtmux/libtmux-haskell/issues/25
[#26]: https://github.com/libtmux/libtmux-haskell/issues/26
[#27]: https://github.com/libtmux/libtmux-haskell/issues/27
[#28]: https://github.com/libtmux/libtmux-haskell/issues/28
[#29]: https://github.com/libtmux/libtmux-haskell/issues/29
[#30]: https://github.com/libtmux/libtmux-haskell/issues/30
[#31]: https://github.com/libtmux/libtmux-haskell/issues/31
[#32]: https://github.com/libtmux/libtmux-haskell/issues/32
[#33]: https://github.com/libtmux/libtmux-haskell/issues/33
[#34]: https://github.com/libtmux/libtmux-haskell/issues/34
[#41]: https://github.com/libtmux/libtmux-haskell/issues/41
[#47]: https://github.com/libtmux/libtmux-haskell/issues/47
[#48]: https://github.com/libtmux/libtmux-haskell/issues/48
[#52]: https://github.com/libtmux/libtmux-haskell/issues/52
