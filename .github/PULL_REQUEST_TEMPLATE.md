## What and why
<!-- 2–5 lines. Link the issue: Closes #… -->

## Spec
<!-- specs/NNN-name/spec.md, or "n/a" for fix/chore. The last commit of a feature PR sets status: Implemented. -->
- [ ] NNN/AC-1
- [ ] NNN/AC-2

## How it was verified
<!-- tests added/changed, manual checks (curl, logs), screenshots -->

## Risks and rollback
<!-- what could break, how to roll back -->

## Checklist
- [ ] Atomic commits, Conventional Commits; history tidy (no "wip"/"fix" noise)
- [ ] Tests for every acceptance criterion; `./mvnw verify` green locally
- [ ] Living docs updated if behavior changed (`api/openapi.yaml`, `docs/architecture.md`, README, ADR)
- [ ] No secrets, card data or PII in code, logs or test fixtures
- [ ] AI review (`/pr-review`) findings resolved or answered
