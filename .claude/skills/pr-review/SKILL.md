---
name: pr-review
description: Multi-model AI review of a pull request — checklist reviewer, several bug-hunting models, specialist lanes (database, API contract, module boundaries, weakened checks) switched on by the diff, verified aggregation, automatic fix of the confirmed findings (one commit each, then one delta round), inline PR comments, then the review guide for the human (/review-guide). Use when the user says "/pr-review <PR>", "review PR N", "run the AI review", "second review round", "re-review after fixes".
argument-hint: "<pr> [--delta] [--allow-degraded] [--no-guide] [--no-publish] [--lanes=<list> | --no-lanes] [--skip=<ids>] [--only=<ids>] [--no-fix]"
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
   Which reviewers are on: `scripts/review/reviewers.conf` (id, level, on/off), overridden by the user's
   `.review/reviewers.local` (`<id> on|off`, not committed) and by `--skip=<ids>` for one run; a reviewer that is
   off is recorded as `skipped` (`disabled`). Quorum: L1, at least one L2 reviewer and every lane switched on by the
   diff must succeed, counting only reviewers that are on; otherwise exit code 3.
3. `aggregate.sh` — `review-aggregator` (opus) verifies every finding against the code → `aggregate.json`,
   `report.md` (with the lanes and why they were switched on), `stats.tsv`.
4. `guide.sh` — `review-guide` (opus) writes the guide for the human from the same round, the raw reports and
   `aggregate.json` → `guide.json`, `guide.md` (**Architect's attention** — up to 7 hard-to-reverse decisions, each
   with the ids of findings that belong to it, then places to read line by line, out-of-scope changes, findings,
   what to skim), plus two Russian documents for the owner that are not posted: `guide.ru.md` (reading version) and
   `walkthrough.ru.md` (code walkthrough). Same as `/review-guide`; skipped with `--no-guide`; a failure here does
   not stop the auto-fix or publication of the findings. Runs before the auto-fix, so that the fixer leaves the
   findings of an attention item to the owner.
5. `fix.sh` — auto-fix: for every confirmed finding (most severe first) the `review-fixer` prompt (opus, effort
   medium) fixes it in a worktree of the PR branch at the reviewed commit, or declines. A finding listed by an
   attention item of `guide.json`, or on its file within 5 lines (`PR_REVIEW_FIX_NEAR`), goes to the owner without
   a fixer run. The fix is kept only if `lanes.py --protected` passes (no guards, spec, ADRs, API contract,
   migrations, ports, `package-info`, port implementations or their wiring in `config`, main code of more than one
   module, no suppressions; existing tests only get lines added, no assumptions or
   conditional execution), the commit hooks accept it and the fast check is green; per finding one commit
   `fix(<scope>): … (auto-fix R<n>-F<k>)` with the code and, if tests changed, one `test(<scope>): cover the
   auto-fix of R<n>-F<k>`, both with an `Auto-fix: R<n>-F<k>` trailer; then a fast-forward push → `fixes.json` (`fixed` with `sha`/`test_sha` / `not_fixed` / `owner`).
   Runs only with publication; skipped when the PR head moved or the PR comes from a fork; off with `--no-fix` or
   `fixer off`.
6. `publish.sh` — one PR review (event COMMENT) with inline comments + one comment with the guide; each comment
   says "Auto-fixed in `<sha>`" (and the test commit) or why it was not fixed. Threads stay open: the owner checks and resolves them.
7. If fixes were pushed: one more round `pr-review.sh <pr> --delta --no-fix` over the fix commits (confirms the
   fixes, catches regressions; never fixes again, so it cannot loop).

## Steps

1. Parse arguments: PR number (required; if missing, use the PR of the current branch:
   `gh pr view --json number -q .number`), flags `--delta`, `--allow-degraded`, `--no-publish`, `--skip=<ids>`,
   `--only=<ids>`, `--no-fix`. "Without glm" → `--skip=glm`; "switch glm off for good" → add `glm off` to `.review/reviewers.local`.
   If this PR already has a round in `.review/<pr>/` and the user did not say otherwise, use `--delta`.
2. Run the pipeline **in the background** (5–20 minutes; with fixes and the delta round over them up to about 40) and wait for the notification:
   `scripts/review/pr-review.sh <pr> [flags]` with `run_in_background: true`. Run it from a checkout of `main`
   (prompts and scripts come from the working tree; the script warns when they differ from `origin/main`).
   Do not read raw reports while it runs; do not run reviewers yourself.
3. On exit code 3 (no quorum): show the failed reviewers and the last lines of their `logs/<id>.err`; ask the user
   whether to fix the cause or re-run with `--allow-degraded`. Do not continue on your own.
4. On success: read only `guide.md` and the last block of the script output. When fixes were pushed, the output
   holds two rounds: the first (findings, `fixes:` line) and the delta round over the fixes — report both, the
   guide of the delta round is the current one. Report to the user in at most
   10 lines: number of findings by severity, the top three Architect's attention items, the top places to read,
   links to the posted review and guide, the full paths of `guide.ru.md` and `walkthrough.ru.md`, failed reviewers if any. If the guide failed, say so and offer
   `/review-guide <pr>`.
5. Confirmed findings are fixed by the pipeline (`fix.sh` above); report how many were fixed and which are left
   (`fixes.json`, reasons). The user resolves every thread, also the auto-fixed ones. For a finding left to the
   user: when asked to fix it, fix it in a separate commit (`fix(<scope>): …`) and reply in the thread; when the
   user decides it is not a bug, reply with the reason. Then the next round is `/pr-review <pr> --delta`.
   Remind the user to pull the PR branch: the fix commits were pushed by the pipeline.

## Questions about a round

After a run the user often asks follow-up questions in the same session. Answer from the files of the round,
`.review/<pr>/<round>/` (the last round: highest number), not from memory; read only the file that answers:

| Question | File |
|---|---|
| Which lanes ran and why (which changed paths switched them on) | `lanes.json` (`setting`, `lanes[].reasons`); summary in `report.md` |
| What the lane was given | `bundle/lanes/<lane>/facts.md` (tool output), `bundle/lanes/<lane>/checklist.md` |
| Who ran, failed, was skipped or switched off; quorum | `quorum.json`; reasons in `logs/<id>.err`; `logs/<id>.status` = `<status> <seconds> <exit>` |
| What a reviewer found (before verification) | `raw/<id>.md` (lanes: `kind` drift or needs-decision, `rule`) |
| What was confirmed, what rejected and why | `report.md`; structured: `aggregate.json` (`findings`, `rejected[].reason`, `previous`) |
| Which `needs-decision` became Architect's attention | `aggregate.json` `rejected` with "design decision" → `guide.md` / `guide.json` `attention` |
| Time, cost, found/confirmed per reviewer | `stats.tsv` (header row; columns below); raw usage: `logs/<id>.json` |
| What the auto-fix did: fixed (commit), not fixed, left to the owner, and why; push result | `fixes.json`; fixer logs `logs/fixer-<F>.{json,err,verify.log,commit.log}` |
| What is still open after the round | `open-findings.json` |
| What the reviewers saw | `bundle/manifest.md`, `meta.json` (`base_ref`, `diff_from`, `head_sha`, `mode`) |

`stats.tsv` columns: `pr round reviewer found confirmed level status seconds cost_usd rejected decisions drift
needs_decision confirmed_ids`; `status` is `ok`, `failed` or `skipped` (`skipped:disabled` — switched off);
`decisions` — findings rejected as design decisions (they go to the owner); `drift` / `needs_decision` — kinds of
findings in a lane's raw report; the `aggregator` row sums the round; the `fixer` row: found = findings tried, confirmed = fixed, rejected = not
fixed, decisions = left to the owner. OpenCode reviewers report no cost.

## Notes

- Requires `gh` (authenticated), `claude`, `jq`; OpenCode reviewers need `opencode` with the `opencode-go` provider.
  A missing OpenCode only degrades L2, it does not stop the run.
- Reviewers: `--only=checklist,bugs-opus` runs just these (lanes are `lane-<id>`) and keeps the other results of the
  round (re-running a failed reviewer); `--skip=glm` switches reviewers off for one run; per-reviewer timeout:
  `PR_REVIEW_TIMEOUT`. Lanes: `--lanes=db,api` forces a set, `--no-lanes` switches them off (both recorded in
  `lanes.json`); `PR_REVIEW_LANE_TOOLS=0` skips squawk/oasdiff/redocly (offline). The tools need `npx` and network,
  `oasdiff` needs docker; a tool that does not run is noted in `facts.md` and the lane still runs.
- Everything in `.review/` is local and git-ignored. `stats.tsv` feeds the review statistics.
- Cost: reviewers and the aggregator as before, plus one opus call per lane that is on, plus one opus call for the guide (about $1–1.5 on a PR of PR #13's
  size).
- Ratchet: when a confirmed finding could be caught by a tool, propose an automated check; otherwise propose a new
  `RC-NN` rule in `docs/review-checklist.md`. Feedback on the guide (useful, noise, missed) goes to "Lessons from past
  PRs" in `docs/review-attention.md`, see `/review-guide`, step 5.
