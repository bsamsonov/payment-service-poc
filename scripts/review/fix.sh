#!/usr/bin/env bash
# Auto-fix of the findings confirmed by the aggregator: one review-fixer run per finding in a worktree of the PR
# branch, one commit per fixed finding, then a fast-forward push to the PR branch.
#   fixes.json  — per finding: fixed (commit sha) | not_fixed | owner (the fix needs the owner) + reason; push result
#   stats.tsv   — `fixer` row (found = findings tried, confirmed = fixed, rejected = not fixed or rolled back,
#                 decisions = handed to the owner)
#   report.md   — "Auto-fix" section
#
# A fix is kept only if the fixer reports it fixed, the change passes lanes.py --protected (no guards, spec, ADRs,
# API contract or migrations from the base branch; no suppressions, no removed tests), the commit hooks accept it
# and the fast check is green. Otherwise it is rolled back and the finding stays with the owner.
# Review threads are never resolved here: the owner checks the fix commit and resolves the thread.
#
# Usage: scripts/review/fix.sh <round-dir> [--force]
#   --force  run again although fixes.json of the round exists
# Switched off by `fixer off` in reviewers.conf / .review/reviewers.local, PR_REVIEW_SKIP=fixer or PR_REVIEW_FIX=0.
# Env: PR_REVIEW_FIX_MODEL (default opus), PR_REVIEW_FIX_EFFORT (default medium), PR_REVIEW_FIX_PUSH (1 | 0 — keep
#      the commits in the worktree), PR_REVIEW_FIX_VERIFY (default: ./mvnw -q -B verify -DskipITs -Djacoco.skip=true),
#      PR_REVIEW_TIMEOUT (per fixer run, seconds; default 1200)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require claude gh git jq timeout python3

round_dir="${1:?usage: fix.sh <round-dir> [--force]}"
force=false
[[ "${2:-}" == "--force" ]] && force=true
round_dir="$(cd "$round_dir" && pwd)"
round_rel="${round_dir#"$REPO_ROOT"/}"
agg="$round_dir/aggregate.json"
fixes="$round_dir/fixes.json"
[[ -f "$agg" ]] || die "no aggregate.json in $round_rel; run aggregate.sh first"
pr="$(jq -r .pr "$round_dir/meta.json")"
round="$(jq -r .round "$round_dir/meta.json")"
head_sha="$(jq -r .head_sha "$round_dir/meta.json")"
base_ref="$(jq -r '.base_ref // "main"' "$round_dir/meta.json")"
TIMEOUT="${PR_REVIEW_TIMEOUT:-1200}"
VERIFY="${PR_REVIEW_FIX_VERIFY:-./mvnw -q -B verify -DskipITs -Djacoco.skip=true}"
wt="$round_dir/worktree"
mkdir -p "$round_dir/logs"

if [[ -f "$fixes" && "$force" == false ]] && jq -e '.status == "done"' "$fixes" >/dev/null; then
  log "auto-fix already ran for this round ($round_rel/fixes.json); use --force to run again"
  exit 0
fi

# Stats row and report section; both are rewritten, so a re-run does not duplicate them.
write_outputs() {
  local tsv="$round_dir/stats.tsv" report="$round_dir/report.md"
  if [[ -f "$tsv" ]]; then
    grep -v $'^[^\t]*\t[^\t]*\tfixer\t' "$tsv" >"$tsv.tmp" || true
    jq -r --arg pr "$pr" --arg round "$round" '
      [$pr, $round, "fixer", (.items | length), ([.items[] | select(.status == "fixed")] | length), "fix",
       (if .status == "done" then "ok" else "skipped" end), (.seconds // ""), (.cost_usd // ""),
       ([.items[] | select(.status == "not_fixed")] | length), ([.items[] | select(.status == "owner")] | length),
       "", "", ([.items[] | select(.status == "fixed") | .id] | join(","))] | map(tostring) | @tsv
    ' "$fixes" >>"$tsv.tmp"
    mv "$tsv.tmp" "$tsv"
  fi
  if [[ -f "$report" ]]; then
    awk '/^## Auto-fix/ {exit} {print}' "$report" >"$report.tmp"
    jq -r '
      "## Auto-fix\n",
      (if .status != "done" then "Not run: \(.reason)\n"
       else
         "Branch `\(.branch)`: " + (if .pushed then "pushed \(.head_before[:7])..\(.head_after[:7])"
                                    elif ([.items[] | select(.status == "fixed")] | length) == 0 then "nothing to push"
                                    else "**not pushed** (\(.push_error)); commits are in `\(.worktree)`" end) + "\n",
         (.items[] | "- \(.id) — \(.status)\(if .sha != "" then " `\(.sha[:7])`" else "" end): \(.reason)"), ""
       end)
    ' "$fixes" >>"$report.tmp"
    mv "$report.tmp" "$report"
  fi
}

not_run() {
  jq -n --arg reason "$1" '{status: "skipped", reason: $reason, items: []}' >"$fixes"
  write_outputs
  log "auto-fix skipped: $1"
  exit 0
}

[[ "${PR_REVIEW_FIX:-1}" == 0 ]] && not_run "switched off (--no-fix)"
[[ "$(reviewer_config | awk '$1 == "fixer" {print $3}')" == off ]] && not_run "switched off (reviewers.conf, .review/reviewers.local or --skip)"
(( $(jq '.findings | length' "$agg") > 0 )) || not_run "no confirmed findings"

pr_info="$(gh pr view "$pr" --json headRefName,headRefOid,isCrossRepository,state)" || not_run "gh pr view failed"
branch="$(jq -r .headRefName <<<"$pr_info")"
[[ "$(jq -r .state <<<"$pr_info")" == OPEN ]] || not_run "PR is not open"
[[ "$(jq -r .isCrossRepository <<<"$pr_info")" == false ]] || not_run "PR comes from a fork"
[[ "$(jq -r .headRefOid <<<"$pr_info")" == "$head_sha" ]] \
  || not_run "PR head moved to $(jq -r '.headRefOid[:7]' <<<"$pr_info") after the review of ${head_sha:0:7}"

git -C "$REPO_ROOT" fetch -q origin "$branch" "$base_ref" 2>/dev/null || log "WARNING: git fetch failed; using local refs"
main_ref="origin/$base_ref"
git -C "$REPO_ROOT" rev-parse -q --verify "$main_ref" >/dev/null || main_ref="$head_sha"
[[ -d "$wt" ]] && git -C "$REPO_ROOT" worktree remove --force "$wt"
git -C "$REPO_ROOT" worktree add -q --detach "$wt" "$head_sha"

prompt_body="$(agent_body "$REPO_ROOT/.claude/agents/review-fixer.md")"
items='[]' total_secs=0 total_cost=0
add_item() {  # add_item <id> <status> <sha> <reason> <files-json> <seconds> <cost>
  items="$(jq --arg id "$1" --arg s "$2" --arg sha "$3" --arg r "$4" --argjson f "$5" --arg sec "$6" --arg c "$7" \
    '. + [{id: $id, status: $s, sha: $sha, reason: $r, files: $f, seconds: ($sec | tonumber), cost_usd: $c}]' <<<"$items")"
  log "  $1: $2${3:+ ${3:0:7}} — $4"
}
rollback_to() { git -C "$wt" reset -q --hard "$1"; git -C "$wt" clean -qfd; }

# Most severe first: later fixes build on earlier ones.
mapfile -t order < <(jq -c '.findings | sort_by({"blocker": 0, "major": 1, "minor": 2}[.severity] // 3) | .[]' "$agg")
log "auto-fix: ${#order[@]} finding(s) of PR #$pr round $round in $wt"
for finding in "${order[@]}"; do
  fid="$(jq -r .id <<<"$finding")"
  id="R$round-$fid"
  start=$SECONDS before="$(git -C "$wt" rev-parse HEAD)"
  out="$round_dir/logs/fixer-$fid.json"
  rc=0
  (cd "$wt" && timeout "$TIMEOUT" claude \
    -p "Fix finding $id of PR #$pr. Review bundle: \`$round_dir/bundle/\` (start with manifest.md).
Finding:
$(jq '{id, severity, rule, title, path, line, body}' <<<"$finding")" \
    --system-prompt "$prompt_body" \
    --model "${PR_REVIEW_FIX_MODEL:-opus}" \
    --effort "${PR_REVIEW_FIX_EFFORT:-medium}" \
    --output-format json \
    --json-schema "$(cat "$SCRIPTS_DIR/fix.schema.json")" \
    --permission-mode dontAsk \
    --allowedTools "Read,Grep,Glob,Edit,Write,Bash(./mvnw:*)" \
    --disallowedTools "Agent,Skill,NotebookEdit,WebFetch,WebSearch" \
    --add-dir "$round_dir/bundle" \
    --strict-mcp-config \
    --disable-slash-commands \
    --no-session-persistence \
    --settings "$CLAUDE_REVIEW_SETTINGS") >"$out" 2>"$round_dir/logs/fixer-$fid.err" || rc=$?
  cost="$(jq -r '.total_cost_usd // 0' "$out" 2>/dev/null || echo 0)"
  total_cost="$(jq -n --arg a "$total_cost" --arg b "$cost" '(($a | tonumber) + ($b | tonumber)) * 10000 | round / 10000')"
  cost="$(jq -n --arg c "$cost" '$c | tonumber * 10000 | round / 10000')"
  answer="$(jq -c 'if (.structured_output | type) == "object" then .structured_output
                   else .result | sub("^[^{]*"; "") | sub("[^}]*$"; "") | fromjson end' "$out" 2>/dev/null || true)"
  secs=$(( SECONDS - start ))
  if [[ $rc -ne 0 || -z "$answer" ]]; then
    rollback_to "$before"
    add_item "$id" not_fixed "" "fixer run failed (exit $rc, see logs/fixer-$fid.err)" '[]' "$secs" "$cost"; continue
  fi
  status="$(jq -r .status <<<"$answer")" reason="$(jq -r .reason <<<"$answer")"
  files="$(jq -c '.files // []' <<<"$answer")"
  if [[ "$status" != fixed ]]; then
    rollback_to "$before"
    [[ "$reason" == "needs owner"* ]] && s=owner || s=not_fixed
    add_item "$id" "$s" "" "$reason" "$files" "$secs" "$cost"; continue
  fi
  if [[ -z "$(git -C "$wt" status --porcelain)" ]]; then
    add_item "$id" not_fixed "" "fixer reported a fix but changed nothing" "$files" "$secs" "$cost"; continue
  fi
  scope="$(jq -r .scope <<<"$answer" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9._-')"
  prefix="fix${scope:+($scope)}: " suffix=" ($id)"
  summary="$(jq -r .summary <<<"$answer" | tr '\n' ' ' | sed 's/[[:space:]]*$//; s/\.$//')"
  max=$(( 72 - ${#prefix} - ${#suffix} ))
  (( ${#summary} > max )) && summary="${summary:0:max}"
  git -C "$wt" add -A
  if ! git -C "$wt" commit -q -m "$prefix$summary$suffix" \
       -m "Auto-fix of /pr-review finding $id ($(jq -r .severity <<<"$finding")): $(jq -r .title <<<"$finding")" \
       >"$round_dir/logs/fixer-$fid.commit.log" 2>&1; then
    rollback_to "$before"
    add_item "$id" not_fixed "" "commit hooks rejected the fix (see logs/fixer-$fid.commit.log)" "$files" "$secs" "$cost"; continue
  fi
  if ! guard="$(cd "$wt" && python3 "$SCRIPTS_DIR/lanes.py" --protected "$before" HEAD "$main_ref")"; then
    rollback_to "$before"
    add_item "$id" owner "" "the fix touches what needs the owner: $(paste -sd ';' <<<"$guard" | sed 's/;/; /g')" \
      "$files" "$(( SECONDS - start ))" "$cost"; continue
  fi
  if ! (cd "$wt" && bash -c "$VERIFY") >"$round_dir/logs/fixer-$fid.verify.log" 2>&1; then
    rollback_to "$before"
    add_item "$id" not_fixed "" "fast check failed after the fix (see logs/fixer-$fid.verify.log)" "$files" \
      "$(( SECONDS - start ))" "$cost"; continue
  fi
  add_item "$id" fixed "$(git -C "$wt" rev-parse HEAD)" "$reason" "$files" "$(( SECONDS - start ))" "$cost"
done

head_after="$(git -C "$wt" rev-parse HEAD)" pushed=false push_error=""
if [[ "$head_after" == "$head_sha" ]]; then
  push_error="nothing to push"
elif [[ "${PR_REVIEW_FIX_PUSH:-1}" == 0 ]]; then
  push_error="push switched off (PR_REVIEW_FIX_PUSH=0)"
elif git -C "$wt" push -q origin "HEAD:refs/heads/$branch" >"$round_dir/logs/fixer-push.log" 2>&1; then
  pushed=true
else
  push_error="push rejected (see logs/fixer-push.log); the branch moved or a pre-push check failed"
fi
total_secs="$(jq '[.[].seconds] | add // 0' <<<"$items")"
jq -n --argjson items "$items" --arg branch "$branch" --arg before "$head_sha" --arg after "$head_after" \
  --argjson pushed "$pushed" --arg err "$push_error" --arg wt "${wt#"$REPO_ROOT"/}" \
  --argjson secs "$total_secs" --arg cost "$total_cost" \
  '{status: "done", branch: $branch, head_before: $before, head_after: $after, pushed: $pushed,
    push_error: $err, worktree: $wt, seconds: $secs, cost_usd: $cost, items: $items}' >"$fixes"
# The worktree stays only when it holds commits that did not reach the PR.
if [[ "$pushed" == true || "$head_after" == "$head_sha" ]]; then
  git -C "$REPO_ROOT" worktree remove --force "$wt"
fi
write_outputs
log "auto-fix: $(jq '[.items[] | select(.status == "fixed")] | length' "$fixes") fixed of ${#order[@]}," \
    "$([[ "$pushed" == true ]] && echo "pushed to $branch" || echo "not pushed: $push_error")"
