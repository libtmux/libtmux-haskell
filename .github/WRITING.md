# Writing

This guide adds Haskell, Cabal, Haddock and example-catalogue rules to
[`libtmux/.github/WRITING.md`][org-writing], which governs voice, plain
CommonMark, 80-column repository wrapping, unwrapped issue and pull-request
bodies, slop removal, and commit and pull-request format.
[CONTRIBUTING.md](CONTRIBUTING.md) owns the development workflow.

Distinguish planned, implemented, tested, and published behavior. Describe the
handled failure instead of calling code robust, and give measurements instead
of calling it fast. A README must not offer installation or API examples before
they work.

## Version claims

State a minimum version only when a used feature or package constraint requires
it. CI pins describe tested configurations, not exact installation
requirements. Keep pins in the toolchain file and link to it instead of
repeating patch versions across guides. Do not invent an upper compiler bound
or imply that an untested version passed. Preserve meaningful tmux ranges,
protocol versions and versioned source citations.

Keep Cabal's package API compatibility bounds separate from these prose claims.
An exact `tested-with` entry records a tested build; it is not a compiler pin
imposed on users.

Reader examples use the language's native runner. Keep test harnesses and
documentation validators out of the application entry point.

## Reader paths

Keep the README ordered around the caller's task: purpose, installation,
the smallest complete example with error handling and output, support and
limits, then links to the manual and API. Link a function or type on its
first use in each section. Use Haskell names such as `parseWindowId` and
`LibTmux.Id`; do not append call parentheses.

Describe CI's actual triggers, versions and exercised behavior. A configured
matrix is not a completed run, and a tested fixture is not a qualified
public client. Performance claims need measurements and a reproduction
command. Changelog and release-note bullets name an observable change,
its affected API, and any migration; omit effort and internal diff narration.

## README shape

A README is scanned, not read. Each line has to survive a glance.

- A section is a task. Its `###` heading is the API, linked to its reference
  page, then a colon and its job in plain words.
- Under the heading: a line or two, the tested example, what it prints, at
  most one note. Detail goes in a guide, linked with `More:`.
- No paragraph over three lines. A list of facts is a bullet list.
- No feature inventory. A section and its example show the feature.
- State requirements as floors a reader can act on, such as "tmux 3.3a or
  newer". Toolchain pins and CI matrices stay in their own files.
- Cut what a reader would assume or never need: that examples are tested,
  how the documentation is built, what the checks cover.
- Never remove an example, command block or table to shorten the README.
  Shorten the prose. Code may add lines; prose may not.
- Examples start with their imports, so a reader can paste one into a file.
- Live examples use `withOwnedServer` to start and retire a private tmux
  server.
- Every displayed example comes from a program CI runs (see
  `examples/catalogue.json` below).
- The README shows the headline features the library has, each with an
  example: queries and filters today; a query planner, command chaining and
  control mode when they exist.

## Code blocks

Code blocks are paste-and-run units:

- Put one command in each block. An explicit `&&`, `;`, or `\` chain counts
  as one command.
- Mark shell commands as `console` and prefix them with `$ `.
- Put explanations and prerequisites outside the fence.
- Split long commands with `\`, one flag per continuation line.
- Use the native language tag for source examples and run examples as shown.

Examples that touch tmux own their socket and cleanup. Keep documentation
snippets derived from checked source. Compilation alone does not establish
runtime behavior.

Every runnable Markdown example belongs in `examples/catalogue.json`, with
one complete `Main.hs` per example directory. Register source, expected
output, package/project files, command and the CI job/step that checks exit
status and output. Mark displayed assets with the existing `example`,
`example-output`, `example-project` and `example-package` directives. The
documentation check rejects drift, orphaned programs and unregistered
Haskell fences throughout the README, manual and maintainer guides.

The shared [capability showcase](https://github.com/libtmux/docs/issues/243)
requires whole programs using public imports, explicit owned setup and
cleanup, and an asserted or printed result. Record each feature's actual
tmux floor. Offer only implemented and executed capabilities; a pure scalar
example does not demonstrate graph navigation or commands. Contract design
notes must identify proposed APIs rather than presenting runnable examples.

## Examples

<!-- shared:examples -->

An example is code written for a reader: a program under `examples/`, code in
a doc comment or docstring, and every fenced block in a README or docs page.
Shell blocks also follow [Code blocks](#code-blocks).

The text between the shared markers is the same in every libtmux port.
Change it in all of them together.

### Width

- **Examples stay within 80 columns.** They render in fixed-width boxes that
  scroll sideways, and 80 columns fits a libtmux.org code block in a
  laptop-width window. Comments inside examples wrap at 80 too.
- **The width check enforces it.** It reads the tracked files that
  `.github/example-width.toml` names and fails on a wider line. It measures
  the whole source line, so code in a doc comment counts its indent and
  comment marker. It skips output (a fence tagged `text`, and what a
  `console` block prints), hidden setup lines, and a line that is only a URL;
  an untagged fence counts as code.
- **A line that must stay wider is listed there with its reason.** An entry
  that no longer matches a line fails the check, so no stale entry stays.
- **The formatter's width is the hard limit for all other source.** Example
  directories set their formatter to 80 where the formatter takes a width.

### Reaching 80

- **Change the code, not the line breaks.** A formatter rejoins any line that
  fits its width. Name a sub-expression, use a short example name, hide setup
  the reader does not need, or print less.
- **Break at the outermost level when a break is still needed:** after an
  opening parenthesis with one argument per line, one call per line in a
  chain, one field per line in a literal.
- **Put a comment on its own line above the code it explains.** Never trail
  one after code in an example, unless the repository's example runner reads
  it there, as with an assertion marker.
- **Break a long string at a word boundary,** never inside a tmux format
  (`#{...}`) or an escape sequence; the joined text stays the same.
- **Continue a long command in a `console` block the way its shell does:**
  `\` after a `$ ` prompt, a backtick after `PS> `, one flag per continuation
  line.

### What never breaks

- **Output a test compares.** Wrapping it changes what the test expects.
- **A block copied from a source file.** Fix the width in the source and run
  the sync command; never edit the copy.
- **Marker lines and URLs,** which tools and readers take whole.

<!-- /shared:examples -->

### In this repository

- **Hard limit:** examples stay within 80 columns, enforced by the
  `check-example-width` action of `libtmux/.github` and
  `.github/example-width.toml`.
- **Not formatted:** no Haskell formatter runs in CI, so example programs,
  Cabal project snippets and Markdown fences are maintained within 80 columns
  by hand.
- **Runs, compiles, exempt:** `scripts/check_docs/check_docs.py --run` executes
  every complete program in `examples/catalogue.json`, and
  `scripts/check_sdist/check_sdist.py` builds and runs them plus Haddock `>>>`
  examples from the source archives. `examples/catalogue.json` and
  `examples/*/expected.stdout` are non-code fixtures excluded in
  `.github/example-width.toml`.
- **Compared output and copied blocks:** `expected.stdout` files and
  `example-output` blocks are compared output and stay intact. Edit
  `examples/<id>/Main.hs` first and copy the exact source into each `example`
  fence; `scripts/check_docs/check_docs.py` rejects drift and unregistered
  `haskell` fences. The untagged policy snippets below illustrate width and are
  not registered catalogue programs.

Bad, over 80:

```
  selected <- Q.runQuery snapshot (Q.panes & Q.matching (Q.allOf [Q.eq F.paneActive True, Q.dimensionAtLeast F.paneWidth 120]))
```

Good, name the reusable predicate:

```
  let activeWide =
        Q.allOf [Q.eq F.paneActive True, Q.dimensionAtLeast F.paneWidth 120]
  selected <- Q.runQuery snapshot (Q.panes & Q.matching activeWide)
```

## Haskell documentation and comments

Use Haddock beside public definitions. Start with the caller-visible result.
Explain inputs, defaults, errors, effects, ownership, ordering, cancellation,
and cleanup when relevant. Distinguish pure values from operations in `IO`.
Verify generated API links when documentation tooling is added.

Use [Haddock's native links][haddock-links], module overviews, export groups
and declaration examples. Quote identifiers and module names in Haddock syntax
rather than hard-coding generated HTML paths. Link opaque types to their
constructors/parsers and accessors; link related modules where callers move
between concepts. Use a namespace-qualified identifier when a type and
constructor share a name. Check the generated target and anchor: module-name
markup alone does not validate its destination. Keep large APIs discoverable
through task-oriented groups instead of a flat member list. Execute every
`>>>` example through the archive consumer check. Inspect generated search,
declaration anchors, source navigation and dependency links before publishing
API artifacts.

Comments explain non-obvious invariants, protocol constraints, or platform
workarounds. Prefer one or two lines. Remove narration of the next expression
and repetition of names, types, or control flow. Preserve tool directives.

## Commits and pull requests

Follow `scope(type[detail]): concise description` (50-character subject,
72-character body lines, `why:` and `what:` separated by a blank line) and the
pull-request rules in [`libtmux/.github/WRITING.md`][org-commits]. Use
lowercase scopes unless they name a proper product or class, and keep temporary
validation results in the review discussion.

[org-writing]: https://github.com/libtmux/.github/blob/main/WRITING.md
[org-commits]: https://github.com/libtmux/.github/blob/main/WRITING.md#commits-and-pull-requests
[haddock-links]: https://haskell-haddock.readthedocs.io/latest/markup.html#hyperlinked-identifiers
