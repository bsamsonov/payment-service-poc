---
description: Draft the technical plan for an approved spec
argument-hint: <NNN-short-name>
---
Write `specs/$1/plan.md` from `specs/_template/plan.md`.

1. Verify `specs/$1/spec.md` has `status: Approved`; if not, stop and say so.
2. Read the spec, `AGENTS.md`, relevant code and ADRs. Use plan mode thinking: propose the approach, components,
   migrations, transaction boundaries, concurrency handling and a test per acceptance criterion.
3. If a significant decision is needed, propose an ADR in `docs/adr/` (MADR) instead of burying it in the plan.
4. Show me the plan for review; after my approval commit it (`docs(spec): plan NNN …`).
