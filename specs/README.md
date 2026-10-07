# Specifications

One folder per feature: `specs/NNN-short-name/` with three short files.

| File | Question | Owner |
|---|---|---|
| `spec.md` | **What** and why: scope, non-goals, acceptance criteria (`AC-n`), errors, NFRs, API/data changes, open questions | human (AI interviews and drafts) |
| `plan.md` | **How**: components, data model and migrations, sequence, transactions/concurrency, test strategy per AC, risks, ADR links | AI drafts in plan mode, human reviews |
| `tasks.md` | **Steps**: ordered, commit-sized tasks, each mapped to ACs | AI |

A spec covers one coherent feature; split features that are not. A spec ships in **one or more pull requests**:
`tasks.md` groups the tasks into PRs (`## PR A — …`), each about 600 changed lines of non-generated code at most
(including tests), green and meaningful on its own. Small PRs keep human and AI review effective.

## Lifecycle
`Draft → Approved → Implemented` (→ `Superseded`). Only the owner sets `Approved`; agents never do.

- **Until the feature's last PR merges, the spec is living.** Edit the body directly; the reason goes in the commit
  message or PR description, not in a changelog section. Open questions are removed once answered.
  A **significant** change to an `Approved` spec — anything that changes observable behavior or a testable
  criterion: an AC, an error, the API, the data model, scope or non-goals — returns it to `Draft` until the owner
  approves it again (a separate commit). Wording fixes and clarifications keep the status.
- **The last commit of the feature's last PR sets `Implemented`.** From then on the body is frozen: it records intent.
  The living truth is `api/openapi.yaml`, acceptance tests, `docs/architecture.md` and the code.
  Allowed edits to a frozen spec: typos and back-links (below).
- **Behavior changes after that go to a new spec**, with `supersedes`/`amends` in its front matter and a section
  *Changes to earlier specs* listing which ACs it replaces. In the same PR the old spec gets back-links:
  `superseded_by` / `amended_by` in its front matter, and `(superseded by NNN/AC-n)` right after the id of each
  replaced AC. A spec replaced as a whole gets `status: Superseded`.

## Acceptance criteria and tests
ACs are numbered from `AC-1` in every spec, so tests qualify them with the spec number:
`@DisplayName("001/AC-2: declined card returns 402")`; one test may cover several: `"001/AC-10, 001/AC-14: …"`.
The id goes in the `@DisplayName` of the test method (or of a `@Nested` class whose tests all cover that AC),
not in the `name` of a `@ParameterizedTest`. Test reports show display names.

`scripts/spec/check-ac-trace.sh` runs in CI:
- error: a test references an unknown or superseded AC, or uses an id without the spec number;
- error: an active AC of an `Implemented` spec has no test;
- warning: an active AC of an `Approved` spec has no test yet;
- `Draft` specs are not checked for coverage.

Commands: `/spec-new`, `/spec-plan`, `/spec-tasks`, `/spec-verify`. Templates: `_template/`.
