# 0005. Amending ADRs

- Status: Accepted
- Date: 2026-10-06
- Amends: [0001](0001-record-architecture-decisions.md) — adds partial changes (amendments)

## Context and problem
ADR-0001 knows only one relation between decisions: a changed decision gets a new ADR that supersedes the old one.
Some ADRs bundle several decisions (ADR-0002 covers the whole technology stack), and later changes often touch only
one of them, e.g. the Java version. Marking the whole ADR as superseded is wrong — most of it stays in force — and
packing every partial change into its status line does not scale.

## Considered options
1. Supersede only: a new ADR replaces the old one entirely, even for a one-line change.
2. Free-form status notes on the old ADR.
3. Two explicit relations, as in adr-tools: **Supersedes / Superseded by** and **Amends / Amended by**.

## Decision
Option 3.

- **Supersedes** — the new ADR replaces the old decision entirely. The old ADR gets
  `Status: Superseded by [NNNN](…)`.
- **Amends** — the new ADR changes or extends part of the old decision; the rest stays in force. The new ADR has
  `- Amends: [NNNN](…) — <what>`; the old ADR keeps its status and gets one line per amendment:
  `- Amended by: [NNNN](…) — <what changed, 3–6 words>`.
- These header lines are the only edits allowed in an accepted ADR; its body is never rewritten.
- When an ADR collects many amendments or its core decision changes, a consolidated ADR supersedes it.
- One decision per ADR where practical, so most changes are plain supersedes.

## Consequences
- An accepted ADR shows at a glance what still holds and where to read about changes.
- The template (`0000-template.md`) gets optional `Amends` / `Amended by` lines.
