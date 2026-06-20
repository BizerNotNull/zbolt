# AGENTS.md

Guidance for Codex and other AI coding agents working in this repository.

## Coding

When writing code in this repository:

- Before developing any code, first sync the local code with [https://github.com/BizerNotNull/zbolt](https://github.com/BizerNotNull/zbolt).
- Follow current Zig best practices for the active Zig version, using
  `context7` to verify language and standard library guidance when
  needed.
- Prefer test-driven development (TDD). Add or update tests together
  with the implementation and use tests to drive behavior changes.
- Favor good abstractions and maintainable design rather than limiting
  changes to the smallest possible patch when that would preserve poor
  structure.
- Write code comments according to the
  `.agents/skills/code-comments/SKILL.md` skill.
- In code that is hard to follow or where a design choice is not
  obvious, add concise comments that explain the intent, invariant, or
  reason for the chosen approach.
- Keep all tests at the end of the file after business code, and
  separate them with a `======tests======` section marker.

## Commit Messages

When asked to write or apply a commit, follow the
`.agents/skills/writting-commit-messages/SKILL.md` skill.

## Pull Requests

When asked to draft or open a pull request, follow the
`.agents/skills/submiting-pull-requests/SKILL.md` skill.
