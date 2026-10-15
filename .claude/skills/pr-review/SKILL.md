---
name: pr-review
description: Multi-model AI review of a pull request — checklist reviewer, several bug-hunting models, specialist lanes (database, API contract, module boundaries, weakened checks) switched on by the diff, verified aggregation, inline PR comments, then the review guide for the human (/review-guide). Use when the user says "/pr-review <PR>", "review PR N", "run the AI review", "second review round", "re-review after fixes".
argument-hint: "<pr> [--delta] [--allow-degraded] [--no-guide] [--no-publish] [--lanes=<list> | --no-lanes]"
---

# /pr-review

Runs `scripts/review/pr-review.sh`, which does all the work outside this session's context:

1. `bundle.sh` — `.review/<pr>/<round>/bundle/`: diff, full changed files, spec, `docs/review-checklist.md`,
   `docs/review-context.md` (from the PR head), `signals.md` (facts from the diff), `docs/review-attention.md` and
   `docs/product.md` (from the PR head, else the base branch). `lanes.py` decides which specialist lanes the diff
   of the round switches on (`lanes.json` with the reasons) and writes their facts without a model:
   | Lane | Switched on by | Facts |
   |---|---|---|
   | `db` | `src/main/resources/db/**` | changed migrations, edits of migrations from the base branch, `squawk` |
   | `api` | `api/**`, `adapter/in/web/**` | `oasdiff breaking` (docker), `redocly lint`, full contract at the head |
   | `boundaries` | new package, `package-info.java`, new dependency between components, ports, events | components, new/removed dependencies, cross-module edges, cycles |
   | `guards` | architecture rules, analyzer config, `pom.xml`, CI, hooks, `AGENTS.md`, review docs, suppressions | changed guard paths, suppressions and skips, removed rule lines, thresholds |
   In `--delta` a lane runs only when the new commits touch it again. Lane checklists: `scripts/review/lanes/<lane>.md`.
2. `run-reviewers.sh` — in parallel: L1 `review-checklist` (sonnet); L2 `review-bugs` (opus), OpenCode
   `deepseek-v4-pro` and `glm-5.3` (on a bundle copy outside the repo), built-in `/code-review` (headless);
   L3 `review-lane` (opus), one run per lane that is on. Lane findings are `drift` (breaks a recorded decision) or
   `needs-decision` (a structural choice no document settles; the aggregator rejects it as a defect and the guide
   turns it into an Architect's attention item).
   Quorum: L1, at least one L2 reviewer and every lane that is on must succeed, otherwise exit code 3.
3. `aggregate.sh` — `review-aggregator` (opus) verifies every finding against the code → `aggregate.json`,
   `report.md`, `stats.tsv`.
4. `guide.sh` — `review-guide` (opus) writes the guide for the human from the same round, the raw reports and
   `aggregate.json` → `guide.json`, `guide.md` (**Architect's attention** — up to 7 hard-to-reverse decisions, then
   places to read line by line, out-of-scope changes, findings, what to skim), plus two Russian documents for the
   owner that are not posted: `guide.ru.md` (reading version) and `walkthrough.ru.md` (code walkthrough). Same as `/review-guide`; skipped with `--no-guide`; a failure here does
   not stop publication of the findings.
5. `publish.sh` — one PR review (event COMMENT) with inline comments + one comment with the guide.

## Steps

1. Parse arguments: PR number (required; if missing, use the PR of the current branch:
   `gh pr view --json number -q .number`), flags `--delta`, `--allow-degraded`, `--no-publish`.
   If this PR already has a round in `.review/<pr>/` and the user did not say otherwise, use `--delta`.
2. Run the pipeline **in the background** (it takes 5–20 minutes) and wait for the notification:
   `scripts/review/pr-review.sh <pr> [flags]` with `run_in_background: true`. Run it from a checkout of `main`
   (prompts and scripts come from the working tree; the script warns when they differ from `origin/main`).
   Do not read raw reports while it runs; do not run reviewers yourself.
3. On exit code 3 (no quorum): show the failed reviewers and the last lines of their `logs/<id>.err`; ask the user
   whether to fix the cause or re-run with `--allow-degraded`. Do not continue on your own.
4. On success: read only `guide.md` and the last block of the script output. Report to the user in at most
   10 lines: number of findings by severity, the top three Architect's attention items, the top places to read,
   links to the posted review and guide, the full paths of `guide.ru.md` and `walkthrough.ru.md`, failed reviewers if any. If the guide failed, say so and offer
   `/review-guide <pr>`.
5. Closing findings is the user's decision. When asked to fix a finding: fix it in a separate commit
   (`fix(<scope>): …`) and reply in the thread. When the user decides it is not a bug: reply with the reason.
   Then the next round is `/pr-review <pr> --delta`.

## Notes

- Requires `gh` (authenticated), `claude`, `jq`; OpenCode reviewers need `opencode` with the `opencode-go` provider.
  A missing OpenCode only degrades L2, it does not stop the run.
- Subset of reviewers: `PR_REVIEW_REVIEWERS="checklist bugs-opus"` (lanes are `lane-<id>`); per-reviewer timeout:
  `PR_REVIEW_TIMEOUT`. Lanes: `--lanes=db,api` forces a set, `--no-lanes` switches them off (both recorded in
  `lanes.json`); `PR_REVIEW_LANE_TOOLS=0` skips squawk/oasdiff/redocly (offline). The tools need `npx` and network,
  `oasdiff` needs docker; a tool that does not run is noted in `facts.md` and the lane still runs.
- Everything in `.review/` is local and git-ignored. `stats.tsv` (reviewer, raw findings, confirmed) feeds the
  review statistics.
- Cost: reviewers and the aggregator as before, plus one opus call per lane that is on, plus one opus call for the guide (about $1–1.5 on a PR of PR #13's
  size).
- Ratchet: when a confirmed finding could be caught by a tool, propose an automated check; otherwise propose a new
  `RC-NN` rule in `docs/review-checklist.md`. Feedback on the guide (useful, noise, missed) goes to "Lessons from past
  PRs" in `docs/review-attention.md`, see `/review-guide`, step 5.
