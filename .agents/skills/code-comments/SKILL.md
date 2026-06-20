---
name: code-comments
description: >-
  Writes and reviews code comments. Activates when the user asks to add,
  improve, standardize, or evaluate comments in source code.
---

# Code Comments

Write comments that improve maintainability, reduce reader confusion,
and document intent that is not obvious from the code itself.

Comments are part of the codebase and must meet the same quality bar
as executable code.

## Principles

- **Prefer clear code first**: Rename, extract, or simplify code before
  adding a comment to explain avoidable complexity.
- **Comment the non-obvious**: Use comments to capture intent,
  constraints, invariants, edge cases, tradeoffs, and reasoning that a
  reader cannot reliably infer from the code alone.
- **Do not narrate the code**: Avoid line-by-line descriptions of what
  the code literally does.
- **Keep comments accurate**: A wrong or stale comment is worse than no
  comment.
- **Optimize for future maintainers**: Write for the next engineer who
  will debug, extend, or review the code under time pressure.

## When To Add Comments

Add comments when one or more of the following is true:

- The code enforces a business rule, protocol rule, or compatibility
  requirement that is not obvious from local context.
- The code depends on a subtle invariant, ordering requirement, or data
  ownership rule.
- The implementation looks unusual, but the unusual shape is
  intentional.
- A workaround exists for a compiler, platform, dependency, API, or
  external system limitation.
- A performance optimization or caching strategy would otherwise look
  premature or confusing.
- Error handling, retry behavior, or fallback logic encodes an
  important operational decision.
- A public API, exported type, or module needs contract-level
  documentation for callers.

## When Not To Add Comments

Do not add comments when the code can be made self-explanatory or when
the comment only repeats the code.

Avoid comments like:

- `// Increment i`
- `// Check if user is null`
- `// Return the result`
- `// Loop through all items`

These add noise without preserving knowledge.

## What Good Comments Explain

Good comments usually answer one of these questions:

- **Why does this exist?**
- **Why is it implemented this way instead of the obvious way?**
- **What must remain true before or after this code runs?**
- **What breaks if this changes?**
- **What external behavior, contract, or constraint is being honored?**

Prefer intent and constraints over mechanics.

## Style Rules

### Tone

- Use direct, neutral, technical language.
- Keep comments concise and specific.
- Write complete thoughts, but avoid essay-style blocks when a short
  note is enough.
- Avoid jokes, conversational filler, and subjective commentary such as
  `hacky`, `weird`, or `magic`.

### Structure

- Place comments as close as possible to the code they describe.
- Use a short leading comment for a non-obvious block rather than many
  inline comments on each line.
- For exported APIs, prefer doc comments that describe behavior,
  inputs, outputs, guarantees, and important caveats.
- For complex modules, use a short file or section comment only when it
  helps readers orient quickly.

### Content

- State facts that are stable and verifiable from the design.
- Reference external specs, issues, or bug IDs when they materially
  help future readers.
- If a comment describes a workaround, say what condition would allow
  its removal.
- If a numeric constant, timeout, limit, or ordering dependency is
  important, explain why that value or order exists.

## Preferred Comment Patterns

### Intent comment

Use when the purpose is not obvious.

```text
// Keep tombstoned entries until replication catches up so peers can
// observe the delete marker.
```

### Invariant comment

Use when correctness depends on a rule that must stay true.

```text
// `head` always points to the first unread node. Writers may append,
// but only the consumer advances `head`.
```

### Workaround comment

Use when the code shape is driven by an external limitation.

```text
// This extra copy avoids aliasing bugs in Zig 0.x slice coercion.
// Remove once the upstream issue is fixed.
```

### API contract comment

Use for public or cross-module behavior.

```text
/// Returns a borrowed view into the cache.
/// The caller must not retain it after `deinit`.
```

## Anti-Patterns

Avoid these comment patterns:

- Restating the code in English.
- Commenting every line in a straightforward function.
- Leaving commented-out code in place instead of deleting it.
- Using comments to excuse poor naming or deeply nested logic that
  should be refactored.
- Writing TODOs without enough context to be actionable.
- Explaining implementation details while omitting the reason the code
  must work that way.

## TODO and FIXME Guidance

- Use `TODO` for planned, non-urgent follow-up work.
- Use `FIXME` for known incorrect, fragile, or incomplete behavior that
  should be addressed.
- Include enough context to make the note actionable.
- Prefer referencing an issue number when one exists.

Examples:

```text
// TODO(#214): batch these writes once the storage layer supports
// transactional append.

// FIXME: This treats clock rollback as expiration. Replace with a
// monotonic source.
```

## Review Standard

When adding or reviewing comments, apply this checklist:

- Is the code clear enough that the comment is unnecessary?
- Does the comment explain intent, constraint, or contract rather than
  mechanics?
- Is the comment placed at the narrowest useful scope?
- Could a future refactor make this comment false easily?
- Would a maintainer learn something important by reading it?

If the answer to the last question is no, delete or rewrite the
comment.

## Workflow

- Read the surrounding code before writing comments.
- Prefer refactoring confusing code before adding explanatory comments.
- Add comments only where they preserve important knowledge that would
  otherwise be lost.
- Keep comments short, local, and tied to real constraints.
- When editing code, update or remove nearby comments that no longer
  match behavior.
- If a comment cannot be kept accurate with confidence, omit it until
  the behavior is better understood.
