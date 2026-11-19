# Changelog

## Unreleased

### Added

- Set, read or remove scalar options at an explicit scope. `LocalOption`
  and `EffectiveOption` distinguish an override from inherited values. ([#29])
- Set individual numeric entries for built-in hooks, read their native
  listing and remove a local hook override. ([#30])

- Report `IncompatibleTmuxClientProtocol` when an older daemon rejects the
  selected client's wire protocol, without inventing a daemon release. ([#15])
- Resize physical panes and windows with `resizePane`, `resizeWindow` and
  their `With` variants. `ResizeWidth`, `ResizeHeight` and `ResizeBoth` use
  checked dimensions and refuse axes above 10000 cells before native effects.
  Capture again for actual geometry after layout constraints. ([#27])

- Create windows through `createWindow` and `createWindowWith`, with explicit
  session/index placement, selection and occupied-link replacement policy.
  Return the actual window, pane and link identities. ([#33])
- Split an explicit pane through `splitPane` and `splitPaneWith`, retaining
  its exact `WindowSlot` context, checked orientation/size and historical
  creation receipts after cancellation or failed hooks. ([#26])
- Run terminal applications through `withProgram` and `runProgram`, with
  literal argv, input, rendered output and typed leader outcomes. Program
  operations require tmux 3.8, Linux 6.9 process-group pidfds and the checked
  Bash features. ([#41])
- Retain incomplete application cleanup through `ProgramRecovery`, preserving
  callback failures and asynchronous exception classes. Cancelled observations
  leave their owning scope running. ([#41])
- Discover application operation support through `serverCapabilities` and
  `LibTmux.Capabilities`, bound to the pinned daemon release. Unsupported
  operations refuse before application creation. ([#15])
- Create detached sessions through `createSession` and `createSessionWith`.
  `LibTmux.Creation` supplies session options and historical created session,
  window and pane references. ([#19])
- Retain observed creation identities through cancellation, deadlines and
  failing hooks. `CreationRecovery` exposes the original operation and
  generation, receipt inspection and explicit cleanup recovery without
  replaying creation. ([#19])
- Remove a generation-bound session, window or pane with `killSession`,
  `killWindow` or `killPane`. A physical window is removed from every session
  that links it. The `With` variants accept an explicit deadline. ([#28])

- Send literal text or a validated sequence of named keys to a `PaneRef`
  with `sendKeys`. Use `sendKeysWith` for an explicit deadline. ([#24])
- Read visible or historical rows with `capturePane`. Plain and ANSI
  captures preserve empty rows, reject text over the byte limit and report a
  failed after-hook separately from rejection of the capture. ([#25])
- Wait for present or newly observed pane text with `waitForText`. Timeout
  and pane exit are distinct and retain the last complete capture when
  available. ([#47])
- Link, unlink and select exact session/index slots. Select a pane through
  its slot and apply a shared named layout to the physical window. ([#12])
- Read and change named entries in the global or session environment.
  Preserve literal bytes, visibility and the difference between empty,
  removed and absent values. ([#12])
- Load and read named binary buffers with a 64 KiB limit. Paste into an
  exact pane with an explicit line-feed policy. ([#12])
- Look up built-in option types and hook scopes using the connected
  daemon's release with `LibTmux.Options`. ([#31], [#32])

### Documentation

- Find the calls that act on a session, window or pane from its reference
  page. `Session`, `Window` and `Pane` each open with a "What is on here"
  directory that groups the calls that list, read, create, change, select and
  remove it by job, with guidance for each job. ([#52])

### Changed

- Publish only defined shared claims in `capabilities.json`, using
  `libtmux-capabilities/1`. Use `capabilityRegistry` for Haskell Program and
  raw-paste requirements, which are outside the shared vocabulary. ([#15])
- Share opaque creation identities through `CreatedEntities`; `CreatedSession`,
  `CreatedWindow` and `CreatedPane` name each command's result. Window and pane
  receipts include existing parents; cleanup must target the entity created
  by the original command. Derived `Show` output now names `CreatedEntities`.
  ([#33], [#26])
- Admit tmux 3.3a and every newer release in `LibTmux.Version.requireSupported`,
  `withServer`, `withServerIn` and the server version recorded in snapshots,
  with no upper bound. Releases after 3.8 and patch letters such as 3.8a now
  pass. Observed releases of 3.3 and older still raise `UnsupportedVersion`
  or `UnsupportedTmuxVersion`. ([#15])
- Parse and order `next-X.Y`, `X.Y-rc` and `X.Y-rcN` in
  `LibTmux.Version.parseVersion`, ranked
  `next-X.Y < X.Y-rc < X.Y-rcN < X.Y < X.Ya`. Numeric components compare as
  numbers and `renderVersion` returns the accepted spelling. Bare `master`
  and unknown suffixes remain `MalformedVersion`. Callers that relied on
  `MalformedVersion` or `UnsupportedVersion` for these spellings or for
  releases above 3.8 now receive a version. ([#15])
- Change the derived `Show` output of `TmuxVersion` with its private
  representation, for example from `TmuxVersion 3 8 (Just 'a')` to
  `TmuxVersion 3 8 (Patch 'a')`. The same text appears inside
  `UnsupportedVersion`. Use `renderVersion` for user-facing release text.
  ([#15])

### Fixed

- Refuse legacy daemons promptly when they retain a version client's stdout.
  A hook-free failed option lookup reads releases before `run-shell -C`
  became available. ([#15])
- Refuse insertion after window index 2147483647 before dispatch, avoiding an
  unexpected tmux 3.3a daemon exit at its signed-index boundary. ([#33])
- Mask watch retirement during `ProgramRecovery` cleanup so asynchronous
  exceptions cannot leave a closed descriptor recorded for retry. ([#41])
- Report a refused native creation context as `InvalidConfiguration` before
  admission. Oversized options raise `InvalidMutationArgument`. ([#19])
- Refuse encoded mutation commands over tmux's native message limit before
  admission. Oversized names no longer leave an uncertain operation waiting
  for explicit recovery.

## 0.0.1.0

### Added

- Rename sessions and physical windows and set pane titles through
  `LibTmux.Server`, using generation-bound references, literal names and
  per-command deadlines. ([#10])
- Set a mutation's deadline with `MutationOptions`: start from
  `defaultMutationOptions` and pass it to the `...With` variants. ([#10])
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
- Tell a captured snapshot from an offline fixture with `snapshotOrigin`. ([#4])
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
[#19]: https://github.com/libtmux/libtmux-haskell/pull/19
[#10]: https://github.com/libtmux/libtmux-haskell/pull/10
[#11]: https://github.com/libtmux/libtmux-haskell/pull/11
[#4]: https://github.com/libtmux/libtmux-haskell/pull/4
[#5]: https://github.com/libtmux/libtmux-haskell/pull/5
[#6]: https://github.com/libtmux/libtmux-haskell/pull/6
[#7]: https://github.com/libtmux/libtmux-haskell/pull/7
[#8]: https://github.com/libtmux/libtmux-haskell/pull/8
[#9]: https://github.com/libtmux/libtmux-haskell/pull/9
[#15]: https://github.com/libtmux/libtmux-haskell/issues/15

[#41]: https://github.com/libtmux/libtmux-haskell/issues/41
[#33]: https://github.com/libtmux/libtmux-haskell/issues/33
[#26]: https://github.com/libtmux/libtmux-haskell/issues/26
[#28]: https://github.com/libtmux/libtmux-haskell/issues/28
[#24]: https://github.com/libtmux/libtmux-haskell/issues/24
[#25]: https://github.com/libtmux/libtmux-haskell/issues/25
[#47]: https://github.com/libtmux/libtmux-haskell/issues/47
[#12]: https://github.com/libtmux/libtmux-haskell/issues/12
[#52]: https://github.com/libtmux/libtmux-haskell/issues/52
[#27]: https://github.com/libtmux/libtmux-haskell/issues/27
[#31]: https://github.com/libtmux/libtmux-haskell/issues/31
[#32]: https://github.com/libtmux/libtmux-haskell/issues/32
[#29]: https://github.com/libtmux/libtmux-haskell/issues/29
[#30]: https://github.com/libtmux/libtmux-haskell/issues/30
