---
description: Check that the implementation matches the spec (ACs, non-goals, contract)
argument-hint: <NNN-short-name>
---
Verify the implementation of `specs/$1/` against the code on the current branch. Report, do not fix.

1. Every `AC-n` in `spec.md` has at least one test whose `@DisplayName` starts with `AC-n:` — list ACs with test names;
   flag missing ones.
2. No non-goal is implemented — flag any code that does.
3. API changes match `api/openapi.yaml`; data changes match the migrations.
4. Open questions are resolved or explicitly deferred.
5. `tasks.md` checkboxes reflect reality.
Output a short table: item, status (ok / missing / mismatch), evidence (file:line).
