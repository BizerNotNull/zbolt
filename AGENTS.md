# AGENTS.md

Guidance for Codex and other AI coding agents working in this repository.

## Coding

When writing code in this repository:

- Follow current Zig best practices for the active Zig version, using
  `context7` to verify language and standard library guidance when
  needed.
- Prefer test-driven development (TDD). Add or update tests together
  with the implementation and use tests to drive behavior changes.
- Favor good abstractions and maintainable design rather than limiting
  changes to the smallest possible patch when that would preserve poor
  structure.
- Write code comments according to the
  `.agents/skills/code-comments/SKILLS.md` skill.

## Commit Messages

When asked to write or apply a commit, follow the
`.agents/skills/writting-commit-messages/SKILLS.md` skill.

## Pull Requests

When asked to draft or open a pull request, follow the
`.agents/skills/submiting-pull-requests/SKILLS.md` skill.
