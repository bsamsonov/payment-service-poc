# Specifications

One folder per feature: `specs/NNN-short-name/` with three short files.

| File | Question | Owner |
|---|---|---|
| `spec.md` | **What** and why: scope, non-goals, acceptance criteria (`AC-n`), errors, NFRs, API/data changes, open questions | human (AI interviews and drafts) |
| `plan.md` | **How**: components, data model and migrations, sequence, transactions/concurrency, test strategy per AC, risks, ADR links | AI drafts in plan mode, human reviews |
| `tasks.md` | **Steps**: ordered, commit-sized tasks, each mapped to ACs | AI |

Lifecycle: `Draft → Approved → Implemented` (→ `Superseded` by a later spec). After implementation a spec is frozen;
the living truth is `api/openapi.yaml`, `docs/architecture.md` and the code. A spec is 1–2 pages; split bigger features.

Commands: `/spec-new`, `/spec-plan`, `/spec-tasks`, `/spec-verify`. Templates: `_template/`.
