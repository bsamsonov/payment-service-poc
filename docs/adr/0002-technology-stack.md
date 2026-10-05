# 0002. Technology stack

- Status: Accepted
- Date: 2026-10-02

## Context and problem
We need a stack for an internal payment service that matches common enterprise Java practice, is currently supported,
and supports strong automated quality gates.

## Considered options
- Spring Boot 3.5 vs 4.1; Java 21 vs 25; Maven vs Gradle; Spring MVC vs WebFlux; Stripe SDK vs own HTTP adapter.

## Decision
- **Java 21** release target (`--release 21`): the common LTS baseline in enterprise environments. A CI job runs the
  build on **JDK 25** to prove forward compatibility, so moving to 25 is a toolchain change, not a project.
- **Spring Boot 4.1**: the 3.x line is out of OSS support; 4.x brings JSpecify null-safety, built-in resilience
  annotations, HTTP service clients and Testcontainers 2 integration.
- **Maven** with the wrapper: the enterprise default, simple and reproducible.
- **Spring MVC** (servlet) with virtual threads: JPA is blocking; reactive code would add complexity without benefit here.
- **PostgreSQL + Flyway + JPA/Hibernate**; tests use real PostgreSQL via Testcontainers (no H2).
- **Own Stripe adapter on `RestClient`** instead of the Stripe SDK, deliberately: it models integration with providers
  that have no SDK (timeouts, retries with provider idempotency keys, error mapping, contract tests with WireMock).
  For Stripe alone, the official SDK would be the pragmatic production choice.
- **Resilience4j** for circuit breaker/retry/time limiter; **Spring Security** OAuth2 resource server (JWT).
- Quality gates: Spotless (palantir-java-format), Error Prone + NullAway (JSpecify), ArchUnit, JaCoCo (80% lines),
  SpotBugs + FindSecBugs, CodeQL, gitleaks, Dependabot.

## Consequences
- Some third-party libraries may lag behind Boot 4; incompatibilities are recorded in new ADRs with the chosen fallback.
- Error Prone on JDK 21 needs compiler exports in `.mvn/jvm.config`.
