# 0001. Record architecture decisions

- Status: Accepted
- Date: 2026-10-02
- Amended by: [0005](0005-amending-adrs.md) — partial changes via amendments

## Context and problem
Decisions made during development (often with AI assistance) are easily lost in chat history. Reviewers and future
contributors — human or AI — need to know why the system looks the way it does.

## Decision
Significant decisions are recorded as ADRs in `docs/adr/` using a lightweight MADR format (`0000-template.md`).
An accepted ADR is never rewritten; a changed decision gets a new ADR that supersedes the old one.
Feature-level detail stays in `specs/`; ADRs capture decisions that outlive a single feature.

## Consequences
- Decisions are reviewed in pull requests like code (`docs/adr/` has a CODEOWNERS entry).
- Agents get durable context from the repository instead of conversation history.
