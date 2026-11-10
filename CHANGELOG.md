# Changelog

## Unreleased

### Added

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
[#4]: https://github.com/libtmux/libtmux-haskell/pull/4
[#5]: https://github.com/libtmux/libtmux-haskell/pull/5
[#6]: https://github.com/libtmux/libtmux-haskell/pull/6
