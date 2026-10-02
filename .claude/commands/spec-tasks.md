---
description: Break an approved plan into ordered, commit-sized tasks
argument-hint: <NNN-short-name>
---
Write `specs/$1/tasks.md` from `specs/_template/tasks.md` based on `specs/$1/plan.md`.

- Order tasks so the build stays green after each one; each task maps to AC ids and is one commit.
- Each task starts with a failing test (except pure configuration/migration tasks — state how they are verified).
- Commit (`docs(spec): tasks NNN …`).
