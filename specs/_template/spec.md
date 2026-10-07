---
id: NNN
title: <Feature title>
status: Draft  # Draft | Approved | Implemented | Superseded
issue: "#<n>"
supersedes: []     # specs this one replaces as a whole, e.g. ["001"]
amends: []         # specs this one changes in part
superseded_by: ""  # back-link, set later on a frozen spec
amended_by: []     # back-links, set later on a frozen spec
---

# NNN. <Feature title>

## Context
Why this feature exists and who calls it.

## Scope
- …

## Non-goals
Explicitly out of scope — must NOT be implemented.
- …

## Flow
Main scenario and alternatives (Mermaid sequence diagram if helpful).

## Acceptance criteria
Tests reference these as `NNN/AC-n` in `@DisplayName`. A replaced AC keeps its text and gets a back-link:
`- **AC-2** (superseded by MMM/AC-1) …`.
- **AC-1** Given …, when …, then …
- **AC-2** …

## Changes to earlier specs
Only for a spec that `supersedes` or `amends` another; delete otherwise.
| Earlier AC | Change | Replaced by |
|---|---|---|
| NNN/AC-n | removed / changed: … | AC-n |

## Errors
| Situation | HTTP status | Problem `type` |
|---|---|---|

## Non-functional requirements
Latency, audit, PII, idempotency, limits.

## API changes
Operations in `api/openapi.yaml` added or changed.

## Data changes
Tables, columns, constraints, migrations.

## Open questions
Questions for the owner. Do not guess answers.
