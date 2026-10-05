# Review context

Condensed project knowledge for AI reviewers (`/pr-review`). It replaces `AGENTS.md` for reviewers: only what is
needed to judge a change, nothing about how to build, commit or run hooks. Keep it in sync with `AGENTS.md` and the
ADRs; when they disagree, `AGENTS.md` wins and this file is fixed in the same PR.

## What the service is
Internal payment service (proof of concept). Internal services (`order-service` with full rights, `reporting-service`
read-only) call our REST API with JWTs; we charge cards through Stripe (test mode) with our own HTTP adapter, no SDK.
Java 21, Spring Boot 4.1 (Spring MVC), PostgreSQL + Flyway, JPA/Hibernate, Resilience4j, Spring Security.

## Architecture
- Hexagonal, root package `io.github.bsamsonov.paymentservice`:
  `domain` (pure Java: no Spring, no JPA), `application` (use cases and ports), `adapter.in.web`,
  `adapter.out.persistence`, `adapter.out.stripe`, `config`. Dependencies point inwards only.
- Constructor injection only; records for DTOs and value objects.
- Null safety: every package is `@NullMarked` (JSpecify); nullable values are explicit `@Nullable`.
- Already enforced by CI (do not report): formatting, Error Prone/NullAway, field injection, `System.out`,
  generic exceptions, `java.util.logging`, coverage threshold, SpotBugs/FindSecBugs, CodeQL, secrets scan.

## Domain invariants
- **Money**: `amount` is a `long` in minor units plus a `Currency`; never `double`/`float`. Currencies come from a
  configured allow-list (v1: USD only) with the number of fraction digits per currency. Minimum $0.50, at most
  8 digits.
- **Payment status**: `PENDING → PROCESSING → SUCCEEDED | FAILED`; refunds move `SUCCEEDED → PARTIALLY_REFUNDED |
  REFUNDED` and `PARTIALLY_REFUNDED → REFUNDED`. Transitions only forward; the exact table is defined by spec 001. Four sources change status — synchronous provider response, webhook, reconciler,
  refunds — and all of them go through one status-applying component.
- **Audit**: every transition is appended to `payment_events` in the same transaction as the state change;
  the table is append-only (`UPDATE`/`DELETE` denied to the application DB role).
- **Refunds**: full or partial; the total refunded never exceeds the payment amount.
- **Identifiers**: payment `id` is UUIDv7. The Stripe PaymentIntent id is never exposed in the API.

## External calls (Stripe)
- Never call Stripe inside a database transaction.
- Explicit timeouts: connect 2 s, read 5 s. Up to 2 retries within ~5 s, always with the same Stripe
  idempotency key (deterministic, derived from the payment id).
- PaymentIntent with `confirm=true`, `error_on_requires_action=true` (3DS → `FAILED`).
- Circuit breaker open → `503`, checked before a payment is created (no payment row).

## Idempotency
- `(client_id, Idempotency-Key)` is unique forever (stored on the payment row, unique index).
- The stored response (status + body) is cached for 24 h and only for started operations: `201`, `202`, `402`.
  Not cached: `400`, `422`, `429`, `503`.
- Same key + different body → `422`; concurrent request with the same key → `409`; same key after the cache expired
  → `200` with the current payment state, no provider call.

## Webhooks
- Verify the Stripe HMAC signature (5 min tolerance) before parsing or acting on the payload.
- Deduplicate by `event.id`. Unknown payment → `200` and a log line.
- Handled events: `payment_intent.succeeded`, `payment_intent.payment_failed`, `charge.refunded` / `refund.updated`.

## API and errors
- REST under `/api/v1`; `api/openapi.yaml` is the contract and changes only together with a spec change.
- Errors are RFC 9457 Problem Details. No stack traces, SQL, provider raw messages or internal ids in responses;
  `failure` carries a code and a safe message.
- Codes: `201` created; `402` + Problem Details with `paymentId` and `Location` for a card decline; `202` with
  `PROCESSING` on provider timeout; `503` circuit breaker open; `400`/`422` validation.

## Security
- Scopes `payments:read`, `payments:write`, `payments:refund`. A client sees only its own payments; another client's
  payment is `404`, not `403`.
- Secrets only from environment variables; never committed, never logged.

## Logging
- Log identifiers (payment id, client id, event id), never card data, secrets, tokens, full request/response bodies
  or PII. No log-and-rethrow of the same error at several layers.

## Testing conventions
- Unit tests `*Test` (no Spring context where possible); integration tests `*IT` with real PostgreSQL
  (Testcontainers, no H2) and WireMock for HTTP (HTTP clients are not mocked).
- Acceptance tests carry the AC id: `@DisplayName("AC-2: …")`. Test names state behavior.

## Process facts useful for review
- Features come from `specs/NNN-name/{spec,plan,tasks}.md`; non-goals in the spec must not be implemented.
- Decisions live in `docs/adr/` (MADR); accepted ADRs are never edited, only superseded.
- Analyzer suppressions and lowered thresholds require a written justification.
