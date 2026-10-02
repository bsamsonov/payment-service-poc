# AGENTS.md — instructions for coding agents (and humans)

This file is the single source of project rules for every coding agent (Claude Code, OpenCode, …).
`CLAUDE.md` imports it and adds Claude-specific notes.

## Project
Proof-of-concept internal payment service: internal services call our REST API; we charge via Stripe (test mode).
Stack: Java 21 (release target), Spring Boot 4.1, Spring MVC, PostgreSQL + Flyway, JPA/Hibernate, Resilience4j,
Spring Security (JWT), Testcontainers, WireMock, Maven wrapper.

## Commands
| Purpose | Command |
|---|---|
| Format code | `./mvnw spotless:apply` |
| Fast check (compile + Error Prone/NullAway, unit tests, ArchUnit) | `./mvnw verify -DskipITs -Djacoco.skip=true` |
| Full check, as in CI (+ integration tests, coverage gate) | `./mvnw verify` |
| CI-only analyzers (SpotBugs/FindSecBugs) | `./mvnw verify -Pci` |
| Install git hooks (once per clone) | `lefthook install` |

Integration tests (`*IT`) need Docker (Testcontainers).

## Workflow
1. Features (`feat`) start only from an approved spec in `specs/NNN-name/` (`spec.md` → `plan.md` → `tasks.md`).
   Fixes/chores/refactorings need an issue only.
2. Test first: write a failing test for an acceptance criterion, then the code.
3. **Commit after every logical block** — a task from `tasks.md`, a passing test with its code, a coherent config
   or documentation change. Each commit compiles and its tests pass, so any commit is a safe rollback point.
   This applies to documentation too. Never batch a day of work into one commit.
4. If implementation needs different behavior than the spec, update the spec first, in the same PR, explicitly.
5. Do not implement anything listed under a spec's non-goals. Do not guess answers to open questions — ask.

## Git
- Conventional Commits: `<type>(<scope>): <subject>` (≤ 72 chars), types: feat fix docs style refactor perf test
  build ci chore revert. Body explains *why* when not obvious.
- Branches: `feat/NNN-short-name`, `fix/…`, `chore/…`, `docs/…`. Work only through pull requests; `main` is protected.
- Merge strategy: rebase merge (linear history, atomic commits preserved). Before opening a PR, history may be
  tidied with fixups, but not squashed into one commit.
- Never use `--no-verify`, never disable checks, never lower coverage thresholds or add analyzer suppressions
  to make a build pass. Suppressions require a written justification.

## Architecture
- Hexagonal (ports and adapters), package root `io.github.bsamsonov.paymentservice`:
  `domain` (no Spring, no JPA), `application` (use cases, ports), `adapter.in.web`, `adapter.out.persistence`,
  `adapter.out.stripe`, `config`. Rules are enforced by ArchUnit as layers appear.
- Every package is `@NullMarked` (JSpecify); nullable values are explicit `@Nullable`.
- Constructor injection only. Records for DTOs and value objects.

## Domain rules (payments)
- Money: amounts in minor units (`long`) with a `Currency`; never `double`/`float`. Currencies come from a configured
  allow-list (v1: USD only).
- Payment status changes only forward through the state machine; every transition is recorded in `payment_events`
  in the same transaction.
- Never call external systems (Stripe) inside a database transaction.
- Every external call has explicit connect/read timeouts. Retries only with the same provider idempotency key.
- Idempotency: `(client_id, Idempotency-Key)` is unique forever; only outcomes of started operations are cached.

## Security and logging
- Never log or persist card data, secrets, tokens, full request bodies or PII. Log identifiers, not payloads.
- Secrets come from environment variables (`.env` locally, never committed).
- A client may access only its own payments; other clients' payments return `404`.

## Errors and API
- REST under `/api/v1`, errors as RFC 9457 Problem Details. The OpenAPI contract in `api/openapi.yaml` is the
  source of truth; do not change it without a spec change.

## Testing
- Unit tests `*Test` (no Spring context where possible), integration tests `*IT`.
- Real PostgreSQL via Testcontainers — no H2. External HTTP via WireMock — no mocking of HTTP clients.
- Test names state behavior; acceptance tests carry the AC id: `@DisplayName("AC-2: …")`.
- Coverage gate: 80% lines (merged unit + integration).

## Documentation
- Specs: `specs/`; decisions: `docs/adr/` (MADR, never edited after acceptance — superseded by new ADRs).
- Living docs (`README.md`, `docs/architecture.md`, `api/openapi.yaml`) are updated in the same PR as the behavior change.
