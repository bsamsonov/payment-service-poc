---
name: pr-review
description: Multi-model AI review of a pull request — checklist reviewer, several bug-hunting models, verified aggregation, inline PR comments and a review guide for the human. Use when the user says "/pr-review <PR>", "review PR N", "run the AI review", "second review round", "re-review after fixes".
argument-hint: "<pr> [--delta] [--allow-degraded] [--no-publish]"
---

# /pr-review

Runs `scripts/review/pr-review.sh`, which does all the work outside this session's context:

1. `bundle.sh` — `.review/<pr>/<round>/bundle/`: diff, full changed files, spec, `docs/review-checklist.md`,
   `docs/review-context.md`, optional `docs/review-attention.md` (taken from the PR head).
2. `run-reviewers.sh` — in parallel: L1 `review-checklist` (sonnet); L2 `review-bugs` (opus), OpenCode
   `deepseek-v4-pro` and `glm-5.3` (on a bundle copy outside the repo), built-in `/code-review` (headless).
   Quorum: L1 and at least one L2 reviewer must succeed, otherwise exit code 3.
3. `aggregate.sh` — `review-aggregator` (opus) verifies every finding against the code → `aggregate.json`,
   `report.md`, `guide.md` (opens with **Architect's attention** — up to 7 hard-to-reverse decisions, then
   Must review), `stats.tsv`.
4. `publish.sh` — one PR review (event COMMENT) with inline comments + one comment with the guide.

## Steps

1. Parse arguments: PR number (required; if missing, use the PR of the current branch:
   `gh pr view --json number -q .number`), flags `--delta`, `--allow-degraded`, `--no-publish`.
   If this PR already has a round in `.review/<pr>/` and the user did not say otherwise, use `--delta`.
2. Run the pipeline **in the background** (it takes 5–20 minutes) and wait for the notification:
   `scripts/review/pr-review.sh <pr> [flags]` with `run_in_background: true`.
   Do not read raw reports while it runs; do not run reviewers yourself.
3. On exit code 3 (no quorum): show the failed reviewers and the last lines of their `logs/<id>.err`; ask the user
   whether to fix the cause or re-run with `--allow-degraded`. Do not continue on your own.
4. On success: read only `guide.md` and the last block of the script output. Report to the user in at most
   10 lines: number of findings by severity, the top three Architect's attention items, the top must-review items,
   links to the posted review and guide, failed reviewers if any.
5. Closing findings is the user's decision. When asked to fix a finding: fix it in a separate commit
   (`fix(<scope>): …`) and reply in the thread. When the user decides it is not a bug: reply with the reason.
   Then the next round is `/pr-review <pr> --delta`.

## Notes

- Requires `gh` (authenticated), `claude`, `jq`; OpenCode reviewers need `opencode` with the `opencode-go` provider.
  A missing OpenCode only degrades L2, it does not stop the run.
- Subset of reviewers: `PR_REVIEW_REVIEWERS="checklist bugs-opus"`; per-reviewer timeout: `PR_REVIEW_TIMEOUT`.
- Everything in `.review/` is local and git-ignored. `stats.tsv` (reviewer, raw findings, confirmed) feeds the
  review statistics.
- Ratchet: when a confirmed finding could be caught by a tool, propose an automated check; otherwise propose a new
  `RC-NN` rule in `docs/review-checklist.md`. When the human found a decision important that the Architect's
  attention section missed (or flagged noise), add a line to "Lessons from past PRs" in `docs/review-attention.md`.
