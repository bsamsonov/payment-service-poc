#!/usr/bin/env bash
# Run all reviewers of a round in parallel and check the quorum.
#   raw/<reviewer>.md   — reviewer report
#   logs/<reviewer>.*   — stderr, usage/cost metadata, exit status
#
# Usage: scripts/review/run-reviewers.sh <round-dir> [--allow-degraded]
# Env:   PR_REVIEW_REVIEWERS  space-separated subset (default: all)
#        PR_REVIEW_TIMEOUT    per-reviewer timeout, seconds (default: 1200)
#        PR_REVIEW_CODE_REVIEW_MODEL  model for the built-in /code-review (default: opus)
#
# Quorum: L1 (checklist) must succeed and at least one L2 reviewer must succeed; otherwise exit 3
# unless --allow-degraded (recorded in quorum.json).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require claude jq timeout

round_dir="${1:?usage: run-reviewers.sh <round-dir> [--allow-degraded]}"
allow_degraded=false
[[ "${2:-}" == "--allow-degraded" ]] && allow_degraded=true
[[ -f "$round_dir/meta.json" ]] || die "not a round directory: $round_dir"
round_dir="$(cd "$round_dir" && pwd)"
bundle="$round_dir/bundle"
bundle_rel="${bundle#"$REPO_ROOT"/}"
pr="$(jq -r .pr "$round_dir/meta.json")"
head_sha="$(jq -r .head_sha "$round_dir/meta.json")"

OPENCODE="${OPENCODE:-$(command -v opencode || echo "$HOME/.opencode/bin/opencode")}"
TIMEOUT="${PR_REVIEW_TIMEOUT:-1200}"
L1=(checklist)
L2=(bugs-opus deepseek glm code-review)
read -ra REVIEWERS <<<"${PR_REVIEW_REVIEWERS:-${L1[*]} ${L2[*]}}"

# Headless Claude Code with a project subagent: no MCP servers, no skills, no hooks, no saved session.
claude_agent() {
  local agent="$1" id="$2"
  (cd "$REPO_ROOT" && timeout "$TIMEOUT" claude \
    -p "Review the bundle in \`$bundle_rel/\` (start with \`$bundle_rel/manifest.md\`). PR #$pr." \
    --agent "$agent" \
    --output-format json \
    --permission-mode dontAsk \
    --strict-mcp-config \
    --disable-slash-commands \
    --no-session-persistence \
    --settings "$CLAUDE_REVIEW_SETTINGS") \
    >"$round_dir/logs/$id.json" 2>"$round_dir/logs/$id.err"
  jq -e '.is_error == false' "$round_dir/logs/$id.json" >/dev/null
  jq -r '.result' "$round_dir/logs/$id.json" >"$round_dir/raw/$id.md"
}

# Built-in /code-review skill in headless mode, read-only git/gh access. The model is explicit: without it the
# user's default model applies (which may be a small one).
claude_code_review() {
  local id="$1"
  (cd "$REPO_ROOT" && timeout "$TIMEOUT" claude \
    -p "/code-review medium $pr" \
    --model "${PR_REVIEW_CODE_REVIEW_MODEL:-opus}" \
    --output-format json \
    --permission-mode dontAsk \
    --strict-mcp-config \
    --no-session-persistence \
    --settings "$CLAUDE_REVIEW_SETTINGS" \
    --allowedTools "Read,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(gh pr view:*),Bash(gh pr diff:*)") \
    >"$round_dir/logs/$id.json" 2>"$round_dir/logs/$id.err"
  jq -e '.is_error == false' "$round_dir/logs/$id.json" >/dev/null
  jq -r '.result' "$round_dir/logs/$id.json" >"$round_dir/raw/$id.md"
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

run_one() {
  local id="$1"
  case "$id" in
    checklist)   claude_agent review-checklist "$id" ;;
    bugs-opus)   claude_agent review-bugs "$id" ;;
    code-review) claude_code_review "$id" ;;
    deepseek)    opencode_review deepseek-v4-pro "$id" ;;
    glm)         opencode_review glm-5.3 "$id" ;;
    *)           echo "unknown reviewer: $id" >"$round_dir/logs/$id.err"; return 1 ;;
  esac
}

log "PR #$pr round $(basename "$round_dir"): running ${REVIEWERS[*]} (timeout ${TIMEOUT}s each)"
# A re-run of the round replaces the selected reviewers' results; stale reports must not survive a failure.
for id in "${REVIEWERS[@]}"; do
  rm -f "$round_dir/raw/$id.md" "$round_dir/logs/$id".{json,err,status}
done

declare -A pids=()
for id in "${REVIEWERS[@]}"; do
  ( start=$SECONDS rc=0
    run_one "$id" || rc=$?
    if [[ $rc -eq 0 && -s "$round_dir/raw/$id.md" ]]; then status=ok
    elif [[ $rc -eq 0 ]]; then status=failed rc=empty
    else status=failed; fi
    printf '%s %s %s\n' "$status" "$(( SECONDS - start ))" "$rc" >"$round_dir/logs/$id.status" ) &
  pids[$id]=$!
done
for id in "${!pids[@]}"; do wait "${pids[$id]}" || true; done

for id in "${REVIEWERS[@]}"; do
  status=failed secs=? rc=?
  [[ -f "$round_dir/logs/$id.status" ]] && read -r status secs rc <"$round_dir/logs/$id.status"
  log "  $id: $status (${secs}s, exit $rc)"
  [[ "$status" == ok ]] || rm -f "$round_dir/raw/$id.md"
done

# Quorum over every reviewer of the round, so that re-running a subset keeps earlier successful results.
ok=() failed=()
for f in "$round_dir"/logs/*.status; do
  id="$(basename "$f" .status)"
  if [[ "$(cut -d' ' -f1 "$f")" == ok ]]; then ok+=("$id"); else failed+=("$id"); fi
done

l1_ok=false l2_ok=0
for id in "${ok[@]}"; do
  [[ " ${L1[*]} " == *" $id "* ]] && l1_ok=true
  [[ " ${L2[*]} " == *" $id "* ]] && l2_ok=$(( l2_ok + 1 ))
done
quorum=true
[[ "$l1_ok" == true && $l2_ok -ge 1 ]] || quorum=false

jq -n --argjson quorum "$quorum" --argjson degraded "$allow_degraded" --arg head "$head_sha" \
  --arg ok "${ok[*]}" --arg failed "${failed[*]}" \
  '{quorum:$quorum, allow_degraded:$degraded, head_sha:$head,
    ok:($ok | split(" ") | map(select(. != ""))), failed:($failed | split(" ") | map(select(. != "")))}' \
  >"$round_dir/quorum.json"

if [[ "$quorum" == false ]]; then
  if [[ "$allow_degraded" == true ]]; then
    log "quorum NOT met (L1 ok: $l1_ok, L2 ok: $l2_ok) — continuing because of --allow-degraded"
  else
    log "quorum NOT met (L1 ok: $l1_ok, L2 ok: $l2_ok). See $round_dir/logs/. Re-run with --allow-degraded to continue."
    exit 3
  fi
fi
log "reviewers done: ok=${ok[*]:-none} failed=${failed[*]:-none}"
