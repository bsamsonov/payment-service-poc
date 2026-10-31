# 001. Payment core — plan

Spec: [spec.md](spec.md)

## Approach
Hexagonal slice through all layers, contract-first:
`api/openapi.yaml` → generated interface + DTOs → web adapter → `CreatePaymentUseCase` / `GetPaymentQuery` → domain
(`Payment`, state machine) → ports `PaymentRepository`, `PaymentJournal`, `PaymentProvider` → adapters (JPA, fake).
Every status change goes through `PaymentStatusApplier`. The use case controls transactions explicitly with
`TransactionTemplate` (Tx 1 → provider call → Tx 2) instead of `@Transactional`, so the "no transaction during the
provider call" rule is visible in code and testable (AC-13).

## Components (packages and classes)
Module `io.github.bsamsonov.paymentservice.payment`; package names below are relative to it. Every package has
`package-info.java` with `@NullMarked`.

| Package | Classes | Notes |
|---|---|---|
| `domain` | `Payment` (aggregate), `PaymentId` (UUIDv7), `Money`, `CurrencyPolicy`, `PaymentStatus` (transition table), `FailureCode`, `PaymentEvent` (+ `EventType`, `ActorType`, `EventSource`), `ProviderOutcome` (sealed: `Succeeded`, `Declined(code, providerCode)`, `Rejected`, `Unknown`), `ProviderAttempt`, `TransitionResult` (`Applied`, `NoOp`, `Rejected`) | no Spring/JPA/Jackson; `Clock` passed in |
| `application` | `CreatePaymentUseCase`, `GetPaymentQuery`, `PaymentStatusApplier`, `RequestHasher` (canonical JSON → SHA-256), `CreatePaymentCommand`, `BusinessRuleViolation` (collects all 422 errors), ports `PaymentRepository`, `PaymentJournal` (events and provider attempts), `PaymentProvider`, `TraceContext` | may use `spring-tx` (`TransactionTemplate`) only |
| `adapter.in.web` | `PaymentsController` (implements generated `PaymentsApi`), `PaymentWebMapper`, `ProblemDetailsHandler` (`@RestControllerAdvice`, extends `ResponseEntityExceptionHandler`), `TraceparentResponseFilter`, `FailureMessages` (dictionary), `RejectedRequestAuditLog` (`AUDIT` line for `400`/`422`) | generated code in `adapter.in.web.api` / `.model` |
| `adapter.out.persistence` | `PaymentEntity`, `PaymentEventEntity` (`@Immutable`), `ProviderAttemptEntity` (`@Immutable`), Spring Data repositories (no delete methods), `JpaPaymentRepository`, `JpaPaymentJournal`, mappers | domain ↔ entity mapping; entities never leave the adapter |
| `adapter.out.provider.fake` | `FakePaymentProvider` | `@ConditionalOnProperty(payments.provider=fake)`; table from spec |
| `adapter.out.tracing` | `MicrometerTraceContext` | current trace id from Micrometer `Tracer` |
| `config` | `PaymentsProperties` (`@ConfigurationProperties`: provider, currency allow-list, min/max), `ClockConfig`, `TransactionConfig` | |

Status applier algorithm (AC-10, AC-11, AC-14): load the payment and `max(sequence_no)` of its events in one query
(one snapshot, before the decision) → `payment.apply(target, data)` returns `Applied | NoOp | Rejected` → for
`Applied`/`Rejected` append event with `sequence_no = max + 1` → save (only `Applied` changes `payments`) → commit.
`max` read after the decision could already include a concurrent transition, so a `Rejected` event computed from a
stale status would get the next free number and no conflict; read with the payment, it collides with that transition.
On `ObjectOptimisticLockingFailureException` or a violation of `payment_events_sequence_unique`: re-read and
re-apply, at most 3 attempts, then fail loudly (ERROR log; the payment stays in its last committed state).

## Data model and migrations
Flyway, `src/main/resources/db/migration`:
- `V1__coded_value_domains.sql` — domains per spec (`text` + named `CHECK` of the 001 values, `COMMENT ON DOMAIN`).
- `V2__append_only_guard.sql` — function `forbid_append_only_change()`, shared by both logs.
- `V3__payments.sql` — `payments` per spec; index `(external_reference, created_at DESC)`.
- `V4__payment_events.sql` — the audit log per spec; FK without cascade; `UNIQUE (payment_id, sequence_no)`; row and
  truncate triggers.
- `V5__provider_attempts.sql` — the provider call log per spec; index on `payment_id`; the same triggers.

Coded values are domains; the Java enums are the source of the sets, and an IT checks that every enum constant is
accepted by its domain (T6). An entity field on a domain column declares `@Column(columnDefinition = "<domain>")`:
PgJDBC reports such a column as `DISTINCT <domain>`, and `validate` matches it by that name. Strings are `text`
(`String` maps to it under `validate`), every constraint is named. JSON column (`metadata`): `jsonb` via Hibernate
`@JdbcTypeCode(SqlTypes.JSON)`. The schema went through an architecture review before PR A was merged (coded values,
provider attempts apart from the audit log, no snapshot, no `rejected_requests` table). Flyway owns the schema;
Hibernate runs with `spring.jpa.hibernate.ddl-auto=validate`, so a mismatch between the entities and the migrated schema
(missing table/column, incompatible type) fails startup and every IT. Local DB: `compose.yaml` with `postgres:17` +
`spring-boot-docker-compose` (dev only). Tests: Testcontainers `postgres:17` via a shared `@TestConfiguration` with
`@ServiceConnection`; the existing context tests start using it.

## Sequence
```mermaid
sequenceDiagram
  participant C as Client
  participant W as Web adapter
  participant U as CreatePaymentUseCase
  participant DB as PostgreSQL
  participant P as PaymentProvider
  C->>W: POST /payments (traceparent?)
  W->>W: schema validation (400 → AUDIT log)
  W->>U: CreatePaymentCommand
  U->>U: business rules (422 → AUDIT log), request hash
  U->>DB: Tx1: payment PENDING + PAYMENT_CREATED
  U->>P: charge(paymentId, amount, pm)  [no transaction]
  P-->>U: outcome + attempts
  U->>DB: Tx2: provider_attempts×n + status + STATUS_CHANGED
  U-->>W: payment / outcome
  W-->>C: 201 | 402 | 502 | 202 (+ Location, traceparent)
```

## Transactions and concurrency
- Tx 1 and Tx 2 via `TransactionTemplate`; the provider call between them. Rejected requests touch no database.
- Optimistic locking (`@Version`) on `payments` for status changes; `UNIQUE (payment_id, sequence_no)` for every
  journal write, so a rejected transition does not change the payment row and sequence numbers never collide.
- No pessimistic locks. Retry of the applier only (bounded, re-reads fresh state).
- Hikari pool stays default; virtual threads already enabled — the provider call holds no connection.

## Validation split (400 vs 422)
- Schema-level (generated Bean Validation + strict Jackson): required, types, length, patterns, unknown fields
  (`spring.jackson.deserialization.fail-on-unknown-properties: true`) → `400`. Jackson coerces by default, so
  `accept-float-as-int: false` and `spring.jackson.mapper.allow-coercion-of-scalars: false` make `19.99`, `1999.0` and
  `"1999"` a `400` instead of a truncated or parsed amount (`JacksonStrictnessTest`).
- `metadata`: the generated `@Size` covers the pair count and value length; the key length (≤ 40) cannot be expressed
  in OpenAPI 3.0, so the web adapter checks it explicitly and reports it as a field error (`400`).
- Business limits are **not** in the OpenAPI schema as `minimum`/`maximum` (the generator would turn them into
  `@Min`/`@Max` → `400`); they live in `CurrencyPolicy` and produce `422`. The schema documents them in `description`.
- Malformed path UUID → `404` (handler maps `MethodArgumentTypeMismatchException` on `id`).
- `ProblemDetailsHandler` writes one `AUDIT` log line (fields per spec, no values) for every `400`/`422` on any
  endpoint; `404` is not recorded in 001.

## Tracing
`spring-boot-micrometer-tracing-opentelemetry` (Micrometer → OTel bridge), W3C propagation (Boot default), no exporter
(export disabled until 008). `TraceparentResponseFilter` writes the current span's `traceparent` to every response.
Trace id lands in MDC (logs) and in journal rows via the `TraceContext` port.

## Dependencies (to add)
`spring-boot-starter-data-jpa`, `spring-boot-starter-flyway` + `flyway-database-postgresql`, `postgresql`,
`spring-boot-micrometer-tracing-opentelemetry` (exact artifact set verified in T1), `uuid-creator` 6.1.1
(JDK 25 has no UUIDv7 factory — checked), `spring-boot-docker-compose` (optional, dev);
test: `spring-boot-testcontainers`, `testcontainers-postgresql`, `testcontainers-junit-jupiter`.
Plugin: `openapi-generator-maven-plugin` 7.26.0, generator `spring`: `interfaceOnly`, `useSpringBoot4`,
`useJackson3`, `useBeanValidation`, `openApiNullable=false`, `skipDefaultInterface`, `useTags`.
Added in T2: `documentationProvider=none`, `annotationLibrary=none` (no springdoc/swagger annotations),
`generateJsonIncludeAnnotations=true` + `containerDefaultToNull=true` (absent optional fields, including empty
collections, are omitted), `generateSupportingFiles=false`. The generator ignores `servers` with `interfaceOnly`, so
the `/api/v1` prefix is part of each path in the contract.
Generated sources are excluded from Spotless, Error Prone/NullAway, SpotBugs and JaCoCo.

## Test strategy
| AC | Test type | Test class |
|---|---|---|
| AC-1 | IT (real server, Testcontainers) | `CreatePaymentIT` |
| AC-2 | IT, parameterized over 4 payment methods | `CreatePaymentIT` |
| AC-3 | IT + `OutputCaptureExtension` for the ERROR line | `CreatePaymentIT` |
| AC-4 | IT | `CreatePaymentIT` |
| AC-5 | slice `@WebMvcTest`, parameterized (shape, all errors) + `OutputCaptureExtension` for the `AUDIT` line (no values) | `PaymentRequestValidationTest` |
| AC-6 | unit (`CurrencyPolicyTest`) + slice + 1 IT case | same + `CurrencyPolicyTest` |
| AC-7, AC-8 | IT | `GetPaymentIT` |
| AC-9 | IT | `FindPaymentsByExternalReferenceIT` |
| AC-10 | unit: full transition table; IT: rejected and conflicting duplicate are journaled, identical duplicate is not | `PaymentStatusTest`, `PaymentTest`, `PaymentStatusApplierIT` |
| AC-11 | IT: sequence, statuses and failure code; rollback when the event insert fails (`@MockitoSpyBean` on the journal) | `PaymentStatusApplierIT` |
| AC-12 | IT via `JdbcTemplate` on both logs | `AppendOnlyJournalIT` |
| AC-13 | IT with a recording provider (`isActualTransactionActive()==false`, payment visible via a separate connection) | `ProviderCallTransactionIT` |
| AC-14 | IT: two threads + `CountDownLatch` on one `PROCESSING` payment → one applied, one rejected, no exception; same for two rejected transitions (sequence collision); a rejection decided on a stale status while another thread commits a transition collides and is re-applied on the new status | `PaymentStatusApplierIT` |
| AC-15 | IT | `CreatePaymentIT` |
| AC-16 | IT with and without `traceparent` | `TracingIT` |
| AC-17 | unit (canonicalization cases) + IT (`payments` column) | `RequestHasherTest`, `CreatePaymentIT` |

Traceability (see `specs/README.md`): every test that covers an AC carries the id in `@DisplayName`, e.g.
`@DisplayName("001/AC-2: declined card returns 402")` (several: `"001/AC-10, 001/AC-14: …"`);
`scripts/spec/check-ac-trace.sh` must pass for all 17 AC. The last commit of the last PR (D) sets `status: Implemented`.

Architecture: enforced by the module and hexagon ArchUnit rules (`ModuleRules`, `HexagonRules`, see `AGENTS.md`).

## Risks
- **Hibernate 7 JSON mapping with Jackson 3** — Hibernate's JSON `FormatMapper` may need Jackson 2 or a custom
  mapper. Verify first in T3; fallback: `FormatMapper` bean on Jackson 3.
- **openapi-generator + Boot 4 / Jackson 3** options are new; generated code may trip Error Prone/NullAway → exclude
  generated sources (done in T2); if the output is unusable, fall back to hand-written DTOs checked against the
  contract with a contract test.
- **Tracing artifact set in Boot 4** (module vs starter, exporter on by default) — verify in T1; export must be off.
- **Coverage gate 80%** with generated code — excluded from JaCoCo.
- **Scope size**: ~17 AC. Mitigation: commit per task; PR A (setup) and PR B (domain) group T1–T6, then one PR per
  task from T7 (`tasks.md`).

## ADR links
- ADR-0006 Contract-first API with generated interfaces (PR A).
- ADR-0007 UUIDv7 identifiers generated in the application (PR A).
- **ADR-0008 Audit architecture** (new, T12): local append-only audit log in the same transaction, the change
  only (no snapshot) + `sequence_no` guarded by a unique key, provider attempts in a separate log, domains for coded
  values (not reference tables), rejected requests in the `AUDIT` log instead of a table (stdout; target retention set
  by the log platform: `AUDIT` ≥ 12 months, application logs ~30 days; metric and JSON audit marker in 008, #23),
  trigger now / DB roles as production option, why not Envers/CDC/pgAudit/event sourcing, hash chain and central store
  as future options.
- ADR-0002 (stack) already covers PostgreSQL/Flyway/JPA/Testcontainers.
