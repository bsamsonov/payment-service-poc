#!/usr/bin/env bash
# Russian reading version of the review guide for the owner (not posted to the PR):
#   guide-context.md — code excerpt and GitHub link for every attention and must_review item (no model)
#   guide.ru.md      — written by the review-guide-ru subagent (sonnet) from guide.json and guide-context.md
#
# Usage: scripts/review/guide-ru.sh <round-dir> [--context-only]
#   --context-only  build guide-context.md and stop (no model call)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require claude jq timeout

round_dir="${1:?usage: guide-ru.sh <round-dir> [--context-only]}"
context_only=false
[[ "${2:-}" == "--context-only" ]] && context_only=true
round_dir="$(cd "$round_dir" && pwd)"
round_rel="${round_dir#"$REPO_ROOT"/}"
guide="$round_dir/guide.json"
[[ -f "$guide" ]] || die "no guide.json in $round_rel; run guide.sh first"
pr="$(jq -r .pr "$round_dir/meta.json")"
round="$(jq -r .round "$round_dir/meta.json")"
head_sha="$(jq -r .head_sha "$round_dir/meta.json")"

# https://github.com/<owner>/<repo> from the origin remote (https or ssh form); empty when it is not GitHub.
repo_url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
  | sed -E 's#^git@github\.com:#https://github.com/#; s#\.git$##' | grep '^https://github\.com/' || true)"

# Numbered lines [from, to] of a file at the reviewed head: the bundle copy if present, else git.
file_at_head() {
  local path="$1"
  if [[ -f "$round_dir/bundle/files/$path" ]]; then cat "$round_dir/bundle/files/$path"
  else git -C "$REPO_ROOT" show "$head_sha:$path" 2>/dev/null; fi
}

{
  echo "# Code excerpts — PR #$pr, round $round, commit ${head_sha:0:7}"
  echo
  jq -r '(.attention | to_entries[] | "attention \(.key + 1)\t\(.value.path)\t\(.value.line)\t\(.value.title)"),
         (.must_review | to_entries[] | "must_review \(.key + 1)\t\(.value.path)\t\(.value.line)\t\(.value.risk)")' \
    "$guide" | while IFS=$'\t' read -r label path line title; do
      from=$(( line > 4 ? line - 4 : 1 )) to=$(( line + 10 ))
      echo "## $label — \`$path:$line\`"
      echo
      echo "$title"
      echo
      if [[ -n "$repo_url" ]]; then
        echo "Link: $repo_url/blob/$head_sha/$path#L$from-L$to"
      fi
      echo
      if content="$(file_at_head "$path")" && [[ -n "$content" ]]; then
        echo '```'
        awk -v a="$from" -v b="$to" 'NR >= a && NR <= b { printf "%4d  %s\n", NR, $0 }' <<<"$content"
        echo '```'
      else
        echo "(file not available at ${head_sha:0:7})"
      fi
      echo
    done
} >"$round_dir/guide-context.md"
log "code excerpts: $round_rel/guide-context.md"
[[ "$context_only" == true ]] && exit 0

agg_line=""
[[ -f "$round_dir/aggregate.json" ]] && agg_line="
Confirmed AI findings: \`$round_rel/aggregate.json\`"
log "writing the Russian reading version (sonnet)"
(cd "$REPO_ROOT" && timeout "${PR_REVIEW_TIMEOUT:-1200}" claude \
  -p "Write the Russian reading version of the review guide of PR #$pr, round $round.
Guide: \`$round_rel/guide.json\`
Code excerpts and links: \`$round_rel/guide-context.md\`
Bundle (only if an excerpt is not enough): \`$round_rel/bundle/\`$agg_line" \
  --agent review-guide-ru \
  --output-format json \
  --permission-mode dontAsk \
  --strict-mcp-config \
  --disable-slash-commands \
  --no-session-persistence \
  --settings '{"disableAllHooks": true}') >"$round_dir/logs/guide-ru.json" 2>"$round_dir/logs/guide-ru.err" \
  || die "review-guide-ru failed, see $round_rel/logs/guide-ru.err"
jq -e '.is_error == false and (.result | length) > 0' "$round_dir/logs/guide-ru.json" >/dev/null \
  || die "review-guide-ru reported an error, see $round_rel/logs/guide-ru.json"
# The document only: drop anything before the first heading (models sometimes add a preface).
jq -r .result "$round_dir/logs/guide-ru.json" | awk 'found || /^# / { found = 1; print }' >"$round_dir/guide.ru.md"
[[ -s "$round_dir/guide.ru.md" ]] || jq -r .result "$round_dir/logs/guide-ru.json" >"$round_dir/guide.ru.md"
log "Russian guide: $round_rel/guide.ru.md (cost \$$(jq -r '.total_cost_usd // "?"' "$round_dir/logs/guide-ru.json"))"
