# Review checklist

Rules checked by the L1 reviewer of `/pr-review` (see `docs/review-context.md` for the facts behind them).
Every rule gets a verdict per PR: `pass`, `fail` (with `file:line` evidence) or `n/a` (the change does not touch
the rule's scope).

**Ratchet.** The checklist holds only what tools cannot check yet. When a rule becomes enforceable by ArchUnit,
Error Prone, a test or another CI check, move it there and delete it here (keep the id retired, do not reuse it).
Every confirmed review finding that no rule covers is a candidate for a new rule.

Format: `RC-NN — title` · **Scope** (where it applies) · **Check** (what must hold) · **Why**.

## Specification and scope

### RC-01 — Acceptance criteria are traced to tests
- Scope: `feat` PRs with a spec.
- Check: every AC of the spec has at least one test whose `@DisplayName` starts with its id; tests assert the
  behavior the AC describes, not just that code runs.
- Why: the spec is the contract; an untested AC is unimplemented.

### RC-02 — Nothing outside the spec
- Scope: `feat` PRs.
- Check: no behavior listed under the spec's non-goals; no endpoint, field, status or config that the spec and
  `api/openapi.yaml` do not mention. Behavior changes are reflected in the spec in the same PR.
- Why: agents tend to add "helpful" extras that nobody reviews as requirements.

## Domain correctness

### RC-03 — Money is exact
- Scope: code that creates, compares, sums or converts amounts.
- Check: amounts are `long` minor units with a `Currency`; no `double`/`float`; no mixing of currencies; bounds
  (minimum, maximum digits) validated; refunds cannot exceed the remaining amount.
- Why: rounding and overflow errors here are real money.

### RC-04 — Status changes go through the state machine
- Scope: code that sets a payment status.
- Check: status is changed only via the status-applying component; transitions only forward; an illegal transition
  is rejected (or ignored for late duplicates), never silently overwritten; a `payment_events` row is written in the
  same transaction.
- Why: four concurrent sources of truth (sync response, webhook, reconciler, refunds) must not fight.

### RC-05 — Concurrency is handled by the database, not by luck
- Scope: check-then-act sequences, uniqueness, counters, status updates.
- Check: races are closed by a unique constraint, optimistic locking (`@Version`) or a conditional update; the
  losing side gets a defined outcome (`409`, retry, no-op), not a `500`.
- Why: duplicate requests and webhooks arrive in parallel in production.

### RC-06 — Idempotency semantics
- Scope: `POST` endpoints with `Idempotency-Key`, provider calls.
- Check: key scoped by client and unique forever; only started operations (`201`/`202`/`402`) cached; different
  body → `422`; in-flight duplicate → `409`; provider retries reuse the same provider idempotency key.
- Why: a broken idempotency path charges a customer twice.

## External calls and transactions

### RC-07 — No external calls inside a transaction
- Scope: `@Transactional` methods and anything they call.
- Check: no Stripe/HTTP call (directly or through a port) while a DB transaction is open; the provider outcome is
  persisted in a separate, short transaction.
- Why: long transactions hold locks and connections; a rollback cannot undo a charge.

### RC-08 — Resilient outbound HTTP
- Scope: `adapter.out.*` clients.
- Check: explicit connect/read timeouts; retries bounded and only on safe/idempotent failures; circuit breaker
  outcome mapped to the documented response; provider errors mapped to domain outcomes, not leaked.
- Why: a hanging provider must not exhaust the service.

## Security and data

### RC-09 — Access control per client
- Scope: controllers, queries that load payments.
- Check: required scope enforced for each endpoint; queries filter by the authenticated client; another client's
  resource returns `404`.
- Why: IDOR is the most common API vulnerability.

### RC-10 — No sensitive data in logs, errors or storage
- Scope: logging statements, exception messages, Problem Details, entities, test fixtures.
- Check: no card data, secrets, tokens, full request/response bodies or PII; responses expose no stack traces, SQL,
  raw provider messages or the PaymentIntent id.
- Why: PCI scope and data protection; logs are widely readable.

### RC-11 — Webhook trust
- Scope: webhook endpoint and handlers.
- Check: signature verified (with timestamp tolerance) before the payload is used; deduplicated by `event.id`;
  unknown payments acknowledged with `200`; handler is idempotent.
- Why: an unauthenticated webhook lets anyone mark payments as paid.

## Persistence

### RC-12 — Migrations are safe and immutable
- Scope: `src/main/resources/db/migration`, entities.
- Check: merged migrations are never edited; schema changes come as a new migration; invariants also enforced in
  the DB (`NOT NULL`, `CHECK`, `UNIQUE`, FK); `payment_events` stays append-only; entity mapping matches the schema.
- Why: the DB is the last line of defence and the only shared state.

## API and errors

### RC-13 — Contract and error mapping
- Scope: controllers, exception handlers, `api/openapi.yaml`.
- Check: responses match the OpenAPI contract (status codes, fields, Problem Details shape); validation errors are
  `400`/`422` with field details; unexpected errors are `500` without internals.
- Why: clients are coded against the contract.

## Code quality not covered by CI

### RC-14 — Errors are handled once, at the right layer
- Scope: `try`/`catch`, exception translation, logging of errors.
- Check: no swallowed exceptions; no log-and-rethrow; domain exceptions are translated at the adapter boundary;
  logs carry identifiers and the right level.
- Why: double logging hides the real failure; swallowing hides it completely.

### RC-15 — Tests prove behavior
- Scope: tests added or changed.
- Check: negative and edge cases for new behavior (declines, timeouts, duplicates, boundaries); integration tests use
  Testcontainers/WireMock, not mocked HTTP clients or H2; no sleeps for synchronization; assertions are specific.
- Why: tests that only cover the happy path pass right until production.

### RC-16 — No silenced checks
- Scope: whole diff.
- Check: no new `@SuppressWarnings`, `@SuppressFBWarnings`, `// NOPMD`, excluded files, `@Disabled` tests or lowered
  thresholds without a written justification next to them.
- Why: the quality gates only work if they are not bypassed.

## Tooling, CI and docs

### RC-17 — Workflows and scripts are least-privilege and robust
- Scope: `.github/workflows`, `scripts/`, `.claude/`, hooks.
- Check: workflow `permissions` minimal; third-party actions pinned to a major version or SHA; secrets never echoed;
  shell scripts use `set -euo pipefail`, quote variables, fail with a clear message, and clean up temp files;
  agent configs grant no tools beyond what the agent needs.
- Why: CI and agents run with credentials; a sloppy script is a supply-chain entry point.

### RC-18 — Living documentation is updated
- Scope: behavior, configuration or architecture changes.
- Check: `README.md`, `docs/architecture.md`, `api/openapi.yaml`, `AGENTS.md`/`docs/review-context.md` updated in the
  same PR; significant decisions have an ADR; accepted ADRs are not edited.
- Why: stale docs mislead both humans and agents.
