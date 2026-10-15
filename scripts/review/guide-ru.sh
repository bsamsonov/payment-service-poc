#!/usr/bin/env bash
# Russian documents for the owner (not posted to the PR):
#   guide-context.md   — code excerpt and GitHub link per attention and must_review item, table of changed files (no model)
#   guide.ru.md        — reading version of the guide (review-guide-ru, opus) from guide.json and guide-context.md
#   walkthrough.ru.md  — code walkthrough: the most significant or unexpected places with snippets
#                        (review-walkthrough-ru, opus); runs in parallel with guide.ru.md
#
# Usage: scripts/review/guide-ru.sh <round-dir> [--context-only] [--no-walkthrough]
#   --context-only    build guide-context.md and stop (no model call)
#   --no-walkthrough  skip walkthrough.ru.md
# Env: PR_REVIEW_GUIDE_RU_MODEL — model override for both agents (default: the agents' model, opus)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require claude jq timeout

round_dir="${1:?usage: guide-ru.sh <round-dir> [--context-only] [--no-walkthrough]}"
shift
context_only=false walkthrough=true
for arg in "$@"; do
  case "$arg" in
    --context-only)   context_only=true ;;
    --no-walkthrough) walkthrough=false ;;
    *)                die "unknown option: $arg" ;;
  esac
done
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

  # Every file of this round's diff, for the "what the PR consists of" section. Line counts with and without
  # whitespace changes show re-indented files; they need the commits, otherwise the patch is counted.
  diff_from="$(jq -r .diff_from "$round_dir/meta.json")"
  echo "## Changed files in this round (${diff_from:0:7}..${head_sha:0:7})"
  echo
  echo "| Status | Path | +/− | +/− ignoring whitespace | Link |"
  echo "|---|---|---|---|---|"
  if git -C "$REPO_ROOT" cat-file -e "$diff_from^{commit}" 2>/dev/null \
     && git -C "$REPO_ROOT" cat-file -e "$head_sha^{commit}" 2>/dev/null; then
    G=(git -C "$REPO_ROOT" diff --no-renames)
    awk -F'\t' -v url="$repo_url" -v head="$head_sha" -v from="$diff_from" '
      FILENAME == ARGV[1] { st[$2] = $1; order[++n] = $2; next }
      FILENAME == ARGV[2] { all[$3] = "+" $1 "/−" $2; next }
                          { ws[$3] = "+" $1 "/−" $2 }
      END {
        for (i = 1; i <= n; i++) {
          p = order[i]; sha = (st[p] == "D") ? from : head
          link = (url == "") ? "" : url "/blob/" sha "/" p
          printf "| %s | `%s` | %s | %s | %s |\n", st[p], p, all[p], (p in ws) ? ws[p] : "+0/−0", link
        }
      }' <("${G[@]}" --name-status "$diff_from" "$head_sha") \
         <("${G[@]}" --numstat "$diff_from" "$head_sha") \
         <("${G[@]}" --numstat -w "$diff_from" "$head_sha")
  else
    awk -v url="$repo_url" -v head="$head_sha" '
      function flush() { if (p != "") printf "| %s | `%s` | +%d/−%d | n/a | %s |\n", s, p, a, d, (url == "" || s == "D") ? "" : url "/blob/" head "/" p }
      /^diff --git / { flush(); p = ""; s = "M"; a = 0; d = 0; hunk = 0; next }
      /^new file mode/ && !hunk { s = "A"; next }
      /^deleted file mode/ && !hunk { s = "D"; next }
      /^--- / && !hunk { if ($0 != "--- /dev/null") p = substr($0, 7); next }
      /^\+\+\+ / && !hunk { if ($0 != "+++ /dev/null") p = substr($0, 7); next }
      /^@@ / { hunk = 1; next }
      hunk && /^\+/ { a++; next }
      hunk && /^-/ { d++; next }
      END { flush() }' "$round_dir/bundle/diff.patch"
  fi
} >"$round_dir/guide-context.md"
log "code excerpts: $round_rel/guide-context.md"
[[ "$context_only" == true ]] && exit 0

agg_line=""
[[ -f "$round_dir/aggregate.json" ]] && agg_line="
Confirmed AI findings: \`$round_rel/aggregate.json\`"
model=()
[[ -n "${PR_REVIEW_GUIDE_RU_MODEL:-}" ]] && model=(--model "$PR_REVIEW_GUIDE_RU_MODEL")

# run_agent <agent> <log name> <output file> <prompt>: one headless call; the Markdown document goes to the output.
run_agent() {
  local agent="$1" name="$2" out="$3" prompt="$4"
  (cd "$REPO_ROOT" && timeout "${PR_REVIEW_TIMEOUT:-1200}" claude -p "$prompt" \
    --agent "$agent" "${model[@]}" \
    --output-format json \
    --permission-mode dontAsk \
    --strict-mcp-config \
    --disable-slash-commands \
    --no-session-persistence \
    --settings '{"disableAllHooks": true}') >"$round_dir/logs/$name.json" 2>"$round_dir/logs/$name.err" \
    || { log "$agent failed, see $round_rel/logs/$name.err"; return 1; }
  jq -e '.is_error == false and (.result | length) > 0' "$round_dir/logs/$name.json" >/dev/null \
    || { log "$agent reported an error, see $round_rel/logs/$name.json"; return 1; }
  # The document only: drop anything before the first heading (models sometimes add a preface).
  jq -r .result "$round_dir/logs/$name.json" | awk 'found || /^# / { found = 1; print }' >"$out"
  [[ -s "$out" ]] || jq -r .result "$round_dir/logs/$name.json" >"$out"
  log "${out#"$REPO_ROOT"/} (cost \$$(jq -r '.total_cost_usd // "?"' "$round_dir/logs/$name.json"))"
}

log "writing the Russian documents (${PR_REVIEW_GUIDE_RU_MODEL:-opus})"
run_agent review-guide-ru guide-ru "$round_dir/guide.ru.md" \
  "Write the Russian reading version of the review guide of PR #$pr, round $round.
Guide: \`$round_rel/guide.json\`
Code excerpts and links: \`$round_rel/guide-context.md\`
Bundle (only if an excerpt is not enough): \`$round_rel/bundle/\`$agg_line" &
guide_pid=$!
walk_pid=""
if [[ "$walkthrough" == true ]]; then
  run_agent review-walkthrough-ru walkthrough-ru "$round_dir/walkthrough.ru.md" \
    "Write the Russian code walkthrough of PR #$pr, round $round.
Guide: \`$round_rel/guide.json\`
Changed files and links: \`$round_rel/guide-context.md\`
Diff of this round: \`$round_rel/bundle/diff.patch\`; full post-change files: \`$round_rel/bundle/files/\`;
spec: \`$round_rel/bundle/spec/\`
Link base for snippets: ${repo_url:+$repo_url/blob/$head_sha}" &
  walk_pid=$!
fi
status=0
wait "$guide_pid" || status=1
[[ -z "$walk_pid" ]] || wait "$walk_pid" || log "WARNING: walkthrough.ru.md was not written"
exit "$status"
