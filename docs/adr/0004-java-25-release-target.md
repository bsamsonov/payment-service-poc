# 0004. Java 25 release target

- Status: Accepted
- Date: 2026-10-06
- Supersedes: the Java version decision of [0002](0002-technology-stack.md) (the rest of 0002 stays in force)

## Context and problem
ADR-0002 chose Java 21 as the release target, as the common enterprise LTS baseline, and added a CI job building on
JDK 25 to keep the move to 25 a toolchain change. Java 25 has been an LTS release since September 2025, Spring Boot 4.1
and every tool in our quality gates (Error Prone/NullAway, SpotBugs, JaCoCo, Spotless) run on it, and the JDK 25
compatibility job is green on `main`. The project is a greenfield service with no consumers
pinned to an older runtime.

## Considered options
1. Keep `--release 21`, build on JDK 25 (toolchain-only change).
2. Move the release target to Java 25 (`--release 25`).

## Decision
Option 2: **Java 25** release target, built and tested in CI on Temurin 25.

- The code may use Java 22–25 features (e.g. unnamed variables `_`, flexible constructor bodies, module imports,
  `Stream.gather`, scoped values) where they make the code clearer.
- The CI build job gets a version-neutral name (`Build and test`), so the next JDK upgrade does not require changing
  the required status checks of the `main` ruleset again.
- The separate JDK 25 compatibility job is removed: it becomes the main build. A forward-compatibility job for the next
  JDK can be added when one is relevant.

## Consequences
- Positive: newer language and library features, a longer support window (Java 25 vs 21), one CI build instead of two.
- Negative: artifacts no longer run on JDK 21–24; environments that only offer Java 21 cannot run the service.
- Error Prone on JDK 25 still needs the compiler exports in `.mvn/jvm.config`.
