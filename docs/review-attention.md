# Review attention checklist

Heuristics for the **Architect's attention** section of the `/pr-review` guide. The aggregator reads this file from
the PR head and uses it to pick at most 7 decisions in the PR that deserve the human reviewer's own judgement —
not bugs (those are findings), but choices that are hard to reverse, shape later specs or set a precedent.

Large PRs scatter attention; this section answers one question: *if I can look at only three things, which ones?*

## Categories

Ordered by cost of changing the decision later.

| Category | Meaning | Typical cost of reversal |
|---|---|---|
| `irreversible` | Fixed once merged or released: data, public contract, stored formats | New migration, API version, data backfill |
| `architecture` | Shapes how later specs are built: boundaries, shared config, persistence model | Refactoring across modules |
| `precedent` | Process or convention that later PRs will copy | Re-deciding and re-explaining the rule |
| `minor` | Cheap to change, but worth a conscious decision | One commit |

## What to look for

### Irreversible
- **Migrations**: constraints (`CHECK`, `UNIQUE`, `NOT NULL`, FKs) and triggers that forbid states a later spec may
  need (retries, reconciliation, refunds, webhooks); column types and sizes; data that can never be deleted
  (append-only tables) vs. personal data and retention.
- **Public contract**: paths and versioning, status codes and the `400`/`422` boundary, field types and units
  (amounts in minor units), strict vs. lenient parsing, error format. Anything a client may start relying on.
- **Stored formats**: identifiers (UUIDv7), hashes and their canonicalization (`request_hash`), enum values persisted
  as strings, JSON stored in `jsonb`.
- **Uniqueness and identity**: which keys are unique and how they relate to idempotency (spec 002) and ownership
  (spec 004).

### Architecture
- **Global configuration** that silently applies to future code: shared `ObjectMapper` features, transaction
  defaults, security filters, error handlers. Ask whether provider/webhook adapters need a different setting.
- **Persistence model**: `@Version`, `Persistable.isNew()`, `@Immutable`, cascade and fetch types — what happens on
  `save()` of an existing row and under concurrent updates.
- **Reliance on library defaults** (Hibernate, Jackson, Spring Boot) that an upgrade may change; is there a test
  that pins the behaviour?
- **Boundaries**: what the domain depends on, what goes into the contract vs. code validation, which module owns a
  rule.
- **Dependencies** that pull in more than needed (exporters, auto-configurations) or lock a version.

### Precedent
- Spec status vs. the change (does a data-model change keep the spec `Approved`?).
- Work deferred to a later PR or spec — is it recorded where it will be picked up?
- Test conventions (shared database, never-cleaned tables, unique fixtures) that later tests will copy.
- New exceptions to rules (suppressed checks, excluded files).

### Minor
- Health checks, logging, small coverage gaps that are cheap to close now.

## Lessons from past PRs

Ratchet: after each PR, add what the human reviewer found important but the guide missed, or what turned out to be
noise. Keep entries short and concrete.

- PR #13 (001, setup/contract/schema): the decisions worth time were the `CHECK` constraints on `payments` and
  `payment_events`, the append-only trigger vs. personal data in `metadata`, the global strict Jackson settings, and
  the `isNew()`/`@Version` persistence model — none of them was a bug finding.
