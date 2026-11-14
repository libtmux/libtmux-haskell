# Writing

This guide covers documentation, user-facing text, comments, and commits.
[CONTRIBUTING.md](CONTRIBUTING.md) owns the development workflow.

## Voice and evidence

Lead with the conclusion or observable behavior, then explain the evidence
and limits. Use active voice, concrete nouns, and short sentences. Assume
no shared history: explain what a referenced issue or decision concerns.

Remove filler, marketing claims, emojis, and tool signatures. Describe the
handled failure instead of calling code robust. Give measurements instead
of calling it fast. Distinguish planned, implemented, tested, and published
behavior. A README must not offer installation or API examples before they
work.

## Version claims

State a minimum version only when a used feature or package constraint requires
it. CI pins describe tested configurations, not exact installation requirements.
Keep pins in the toolchain file and link to it instead of repeating patch versions
across guides. Do not invent an upper compiler bound or imply that an untested
version passed. Preserve meaningful tmux ranges, protocol versions and versioned
source citations.

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

- A section is a task. Its `###` heading links the API and names its job:
  `### [`capture`](url): the whole graph in one read`.
- Under the heading: a line or two, the tested example, what it prints, at
  most one note. Detail goes in a guide, linked with `More:`.
- No paragraph over three lines. A list of facts is a bullet list.
- No feature inventory. A section and its example show the feature.
- State requirements as floors a reader can act on, such as "tmux 3.3a or
  newer". Toolchain pins and CI matrices stay in their own files.
- Cut what a reader would assume or never need: that examples are tested,
  how the documentation is built, what the checks cover.

## Markdown and examples

Use CommonMark with blank lines around headings and lists. Wrap repository
prose near 80 columns, except long links, identifiers, and tables. Do not
hard-wrap GitHub issue or pull request paragraphs. Avoid personal information
and local absolute paths.

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

## Haskell documentation and comments

Use Haddock beside public definitions. Start with the caller-visible result.
Explain inputs, defaults, errors, effects, ownership, ordering, cancellation,
and cleanup when relevant. Distinguish pure values from operations in `IO`.
Verify generated API links when documentation tooling is added.

Use [Haddock's native links](https://haskell-haddock.readthedocs.io/latest/markup.html#hyperlinked-identifiers),
module overviews, export groups and declaration examples. Quote identifiers
and module names in Haddock syntax rather than hard-coding generated HTML
paths. Link opaque types to their constructors/parsers and accessors; link
related modules where callers move between concepts. Use a namespace-qualified
identifier when a type and constructor share a name. Check the generated
target and anchor: module-name markup alone does not validate its destination.
Keep large APIs discoverable through task-oriented groups instead of a flat
member list. Execute every `>>>` example through
the archive consumer check. Inspect generated search, declaration anchors,
source navigation and dependency links before publishing API artifacts.

Comments explain non-obvious invariants, protocol constraints, or platform
workarounds. Prefer one or two lines. Remove narration of the next expression
and repetition of names, types, or control flow. Preserve tool directives.

## Commits and pull requests

Use `scope(type[detail]) Concise description`; the detail is optional.
Use lowercase scopes unless they name a proper product or class. Follow the
subject with a `why:` paragraph and focused `what:` bullets. Explain the
durable reason and concrete changes, with one topic per commit.

Keep temporary validation results in the review discussion. Pull request
descriptions lead with the problem and resulting behavior, explain the final
change, and report relevant checks and limits. A ticket number or commit
hash alone does not explain the change.
