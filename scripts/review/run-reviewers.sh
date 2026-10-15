#!/usr/bin/env bash
# Run all reviewers of a round in parallel and check the quorum.
#   raw/<reviewer>.md   — reviewer report
#   logs/<reviewer>.*   — stderr, usage/cost metadata, exit status
#
# Usage: scripts/review/run-reviewers.sh <round-dir> [--allow-degraded]
# Reviewers, their levels and on/off: scripts/review/reviewers.conf, overridden by .review/reviewers.local.
# Env:   PR_REVIEW_REVIEWERS  space-separated list to run exactly (default: every reviewer that is on — L1, L2 and
#                             the lanes of lanes.json); results of the other reviewers of the round stay as they are
#        PR_REVIEW_SKIP       comma- or space-separated reviewers switched off for this run
#        PR_REVIEW_TIMEOUT    per-reviewer timeout, seconds (default: 1200)
#        PR_REVIEW_CODE_REVIEW_MODEL  model for the built-in /code-review (default: opus)
#
# Quorum: L1 (checklist) must succeed, at least one L2 reviewer must succeed and every L3 lane switched on for the
# round (lanes.json, written by lanes.py) must succeed — counting only reviewers that are on (a level with every
# reviewer off is not required, a lane that is off is not waited for); otherwise exit 3 unless --allow-degraded (recorded in
# quorum.json). A lane is required because nothing else covers its area: a migration PR without the db lane is worse
# than one bug-hunting model less.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require claude gh jq timeout

round_dir="${1:?usage: run-reviewers.sh <round-dir> [--allow-degraded]}"
allow_degraded=false
[[ "${2:-}" == "--allow-degraded" ]] && allow_degraded=true
[[ -f "$round_dir/meta.json" ]] || die "not a round directory: $round_dir"
round_dir="$(cd "$round_dir" && pwd)"
bundle="$round_dir/bundle"
bundle_rel="${bundle#"$REPO_ROOT"/}"
pr="$(jq -r .pr "$round_dir/meta.json")"
head_sha="$(jq -r .head_sha "$round_dir/meta.json")"
mode="$(jq -r .mode "$round_dir/meta.json")"

OPENCODE="${OPENCODE:-$(command -v opencode || echo "$HOME/.opencode/bin/opencode")}"
TIMEOUT="${PR_REVIEW_TIMEOUT:-1200}"
# Levels and on/off come from reviewers.conf (+ .review/reviewers.local, PR_REVIEW_SKIP); see lib.sh reviewer_config.
L1=() L2=() OFF=()
while read -r id level enabled; do
  [[ "$level" == "?" ]] && { log "WARNING: unknown reviewer '$id' in .review/reviewers.local or --skip — ignored"; continue; }
  [[ "$enabled" == on ]] || { OFF+=("$id"); continue; }
  case "$level" in L1) L1+=("$id") ;; L2) L2+=("$id") ;; esac
done < <(reviewer_config)
is_off() { [[ " ${OFF[*]} " == *" $1 "* ]]; }
# L3: one reviewer per specialist lane switched on by the diff of the round, unless the lane is off.
LANES=() lanes_disabled=()
if [[ -f "$round_dir/lanes.json" ]]; then
  while read -r id; do
    if is_off "$id"; then lanes_disabled+=("$id"); else LANES+=("$id"); fi
  done < <(jq -r '.lanes[].id | "lane-" + .' "$round_dir/lanes.json")
fi
# PR_REVIEW_REVIEWERS (--only) runs exactly the listed reviewers, even ones that are off, and leaves the results
# of the others in the round untouched; without it the round runs every reviewer that is on.
read -ra REVIEWERS <<<"${PR_REVIEW_REVIEWERS:-${L1[*]} ${L2[*]} ${LANES[*]}}"

# run_one is called in a conditional context where `set -e` is off, so every failure must be returned explicitly.

# Extract the text result of a headless Claude run; fails on an error result or an empty result.
claude_result() {
  local id="$1" json="$round_dir/logs/$1.json"
  jq -e '.is_error == false and (.result | type == "string") and (.result | length > 0)' "$json" >/dev/null || return 1
  jq -r '.result' "$json" >"$round_dir/raw/$id.md" || return 1
}

# Headless Claude Code with a project subagent: no MCP servers, no skills, no hooks, no saved session.
# Optional third argument: extra instructions appended to the prompt (the lane of an L3 reviewer).
claude_agent() {
  local agent="$1" id="$2" extra="${3:-}"
  (cd "$REPO_ROOT" && timeout "$TIMEOUT" claude \
    -p "Review the bundle in \`$bundle_rel/\` (start with \`$bundle_rel/manifest.md\`). PR #$pr.${extra:+ $extra}" \
    --agent "$agent" \
    --output-format json \
    --permission-mode dontAsk \
    --strict-mcp-config \
    --disable-slash-commands \
    --no-session-persistence \
    --settings "$CLAUDE_REVIEW_SETTINGS") \
    >"$round_dir/logs/$id.json" 2>"$round_dir/logs/$id.err" || return 1
  claude_result "$id"
}

# Built-in /code-review skill in headless mode. Only gh read commands: git diff/log/show accept --output=<file>,
# which would let a prompt-injected reviewer write files. The model is explicit: without it the
# user's default model applies (which may be a small one).
claude_code_review() {
  local id="$1" live_head
  # /code-review takes only a PR number and reviews the live PR: it cannot follow a delta range or a pinned commit.
  if [[ "$mode" == delta ]]; then
    echo "skipped: /code-review cannot review a delta range" >"$round_dir/logs/$id.err"; return 10
  fi
  live_head="$(gh pr view "$pr" --json headRefOid -q .headRefOid)" || return 1
  if [[ "$live_head" != "$head_sha" ]]; then
    echo "skipped: PR head moved to ${live_head:0:7} since the bundle (${head_sha:0:7})" >"$round_dir/logs/$id.err"
    return 10
  fi
  (cd "$REPO_ROOT" && timeout "$TIMEOUT" claude \
    -p "/code-review medium $pr" \
    --model "${PR_REVIEW_CODE_REVIEW_MODEL:-opus}" \
    --output-format json \
    --permission-mode dontAsk \
    --strict-mcp-config \
    --no-session-persistence \
    --settings "$CLAUDE_REVIEW_SETTINGS" \
    --allowedTools "Read,Grep,Glob,Bash(gh pr view:*),Bash(gh pr diff:*)") \
    >"$round_dir/logs/$id.json" 2>"$round_dir/logs/$id.err" || return 1
  claude_result "$id"
}

# OpenCode model on a copy of the bundle outside the repository, so that the project AGENTS.md is not loaded.
# Only read/search tools stay enabled: subagents (task) would run with the user's global permissions.
opencode_review() {
  local model="$1" id="$2" work
  [[ -x "$OPENCODE" ]] || { echo "opencode not found: $OPENCODE" >"$round_dir/logs/$id.err"; return 1; }
  work="$(mktemp -d "${TMPDIR:-/tmp}/pr-review-$pr-$id.XXXXXX")"
  cp -r "$bundle/." "$work/"
  agent_body "$REPO_ROOT/.claude/agents/review-bugs.md" >"$work/.reviewer-prompt.md"
  cat >"$work/opencode.json" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "agent": {
    "pr-reviewer": {
      "description": "Read-only PR reviewer",
      "mode": "primary",
      "prompt": "{file:./.reviewer-prompt.md}",
      "tools": {"write": false, "edit": false, "patch": false, "bash": false, "task": false, "todowrite": false,
                "webfetch": false, "websearch": false, "codesearch": false},
      "permission": {"edit": "deny", "bash": "deny", "webfetch": "deny", "websearch": "deny", "codesearch": "deny",
                     "task": "deny", "external_directory": "deny"}
    }
  }
}
JSON
  local rc=0
  (cd "$work" && OPENCODE_DISABLE_CLAUDE_CODE=1 timeout "$TIMEOUT" "$OPENCODE" run --pure \
    --agent pr-reviewer -m "opencode-go/$model" \
    "Review the bundle in the current directory (start with manifest.md). PR #$pr.") \
    >"$round_dir/raw/$id.md" 2>"$round_dir/logs/$id.err" || rc=$?
  rm -rf "$work"
  return "$rc"
}

# L3 lane reviewer: the generic review-lane agent with the lane's checklist and facts from the bundle.
claude_lane() {
  local lane="$1" id="$2"
  [[ -f "$bundle/lanes/$lane/checklist.md" && -f "$bundle/lanes/$lane/facts.md" ]] || {
    echo "lane $lane is not prepared in $bundle_rel/lanes/ (run lanes.py, or set PR_REVIEW_LANES)" >"$round_dir/logs/$id.err"
    return 1
  }
  claude_agent review-lane "$id" "Lane: \`$lane\`. Checklist: \`$bundle_rel/lanes/$lane/checklist.md\`; facts: \`$bundle_rel/lanes/$lane/facts.md\`."
}

# A report counts only if it has the structure its prompt requires; a truncated or chatty answer does not.
report_complete() {
  local id="$1" f="$round_dir/raw/$1.md"
  [[ -s "$f" ]] || return 1
  case "$id" in
    checklist)               grep -q '^# L1 checklist review' "$f" && grep -qE '^\| *RC-[0-9]+' "$f" ;;
    bugs-opus|deepseek|glm)  grep -q '^# L2 bug review' "$f" && grep -q '^## Findings' "$f" ;;
    lane-*)                  grep -q "^# L3 ${id#lane-} review" "$f" && grep -q '^## Findings' "$f" ;;
    *)                       ;;  # /code-review has a free-form answer
  esac
}

run_one() {
  local id="$1"
  case "$id" in
    checklist)   claude_agent review-checklist "$id" ;;
    bugs-opus)   claude_agent review-bugs "$id" ;;
    code-review) claude_code_review "$id" ;;
    deepseek)    opencode_review deepseek-v4-pro "$id" ;;
    glm)         opencode_review glm-5.3 "$id" ;;
    lane-*)      claude_lane "${id#lane-}" "$id" ;;
    *)           echo "unknown reviewer: $id" >"$round_dir/logs/$id.err"; return 1 ;;
  esac
}

log "PR #$pr round $(basename "$round_dir"): running ${REVIEWERS[*]} (timeout ${TIMEOUT}s each)"
# A re-run of the round replaces the selected reviewers' results; stale reports must not survive a failure.
for id in "${REVIEWERS[@]}"; do
  rm -f "$round_dir/raw/$id.md" "$round_dir/logs/$id".{json,err,status}
done
# Reviewers that are off are recorded as skipped, so that the report and the stats show who did not take part.
if [[ -z "${PR_REVIEW_REVIEWERS:-}" ]]; then
  for id in "${OFF[@]}"; do
    [[ "$id" == lane-* && " ${lanes_disabled[*]} " != *" $id "* ]] && continue  # lane not switched on anyway
    rm -f "$round_dir/raw/$id.md" "$round_dir/logs/$id".{json,err}
    echo "skipped 0 disabled" >"$round_dir/logs/$id.status"
    echo "skipped: switched off in reviewers.conf, .review/reviewers.local or --skip" >"$round_dir/logs/$id.err"
  done
  [[ ${#OFF[@]} -eq 0 ]] || log "switched off: ${OFF[*]}"
fi

declare -A pids=()
for id in "${REVIEWERS[@]}"; do
  ( start=$SECONDS rc=0
    run_one "$id" || rc=$?
    if [[ $rc -eq 10 ]]; then status=skipped rc=0
    elif [[ $rc -ne 0 ]]; then status=failed
    elif ! [[ -s "$round_dir/raw/$id.md" ]]; then status=failed rc=empty
    elif ! report_complete "$id"; then status=failed rc=incomplete
    else status=ok; fi
    printf '%s %s %s\n' "$status" "$(( SECONDS - start ))" "$rc" >"$round_dir/logs/$id.status" ) &
  pids[$id]=$!
done
for id in "${!pids[@]}"; do wait "${pids[$id]}" || true; done

for id in "${REVIEWERS[@]}"; do
  status=failed secs=? rc=?
  [[ -f "$round_dir/logs/$id.status" ]] && read -r status secs rc <"$round_dir/logs/$id.status"
  log "  $id: $status (${secs}s, exit $rc)"
  [[ "$status" == ok ]] || rm -f "$round_dir/raw/$id.md"  # failed or skipped
done

# Quorum over every reviewer of the round, so that re-running a subset keeps earlier successful results.
# An `ok` status counts only while its report is still present and complete (it may have been removed since).
ok=() failed=() skipped=() disabled=()
for f in "$round_dir"/logs/*.status; do
  id="$(basename "$f" .status)"
  [[ "$(cut -d' ' -f3 "$f")" == disabled ]] && disabled+=("$id")
  case "$(cut -d' ' -f1 "$f")" in
    ok)      if report_complete "$id"; then ok+=("$id")
             else log "  $id: status ok but raw/$id.md is missing or incomplete — counted as failed"; failed+=("$id"); fi ;;
    skipped) skipped+=("$id") ;;  # neither helps nor hurts the quorum
    *)       failed+=("$id") ;;
  esac
done

# A level is required only while some reviewer of it is on: switching off all of L2 is a deliberate choice.
l1_ok=false l2_ok=0
for id in "${ok[@]}"; do
  [[ " ${L1[*]} " == *" $id "* ]] && l1_ok=true
  [[ " ${L2[*]} " == *" $id "* ]] && l2_ok=$(( l2_ok + 1 ))
done
[[ ${#L1[@]} -eq 0 ]] && l1_ok=true
[[ ${#L2[@]} -eq 0 ]] && l2_ok=1
lanes_missing=()
for id in "${LANES[@]}"; do
  [[ " ${ok[*]} " == *" $id "* ]] || lanes_missing+=("$id")
done
quorum=true
[[ "$l1_ok" == true && $l2_ok -ge 1 && ${#lanes_missing[@]} -eq 0 ]] || quorum=false

jq -n --argjson quorum "$quorum" --argjson degraded "$allow_degraded" --arg head "$head_sha" \
  --arg ok "${ok[*]}" --arg failed "${failed[*]}" --arg skipped "${skipped[*]}" --arg off "${disabled[*]}" \
  --arg lanes "${LANES[*]}" --arg missing "${lanes_missing[*]}" --arg lanes_off "${lanes_disabled[*]}" \
  'def words: split(" ") | map(select(. != ""));
   {quorum:$quorum, allow_degraded:$degraded, head_sha:$head, ok:($ok | words), failed:($failed | words),
    skipped:($skipped | words), disabled:($off | words),
    lanes_required:($lanes | words), lanes_missing:($missing | words), lanes_disabled:($lanes_off | words)}' \
  >"$round_dir/quorum.json"

if [[ "$quorum" == false ]]; then
  if [[ "$allow_degraded" == true ]]; then
    log "quorum NOT met (L1 ok: $l1_ok, L2 ok: $l2_ok, lanes missing: ${lanes_missing[*]:-none}) — continuing because of --allow-degraded"
  else
    log "quorum NOT met (L1 ok: $l1_ok, L2 ok: $l2_ok, lanes missing: ${lanes_missing[*]:-none}). See $round_dir/logs/. Re-run with --allow-degraded to continue."
    exit 3
  fi
fi
log "reviewers done: ok=${ok[*]:-none} failed=${failed[*]:-none}"
