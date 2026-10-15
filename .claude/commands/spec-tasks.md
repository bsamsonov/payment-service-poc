---
description: Break an approved plan into ordered, commit-sized tasks
argument-hint: <NNN-short-name>
---
Write `specs/$1/tasks.md` from `specs/_template/tasks.md` based on `specs/$1/plan.md`.

- Order tasks so the build stays green after each one; each task maps to AC ids and is one commit.
- Group the tasks into pull requests under `## PR A — <theme>` headings: about 600 changed lines of non-generated
  code at most per PR (tests included), each green and meaningful on its own; the last PR sets `Implemented`.
- Each task starts with a failing test (except pure configuration/migration tasks — state how they are verified).
- Commit (`docs(spec): tasks NNN …`).
