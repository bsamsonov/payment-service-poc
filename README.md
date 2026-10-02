# payment-service-poc

> **Proof of concept / learning project — not a production product.**

An internal payment service PoC: internal services call a REST API, the service charges via Stripe (test mode),
stores payments in PostgreSQL and keeps an audit trail. Its main purpose is to demonstrate a production-grade,
AI-assisted development workflow: specifications before code, test-first development, atomic commits, automated
quality gates and multi-layer code review.

**Status:** project bootstrap — build, quality gates, CI and workflow are in place; features follow as specs in `specs/`.

## Stack
Java 21 (release target, CI also checks JDK 25) · Spring Boot 4.1 · Spring MVC · PostgreSQL · Flyway · JPA/Hibernate ·
Resilience4j · Spring Security (JWT) · Testcontainers · WireMock · Maven. Rationale: [ADR-0002](docs/adr/0002-technology-stack.md).

## Getting started
Prerequisites: JDK 21+, Docker (for integration tests), [Lefthook](https://lefthook.dev) and
[gitleaks](https://github.com/gitleaks/gitleaks) for local git hooks.

```bash
lefthook install                              # once per clone
./mvnw verify                                 # full check, as in CI (unit + integration tests, coverage)
./mvnw verify -DskipITs -Djacoco.skip=true    # fast check
./mvnw spring-boot:run                        # run locally; health: http://localhost:8080/actuator/health
```

## How this project is built
| Layer | What runs |
|---|---|
| Specs | `specs/NNN-name/{spec,plan,tasks}.md` — acceptance criteria with ids, mapped to tests |
| Agent rules | [`AGENTS.md`](AGENTS.md) (all agents), [`CLAUDE.md`](CLAUDE.md) (Claude Code) |
| Claude Code hooks | format Java on edit; fast check when a turn ends (failures go back to the agent) |
| Git hooks (Lefthook) | pre-commit: Spotless, gitleaks, Conventional Commits; pre-push: fast verify |
| CI | full verify (Error Prone/NullAway, ArchUnit, JaCoCo 80%, SpotBugs/FindSecBugs), JDK 25 check, CodeQL, gitleaks, dependency review |
| Repository rules | PRs only, required checks, resolved conversations, linear history (rebase merge) |
| Decisions | [`docs/adr/`](docs/adr/) |

Details: [ADR-0003](docs/adr/0003-development-workflow.md).

## License
[MIT](LICENSE)
