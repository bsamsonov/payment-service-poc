# 001. Payment core — tasks

Each task is one commit (or a few): failing test first, then code; the build is green after each task.
Tests that cover an AC carry `@DisplayName("001/AC-n: …")`. T1–T3 come first because they retire the plan's risks.
Four PRs (`specs/README.md`); the last one sets `status: Implemented`.

## PR A — setup, contract, schema (AC-12)

- [x] T1 (setup) Dependencies and test infrastructure: JPA, Flyway + `flyway-database-postgresql`, `postgresql`,
  tracing (verify the Boot 4 artifact set; export off), `uuid-creator`, Testcontainers; `compose.yaml` +
  `spring-boot-docker-compose` (dev); shared `@TestConfiguration` with `@ServiceConnection` `postgres:17`;
  `spring.jpa.hibernate.ddl-auto=validate`, `fail-on-unknown-properties: true`.
  Verified by: the context test (`PaymentServiceApplicationIT`) passes against PostgreSQL; no exporter bean.
- [x] T2 (setup) Contract: `api/openapi.yaml` per spec (business limits only in `description`); openapi-generator
  plugin with the plan's options; generated sources excluded from Spotless, Error Prone/NullAway, SpotBugs, JaCoCo;
  ArchUnit layer rules from the plan (`allowEmptyShould(true)` until the packages exist).
  Verified by: `verify -Pci` green with the generated `PaymentsApi` compiled; ArchUnit test passes.
- [x] T3 (AC-12) Migrations `V1`–`V3` (`currency varchar(3)` + `CHECK`, journal triggers) and JPA entities including
  `jsonb` columns (Hibernate 7 JSON with Jackson 3 — fallback `FormatMapper` bean). Test first: `AppendOnlyJournalIT`
  (`UPDATE`/`DELETE`/`TRUNCATE` rejected with SQLSTATE `42501` on both journals); entity round trip of a `jsonb` column.

## PR B — domain, journal, status applier (AC-10, AC-11, AC-14, AC-17)

- [ ] T4 (AC-10) Domain: `PaymentId`/event ids (UUIDv7), `Money`, `CurrencyPolicy`, `PaymentStatus` transition table,
  `FailureCode`, `ProviderOutcome`, `Payment.apply` → `Applied | NoOp | Rejected` (incl. `conflicting_duplicate`).
  Tests first: `PaymentStatusTest` (full table), `PaymentTest`, `CurrencyPolicyTest` (unit part of AC-6).
- [ ] T5 (AC-17) `RequestHasher`: canonical JSON (sorted keys, no insignificant whitespace) → SHA-256.
  Test first: `RequestHasherTest` (key order, whitespace, nested `metadata`, different values → different hash).
- [ ] T6 (AC-10, AC-11, AC-14) Ports and JPA adapters (`PaymentRepository`, `PaymentJournal`), `TraceContext` port +
  `MicrometerTraceContext`, `PaymentStatusApplier` with `last_event_seq`, `@Version` and bounded retry.
  Tests first: `PaymentStatusApplierIT` (sequence and snapshot, rollback on failed event insert, rejected and
  conflicting duplicate journaled, identical duplicate not, two threads on one `PROCESSING` payment).

## PR C — API: create and read payments (AC-1…AC-9, AC-13, AC-15)

If it grows past ~600 lines: T7–T8 and T9–T10 as two PRs.
- [ ] T7 (AC-1, AC-13, AC-15, AC-17) `CreatePaymentUseCase` (Tx 1 → provider → Tx 2 via `TransactionTemplate`),
  `FakePaymentProvider` (success path), `PaymentsController` `POST`, `PaymentWebMapper`, base `ProblemDetailsHandler`.
  Tests first: `CreatePaymentIT` (AC-1, AC-15, AC-17 column and event), `ProviderCallTransactionIT` (AC-13).
- [ ] T8 (AC-2, AC-3, AC-4) Remaining provider outcomes: `DECLINED` → `402`, `REJECTED` → `502` + ERROR log,
  `UNKNOWN` → `202` `PROCESSING`; `FailureMessages` dictionary; fake provider table complete.
  Tests first: `CreatePaymentIT` cases (parameterized declines, `OutputCaptureExtension`, timeout).
- [ ] T9 (AC-5, AC-6) Validation: `400` with all field errors (schema, unknown fields, malformed JSON, lowercase
  currency), `422` from `CurrencyPolicy` via `BusinessRuleViolation`; `RejectedRequestRecorder` + `rejected_requests`
  adapter written by `ProblemDetailsHandler`. Tests first: `PaymentRequestValidationTest` (slice), `RejectedRequestsIT`.
- [ ] T10 (AC-7, AC-8, AC-9) `GetPaymentQuery`, `GET /payments/{id}` (malformed id → `404`) and
  `GET /payments?externalReference=…` (≤ 20, newest first, missing parameter → `400`).
  Tests first: `GetPaymentIT`, `FindPaymentsByExternalReferenceIT`.

## PR D — tracing, ADR, final check (AC-16)

- [ ] T11 (AC-16) `TraceparentResponseFilter`; trace id in MDC and journal rows.
  Test first: `TracingIT` (with valid, invalid and no `traceparent`).
- [ ] T12 (docs) ADR-0008 audit architecture; README / living docs updated for the new API.
  Verified by: review; links resolve.
- [ ] T13 (all) Final check: `scripts/spec/check-ac-trace.sh` passes for AC-1…AC-17, `verify -Pci` green, coverage
  ≥ 80%; spec `status: Implemented`. Verified by: CI.
