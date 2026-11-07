# Agent instructions

Follow the existing project conventions and keep changes scoped to the
requested work.

## Change discipline

- Inspect the current branch, working tree, and relevant files before editing.
  Preserve unrelated changes and existing symlink targets.
- Make the smallest coherent change that solves the requested problem.
- Reuse existing files and APIs before adding helpers or new abstractions.
- Keep new APIs private until a caller outside the library needs them.
- Add files for distinct responsibilities or independent reuse, not one-line
  re-exports or single-use helpers.
- Use language-native conventions. Sibling ports provide behavioral
  references; their tooling and test results do not establish support here.
- Add tests for critical behavior. Demonstrate that a regression test fails
  for the intended reason before relying on its passing result.
- Verify claims against the current source and commands actually run.
- Prefer `rg`, `ag`, and `fd` for discovery; use `jq` for JSON.

## Project guides

- Setup, validation, and tmux isolation:
  [CONTRIBUTING.md](CONTRIBUTING.md).
- Prose, examples, comments, and commits:
  [WRITING.md](WRITING.md).

Each guide owns its subject. `CLAUDE.md` is a relative symlink to this file.

## Merging pull requests

Use a descriptive subject ending in the actual PR number: `Title (#PRNUM)`.
Follow it with `what:` and `why:` sections describing the change and its
reason. Never use the default `Merge pull request ... from ...` subject.

Pass the subject and body explicitly to the merge command. Read back the
resulting commit message before starting another merge.
