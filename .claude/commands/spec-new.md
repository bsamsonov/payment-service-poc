---
description: Interview the owner and draft a new feature spec from the template
argument-hint: <NNN-short-name> [issue or short description]
---
Create `specs/$1/spec.md` from `specs/_template/spec.md` for: $ARGUMENTS

1. Read `AGENTS.md`, `specs/README.md`, existing specs and `api/openapi.yaml` (if present) for context.
2. Before writing, interview me: ask focused questions (in rounds, numbered, each with your recommended answer) about
   scope, non-goals, edge cases, errors, idempotency, security, audit and data. Wait for my answers.
3. Draft `spec.md` with status `Draft`: numbered acceptance criteria in Given/When/Then, an errors table and explicit
   non-goals. Put anything still undecided under "Open questions" — do not guess.
4. Keep it to one coherent feature (split otherwise); it may ship in several PRs (`specs/README.md`). Commit the draft (`docs(spec): draft NNN …`) and show me the open questions.
