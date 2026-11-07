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
snippets derived from checked source or add a drift check once examples
exist. Compilation alone does not establish runtime behavior.

## Haskell documentation and comments

Use Haddock beside public definitions. Start with the caller-visible result.
Explain inputs, defaults, errors, effects, ownership, ordering, cancellation,
and cleanup when relevant. Distinguish pure values from operations in `IO`.
Verify generated API links when documentation tooling is added.

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
