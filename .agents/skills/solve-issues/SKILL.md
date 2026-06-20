---
name: solve-issues
description: >-
  Solves GitHub issues end to end with a structured engineering
  workflow. Use when Codex needs to take a repository issue from issue
  analysis through planning, TDD implementation, code review, ready
  pull request submission, Sourcery feedback triage, and final merge.
---

# Solve Issues

Resolve GitHub issues with an explicit plan-review-implement-review
loop instead of jumping straight into code.

## Workflow

Follow these steps in order unless the user explicitly narrows the
scope.

### 1. Read The Issue And Build A TDD Plan

- Read the full issue before changing code.
- Identify the expected behavior, current behavior, affected modules,
  and likely failure boundary.
- Read the relevant production code and existing tests before drafting
  the plan.
- Prefer adding or updating tests first so the plan is grounded in an
  observable failing case.
- Write a concrete implementation plan that includes:
  - the root cause or working hypothesis
  - the tests to add or update
  - the production code changes to make
  - the validation steps to run
  - known risks, invariants, and compatibility constraints

### 2. First Plan Review: Completeness And Local Risks

Review the initial plan before implementation.

- Check whether the plan skipped edge cases, error paths, migration
  concerns, or cleanup work.
- Check whether test coverage is strong enough to prove the behavior
  change.
- Add notes for repository-specific concerns such as branch state,
  generated files, feature flags, or API compatibility.
- Update the plan before proceeding.

### 3. Second Plan Review: Engineering Best Practices

Review the revised plan against language and library best practices.

- Use `context7` MCP when it is available and the task depends on
  language, standard library, framework, or dependency behavior.
- Reject plans that would preserve poor structure when a cleaner
  abstraction is reasonable inside the issue scope.
- Prefer changes that are testable, maintainable, and easy to review.
- Update the plan if better abstractions, safer APIs, or clearer
  ownership boundaries are needed.

### 4. Third Plan Review: Feasibility

Stress-test the plan before coding.

- Check whether each step is executable in the current repository and
  environment.
- Check whether the tests can be run locally and whether fixtures or
  tooling need updates.
- Check whether the plan depends on permissions, secrets, external
  services, or unavailable tooling.
- Simplify or reorder the plan if the original sequence is not
  realistic.

### 5. Implement The Plan

- Prefer TDD: add or update tests first, confirm they fail for the
  intended reason, then change production code.
- Keep business code before tests in each file.
- Keep all tests at the end of the file after a
  `======tests======` section marker when editing repository files that
  follow that convention.
- Follow the repository's code comment guidance. Add comments only for
  non-obvious intent, invariants, or tradeoffs.
- Avoid unrelated refactors unless they are required to deliver a
  maintainable fix.
- Run the relevant tests, formatters, linters, and build steps that
  support confidence in the change.

### 6. Commit And Open A Ready-For-Review PR

- Review the final diff before committing.
- Use the `writing-commit-messages` skill to prepare and apply the
  commit.
- Use the `submiting-pull-requests` skill to open the PR.
- Open the PR as ready for review, not draft, unless the user
  explicitly asks for a draft.
- Include the linked issue in the PR body when applicable.
- Do not merge yet.

### 7. Triage Sourcery Feedback

After the PR is open, inspect Sourcery feedback if Sourcery comments
or reviews are available on the PR.

- Read the actual Sourcery suggestion before deciding.
- Classify each comment as one of:
  - correct and worth fixing now
  - correct but out of scope for this issue
  - incorrect, obsolete, or not worth the tradeoff
- Fix and push follow-up commits only for comments that materially
  improve correctness, maintainability, clarity, or repository
  standards.
- Do not apply Sourcery suggestions blindly.
- If a suggestion is declined, record the reason in the PR discussion
  when reviewer context would help.

## Operating Rules

- Do not skip the three plan reviews.
- Do not start implementation until the plan has been revised after
  the third review.
- Do not treat code review tools as authoritative; use engineering
  judgment.
- Do not merge with failing validation unless the user explicitly
  accepts that risk.
- Prefer repository-native tooling and existing helper skills over
  ad-hoc process.

## Tooling Notes

- Use GitHub issue and PR tooling when available to read issues, open
  PRs, inspect review comments, and merge.
- Use `context7` only in the second review when external best-practice
  confirmation materially improves the plan.
- Use `writing-commit-messages` for commit message quality and
  `submiting-pull-requests` for PR creation workflow.

## Deliverables

When using this skill end to end, produce:

- a reviewed implementation plan
- the code and tests
- a committed branch
- a ready-for-review PR
- a Sourcery triage decision with fixes if needed
- a merged PR or a concrete merge blocker
