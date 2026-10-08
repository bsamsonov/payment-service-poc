# Product requirements (v1)

Project-level requirements: what the service is for, what v1 covers and in which order it is built.
This is the overview that every feature spec starts from. It is **not** a source of acceptance criteria:
exact behavior, errors and status codes are defined by the specs in `specs/`, and once a feature is implemented the
living truth is `api/openapi.yaml`, the acceptance tests and the code. If a spec refines something stated here, the
spec wins and this file is updated in the same PR.

## Purpose and users
Internal services (e.g. `order-service`) charge a customer's payment method through our REST API; the service
charges via Stripe (test mode), stores payments in PostgreSQL and keeps an audit trail. Internal reporting
(`reporting-service`) reads payments. There are no end users and no frontend.

## Scope of v1
- **Charging** via Stripe with our own HTTP adapter (no Stripe SDK): PaymentIntent with `confirm=true` and
  `error_on_requires_action=true` (3-D Secure → payment `FAILED`); Stripe's default capture (`automatic_async`).
- **Money**: amounts in minor units, `Money(long, Currency)`. Only USD, but through a currency reference with the
  number of decimals per currency. Minimum $0.50, at most 8 digits.
- **Statuses**: `PENDING → PROCESSING → SUCCEEDED/FAILED → PARTIALLY_REFUNDED/REFUNDED`, forward only. Four sources
  of transitions — synchronous provider response, webhook, reconciler, refunds — all go through one status-applying
  component.
- **API** under `/api/v1`: `POST /payments` (with `Idempotency-Key`), `GET /payments/{id}`,
  `GET /payments?externalReference=`, `POST /payments/{id}/refunds`, `POST /webhooks/stripe`.
- **Payment fields**: `id` is UUIDv7. Request: `amount`, `currency`, `paymentMethodId`, `externalReference`,
  `description`, `metadata` (≤ 10 keys). Response adds `status`, `refundedAmount`, `failure` (code + safe message) and
  timestamps. The Stripe PaymentIntent id is never exposed.
- **Responses**: `201` charged; `402` Problem Details with `paymentId` and `Location` — declined by the bank;
  `202` + `PROCESSING` — outcome unknown (timeout); `503` — circuit breaker open (checked before a payment is created,
  so none is created); `400`/`422` — validation. Errors are RFC 9457 Problem Details.
- **Calls to Stripe**: connect timeout 2 s, read timeout 5 s; up to 2 retries within a ~5 s budget, with the same
  deterministic Stripe idempotency key derived from the payment id.
- **Idempotency**: a key is unique per (`client_id`, key) forever — a repeat never creates a second payment. A repeat
  returns the stored response (kept 24 h; only for operations that started: `201`, `202`, `402`), later the current
  state of the payment; a different body with the same key → `422`; a concurrent repeat → `409`.
- **Security**: JWT with scopes `payments:read`, `payments:write`, `payments:refund`; `order-service` has all of them,
  `reporting-service` read only. A client sees only its own payments; another client's payment → `404`.
- **Webhooks**: `payment_intent.succeeded`, `payment_intent.payment_failed`, `charge.refunded` / `refund.updated`;
  HMAC signature with a 5-minute tolerance; deduplication by `event.id`; unknown payment → `200` and a log line.
- **Refunds**: full and partial; the refunded total never exceeds the payment amount.
- **Audit**: every status change and every failed attempt is recorded in an append-only journal in the same
  transaction; service columns via Spring Data Auditing; read auditing is optional. The design and the rejected
  alternatives (Envers, CDC, pgAudit) go to an ADR "Audit architecture".
- **Reconciler**: resolves payments stuck in `PENDING`/`PROCESSING` against Stripe; also cleans up expired idempotency
  responses. Lowest priority.
- **Observability** (optional): Actuator, Micrometer metrics, JSON logs, OpenTelemetry export to a local
  `grafana/otel-lgtm`.

## Non-functional requirements
- Latency: p95 < 300 ms excluding the Stripe call (a target, not a gate).
- Never log or persist card data, secrets, tokens, full request bodies or PII.
- No external call inside a database transaction; every external call has explicit timeouts.

## Out of scope for v1
Business deduplication by `externalReference`, list with pagination and filters, Stripe Customers, frontend and
3-D Secure flows, manual capture/void, multiple currencies, chargebacks/disputes, payouts, push notifications,
rate limiting, load testing, Hibernate Envers, CDC/pgAudit. Deployment is not part of the project.

## Roadmap
Each line becomes a spec in `specs/NNN-name/` (written just before implementation, see `specs/README.md`).

| Spec | Covers | Status |
|---|---|---|
| `001-payment-core` | domain, state machine, audit journal, persistence, `POST`/`GET` payments, fake provider | in progress |
| `002-idempotency` | `Idempotency-Key`, stored responses | planned |
| `003-stripe-charge` | Stripe adapter, timeouts, retries, circuit breaker | planned |
| `004-security` | JWT, scopes, clients, ownership | planned |
| `005-stripe-webhooks` | signature check, deduplication, status updates from events | planned |
| `006-refunds` | full and partial refunds | planned |
| `007-reconciler` | resolving stuck payments, idempotency cleanup | planned (low priority) |
| `008-observability` | metrics, JSON logs, OpenTelemetry export | optional |

Update the status column when a spec is approved or implemented.
