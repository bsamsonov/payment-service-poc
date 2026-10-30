---
name: review-guide
description: Review guide for the human reviewer of a pull request — the few decisions to judge personally (Architect's attention), places to read line by line, out-of-scope changes, what can be skimmed. Works without the AI review and uses its results when a round exists. Use when the user says "/review-guide <PR>", "what should I look at in PR N", "prepare me for the review", "на что смотреть в PR", "подсказки для ручного ревью". Also runs as part of /pr-review.
argument-hint: "<pr> [--no-publish] [--reuse] [--no-ru]"
---

# /review-guide

Runs `scripts/review/write-review-guide.sh`, which calls the `review-guide` agent (opus, read-only) outside this session's context.

- If `.review/<pr>/` has a round for the current PR head (for example from `/pr-review`), the agent reads its bundle,
  the reviewers' raw reports and `aggregate.json` (confirmed findings and rejections with reasons).
- Otherwise `build-review-bundle.sh` builds a new round with the full PR diff and no AI review.
- In both cases the agent also reads the repository around the change: callers, existing conventions, ADRs.

Output in the round directory: `guide.json` and `guide.md` (What changed, Architect's attention, Read line by line,
Outside the declared scope, Findings if there was an AI review, Can be skimmed, sensitive paths checked), posted to
the PR in English. Then `guide-ru.sh` writes `guide.ru.md` for the owner, not posted: a short Russian reading version
in which every decision is explained in plain words with the relevant code lines and a GitHub link, so that it can be
decided without opening the code, plus a section that groups the changed files by purpose (`review-guide-ru`, opus,
about $0.3–0.5). In parallel `walkthrough.ru.md`: a code walkthrough of the 5–8 most significant or unexpected places,
each with a snippet, a GitHub link and a plain explanation, as a developer would show the change to an architect
(`review-walkthrough-ru`, opus, about $0.6). `guide-context.md` holds the excerpts and the file table.

## Steps

1. Parse arguments: PR number (if missing: `gh pr view --json number -q .number`), `--no-publish`, `--reuse`
   (re-render from the saved agent output without a new model call), `--no-ru` (skip the Russian version). Tell the
   user that one run costs about $1–1.5 (one opus call) plus about $1 for the two Russian documents, unless `--reuse`.
2. Run in the background (3–6 minutes) and wait for the notification:
   `scripts/review/write-review-guide.sh <pr> [--reuse] [--no-ru]` with `run_in_background: true`. The last line of stdout is the round
   directory.
3. Unless `--no-publish`: `scripts/review/publish-to-pr.sh <round-dir> --guide-only` posts `guide.md` as a PR comment
   (idempotent: not posted twice for the same round).
4. Read only `guide.md`. Report to the user in their language, in at most 10 lines: the top three attention items
   (title, question, `decide_by`), the places to read line by line, out-of-scope changes, the link to the comment,
   and the full paths of `guide.ru.md` and `walkthrough.ru.md` if they were written.
5. After the user has done the review, ask one question: which items were useful, which were noise, what did the
   guide miss. Propose one line per answer for "Lessons from past PRs" in `docs/review-attention.md`, in the format
   given there. Commit it only when the user agrees, on the branch the user names (usually a separate docs PR).

## Notes

- Run it from a checkout of `main` (a worktree is fine): prompts and scripts come from the working tree, while the
  heuristics (`docs/review-attention.md`) and the roadmap (`docs/product.md`) come from the PR head, falling back to
  the base branch. `write-review-guide.sh` warns when the local review tooling differs from `origin/main`.
- The agent writes in English because the guide is posted to the PR.
