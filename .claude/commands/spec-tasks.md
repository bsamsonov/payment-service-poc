---
description: Break an approved plan into ordered, PR-sized tasks
argument-hint: <NNN-short-name>
---
Write `specs/$1/tasks.md` from `specs/_template/tasks.md` based on `specs/$1/plan.md`.

- Order tasks so the build stays green after each one; each task maps to AC ids.
- Each task is one pull request (one or more commits): about 600 changed lines of non-generated code at most
  (tests included), green and meaningful on its own — split a larger task. Small adjacent tasks may share one PR:
  mark the later one `(same PR as Tn)`. A task split later becomes `T7.1`, `T7.2` (no renumbering).
  The last task sets `Implemented`.
- Each task updates the living docs its behavior change affects (`AGENTS.md`, Documentation); no docs-only
  catch-up task at the end.
- Each task starts with a failing test (except pure configuration/migration tasks — state how they are verified).
- Commit (`docs(spec): tasks NNN …`).
