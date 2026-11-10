# Changelog

## Unreleased

### Added

- Rename sessions and physical windows and set pane titles through
  `LibTmux.Server`, using generation-bound references, literal names and
  per-command deadlines. ([#10])
- Recover interrupted mutations through their original operation and cleanup
  owner. Distinguish rejected commands from applied changes followed by hook
  errors, without replaying an uncertain command. ([#10])
- Capture an existing tmux daemon with `LibTmux.Server`. Detached snapshots
  expose sessions, physical windows and panes, attached clients, window links
  and pane occurrences through ordinary Haskell collections. ([#4])
- Navigate snapshots after the Server scope closes. Typed references and
  indexed lookups distinguish connection identity, missing targets and linked
  window context. ([#4])
- Share a `Runtime` across independent Server scopes. Bounded cleanup preserves
  callback failures and cancellation, with correlated recovery when capture,
  adoption or cleanup cannot establish completion. ([#4])
- Build validated offline snapshots with `LibTmux.Snapshot.Fixture` for pure
  application tests, without starting tmux or creating live references. ([#4])
- Select observations with typed fields and relationships through
  `LibTmux.Query`. Validate requirements, evaluate an existing snapshot or
  fetch fresh observations, and apply stable ordering and limits. ([#6])
- Require unique selections with `exactlyOne` and `atMostOne`, preserving
  the distinction between physical entities and contextual appearances. ([#6])

### Documentation

- Follow Haskell language and standard-library references from the mutation
  guide, including operand text and exception-context recovery. ([#11])
- Follow a native Cabal example from typed target selection to mutation and
  fresh capture. Read the deadline, partial-change and recovery contracts
  alongside the linked API declarations. ([#10])
- Run the capture, query and shared Runtime examples through Cabal, with
  private-server setup, expected output, teardown and per-package guides.
  Installation guidance distinguishes package requirements from CI toolchain
  pins. ([#9])
- Read linked module and ownership documentation with explicit failure and
  recovery contracts. Native source listings support keyboard scrolling,
  with type annotations kept inside the viewport. ([#9])
- Browse native Haddock with distinct links for record owners, instance
  methods and source identifiers. Wide API sections scroll within narrow
  screens; CI retains the original output alongside the checked browser. ([#5])
- Follow the query guide and runnable example for linked-window selection,
  ordinary-predicate equivalence and application error handling. Long native
  module headings wrap on narrow screens. ([#6])

### Changed

- Admit tmux 3.3a through 3.8, including all intermediate stable releases,
  with `LibTmux.Version.requireSupported`. ([#2])

### Development

- Distinguish rejected mutations from changes followed by hook errors in the
  private command backend. Cancellation preserves cleanup ownership and
  correlated recovery without replaying commands. Public mutation methods
  remain under development. ([#8])
- Prepare session, window and pane mutations to preserve literal text,
  including tmux format syntax, style markers and command separators.
  Command execution remains private. ([#7])
- Measure complete public captures with an optional benchmark, recorded
  samples and owned graph fixtures, separate from routine CI. ([#4])
- Add a native capture backend for server metadata, sessions, windows, panes
  and attached clients. Detached observations preserve linked-window context;
  the capture API remains private. ([#2])
- Preserve non-text window labels, process names and paths. Validate complete
  captures and retain read ownership through cancellation and recovery. ([#2])
- Check tmux 3.3a and 3.8 in CI with the current Haskell toolchain, isolated
  servers and source-archive consumers. ([#2])

[#2]: https://github.com/libtmux/libtmux-haskell/pull/2
[#10]: https://github.com/libtmux/libtmux-haskell/pull/10
[#11]: https://github.com/libtmux/libtmux-haskell/pull/11
[#4]: https://github.com/libtmux/libtmux-haskell/pull/4
[#5]: https://github.com/libtmux/libtmux-haskell/pull/5
[#6]: https://github.com/libtmux/libtmux-haskell/pull/6
[#7]: https://github.com/libtmux/libtmux-haskell/pull/7
[#8]: https://github.com/libtmux/libtmux-haskell/pull/8
[#9]: https://github.com/libtmux/libtmux-haskell/pull/9
