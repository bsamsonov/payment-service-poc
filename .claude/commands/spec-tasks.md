---
description: Break an approved plan into ordered, commit-sized tasks
argument-hint: <NNN-short-name>
---
Write `specs/$1/tasks.md` from `specs/_template/tasks.md` based on `specs/$1/plan.md`.

- Order tasks so the build stays green after each one; each task maps to AC ids.
- Each task is one pull request (one or more commits): about 600 changed lines of non-generated code at most
  (tests included), green and meaningful on its own — split a larger task. Small adjacent tasks may share one PR:
  mark the later one `(same PR as Tn)`. The last task sets `Implemented`.
- Each task starts with a failing test (except pure configuration/migration tasks — state how they are verified).
- Commit (`docs(spec): tasks NNN …`).
