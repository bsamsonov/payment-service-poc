# Lane `guards` — the checks themselves

The build, the hooks, the AI review and the agent rules are what keep the code honest. A PR written by a coding agent
may weaken them to get green. Facts: `facts.md` (changed guard paths, suppressions and skips in added lines, removed
lines of architecture rule files, threshold changes). Rules: `AGENTS.md` ("Never use `--no-verify`, never disable
checks, never lower coverage thresholds or add analyzer suppressions to make a build pass. Suppressions require a
written justification."), `context.md` (what CI enforces), `checklist.md`.

- GRD-1 Suppressions (`@SuppressWarnings`, `@SuppressFBWarnings`, `NOPMD`, `NOSONAR`, analyzer excludes, `@Disabled`):
  each one has a written justification next to it and is the narrowest possible (one line or member, one rule).
  A suppression that hides a real defect is a `drift` finding.
- GRD-2 Architecture rules (ArchUnit, Modulith tests, fixtures): a removed or relaxed rule, a new exception, or an
  `allowEmptyShould(true)` without reason is a finding; a rule changed in the same PR as code that would violate the
  old rule is a strong signal.
- GRD-3 Thresholds and gates (coverage minimum, analyzer severity, `failOnViolation`, NullAway/Error Prone levels,
  required CI checks, `continue-on-error`, `|| true`) never go down to make a build pass.
- GRD-4 Skipped steps: `-DskipTests`, `-DskipITs`, removed CI jobs or hook commands, changed triggers of a workflow.
- GRD-5 Agent and review rules (`AGENTS.md`, `CLAUDE.md`, `.claude/settings.json`, hooks, `docs/review-*.md`): a change
  that lets an agent skip a check, widens permissions, or edits the rules the PR is reviewed by. The PR is reviewed by
  the rules at its head — say so when the PR changes them.
- GRD-6 Build changes (`pom.xml`, `.mvn/`): a new dependency or plugin is listed in the technology stack or comes with
  an ADR; version downgrades and removed enforcer rules are reported.
- GRD-7 A legitimate change of a guard (a rule that was wrong, a threshold the owner decided) is `needs-decision`
  unless the PR description or an ADR records the owner's decision.
