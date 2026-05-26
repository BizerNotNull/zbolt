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

### Branch source

- This repository does not accept pull requests whose source branch is
  `main` or `master`.
- Always create a new branch before preparing commits, pushing, or
  opening a pull request.
- If the current work is on `main` or `master`, create a new branch
  from the appropriate base branch and move the PR work there before
  continuing.
- Do not open or draft a PR until the changes are on a non-default
  branch.

### Branch naming

- Name the PR branch after the change scope and intent.
- Prefer lowercase branch names with hyphen-separated words.
- Keep branch names short, descriptive, and easy to review at a
  glance.
- Prefer a prefix when it clarifies the type of change, such as
  `docs/`, `fix/`, `feat/`, `refactor/`, `build/`, or `ci/`.
- Avoid spaces, uppercase letters, vague names, and generic names such
  as `update`, `test`, or `temp`.
- When the work maps to an issue, include the issue number when it
  helps disambiguate, such as `fix/123-broken-pr-template`.

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
- Determine the PR submitter identity before creating branches,
  pushing, or opening the PR. Record the identity as one of:
  `maintainer`, `contributor`, or `fork-based downstream developer`.
- If you are not sure whether the user is acting as a `contributor`
  or a `fork-based downstream developer`, ask the user to choose
  before creating the PR. Do not guess.
- Review the current branch diff against the PR base branch.
- Inspect the existing commits and working tree to understand the full
  scope of the change.
- Read `.github/pull_request_template.md` and use it to draft the PR
  title and body.
- Identify any related issues, release-note implications, testing
  status, and reviewer notes from the diff and repo context.
- Follow the branch and remote workflow that matches the PR submitter
  identity:
  - `maintainer`: create a new branch in the local repository, push it
    to the main remote repository, and open a PR from that remote
    branch to the appropriate base branch in the same repository.
  - `contributor`: create a new branch in the user's forked
    repository, push it to the fork, and open a PR from the forked
    branch to the upstream repository's appropriate base branch.
  - `fork-based downstream developer`: create a new branch in the
    repository used for the downstream fork, push it to that remote
    repository, and open a PR against the appropriate base branch in
    that same remote repository unless the user says otherwise.
- Create the pull request as a draft unless the user explicitly asks
  for a ready-for-review PR.
- State the PR submitter identity explicitly when reporting the final
  PR result to the user, and include it in the PR notes when that
  context would help reviewers understand the source repository or
  branch flow.
- After creating the PR, return the PR number and URL to the user.
