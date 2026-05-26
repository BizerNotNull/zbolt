---
name: submiting-pull-requests
description: >-
  Submits GitHub pull requests. Activates when the user asks to submit
  a pull request, open a PR, draft a PR, or similar.
---

# Submitting Pull Requests

Submit pull requests that follow the project PR template and include
clear reviewer-facing context.

## Format

Use `.github/pull_request_template.md` as the source of truth for the
PR body. Fill in each section with concise, concrete details from the
actual changes.

## Rules

### Title

- Use the commit style of the project when possible.
- Keep the title short, specific, and action-oriented.
- Prefer a subsystem prefix when the change is scoped to one area,
  such as `docs:`, `build:`, or `ci:`.
- Do not end the title with a period.

### Summary

- Explain what the PR changes in 1 to 3 sentences.
- Focus on reviewer context rather than pasting the commit subject.
- Mention the user-facing or maintainer-facing outcome when relevant.

### Related issue

- Link the relevant issue when one exists, such as `Closes #123`.
- If there is no related issue, replace the placeholder with `N/A`.

### Type of change

- Mark only the boxes that actually apply.
- Prefer the smallest accurate set of categories.

### Changes made

- Summarize the main edits as short bullets.
- Group related changes together instead of listing every file.
- Keep bullets concrete and easy to scan.

### Release Notes

- Describe the user-facing impact, who is affected, and any migration
  or upgrade notes.
- If no release notes are needed, write `N/A`.

### Checklist

- Only mark items complete when the current branch really satisfies
  them.
- Do not claim tests, docs, or breaking-change validation that were
  not actually done.

### Additional notes

- Use this for reviewer guidance, tradeoffs, follow-up work, or
  anything that helps review move faster.
- Omit unnecessary filler if there is nothing extra to say.

## Workflow

- If `.jj` is present, use `jj` instead of `git` for all commands.
- Review the current branch diff against the PR base branch.
- Inspect the existing commits and working tree to understand the full
  scope of the change.
- Read `.github/pull_request_template.md` and use it to draft the PR
  title and body.
- Identify any related issues, release-note implications, testing
  status, and reviewer notes from the diff and repo context.
- Create the pull request as a draft unless the user explicitly asks
  for a ready-for-review PR.
- After creating the PR, return the PR number and URL to the user.
