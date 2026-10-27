#!/usr/bin/env bash
# Write the guide for the human reviewer with the review-guide subagent:
#   guide.json — structured result (schema: guide.schema.json)
#   guide.md   — rendered guide (render-guide.jq), posted as a PR comment by publish.sh
#   guide.ru.md, walkthrough.ru.md — Russian reading version and code walkthrough for the owner, not posted
#                (guide-ru.sh, opus)
#
# Works with or without an AI review round. Uses raw/*.md and aggregate.json of the round when they exist.
#
# Usage: scripts/review/guide.sh <pr | round-dir> [--reuse] [--no-ru]
#   <pr>        use the latest round of the current PR head; if there is none, build a bundle (bundle.sh, full diff)
#   <round-dir> a round directory built by bundle.sh (this is how pr-review.sh calls it)
#   --reuse     do not call the agent again; re-render from logs/guide.json
#   --no-ru     skip the Russian documents
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require claude jq timeout gh

target="${1:?usage: guide.sh <pr | round-dir> [--reuse] [--no-ru]}"
shift
reuse=false ru=true
for arg in "$@"; do
  case "$arg" in
    --reuse) reuse=true ;;
    --no-ru) ru=false ;;
    *)       die "unknown option: $arg" ;;
  esac
done
warn_if_tooling_differs_from_main

if [[ -d "$target" ]]; then
  round_dir="$(cd "$target" && pwd)"
elif [[ "$target" =~ ^[0-9]+$ ]]; then
  head_sha="$(gh pr view "$target" --json headRefOid -q .headRefOid)"
  round_dir="$(latest_round_dir_for_head "$target" "$head_sha")"
  if [[ -n "$round_dir" ]]; then
    log "PR #$target: using round $(basename "$round_dir") of head ${head_sha:0:7}"
  else
    log "PR #$target: no round for head ${head_sha:0:7}; building a bundle"
    round_dir="$("$SCRIPTS_DIR/bundle.sh" "$target")"
  fi
else
  die "PR number or round directory expected, got: $target"
fi
round_rel="${round_dir#"$REPO_ROOT"/}"
[[ -f "$round_dir/meta.json" && -f "$round_dir/bundle/manifest.md" ]] || die "$round_rel is not a complete round"
pr="$(jq -r .pr "$round_dir/meta.json")"
round="$(jq -r .round "$round_dir/meta.json")"
mode="$(jq -r .mode "$round_dir/meta.json")"
mkdir -p "$round_dir/logs"

# Delta mode: the guide of the latest earlier round, so that the agent reports the status of its items.
rm -f "$round_dir/previous-guide.json" "$round_dir/previous-fixes.json"
if [[ "$mode" == "delta" ]]; then
  for n in $(find "$REVIEW_ROOT/$pr" -mindepth 1 -maxdepth 1 -type d -regex '.*/[0-9]+' -printf '%f\n' | sort -rn); do
    (( n < round )) && [[ -f "$REVIEW_ROOT/$pr/$n/guide.json" ]] \
      && { cp "$REVIEW_ROOT/$pr/$n/guide.json" "$round_dir/previous-guide.json"
           [[ -f "$REVIEW_ROOT/$pr/$n/fixes.json" ]] && cp "$REVIEW_ROOT/$pr/$n/fixes.json" "$round_dir/previous-fixes.json"
           break; }
  done
fi

inputs=()
compgen -G "$round_dir/raw/*.md" >/dev/null \
  && inputs+=("- AI reviewer reports: $(cd "$round_dir/raw" && ls -1 *.md | sed "s|^|\`$round_rel/raw/|; s|$|\`|" | paste -sd' ' -)")
[[ -f "$round_dir/aggregate.json" ]] && inputs+=("- verified findings and rejections: \`$round_rel/aggregate.json\`")
[[ -f "$round_dir/fixes.json" ]] && inputs+=("- auto-fix of the findings (fix commits, findings left to the owner): \`$round_rel/fixes.json\`")
[[ -f "$round_dir/previous-fixes.json" ]] && inputs+=("- auto-fix of the previous round (its fix commits are in this delta): \`$round_rel/previous-fixes.json\`")
[[ -f "$round_dir/previous-guide.json" ]] && inputs+=("- previous guide: \`$round_rel/previous-guide.json\`")
(( ${#inputs[@]} )) || inputs+=("- no AI review results for this round")

if [[ "$reuse" == true && -s "$round_dir/logs/guide.json" ]]; then
  log "reusing logs/guide.json"
else
  log "writing the review guide for PR #$pr, round $round ($mode)"
  (cd "$REPO_ROOT" && timeout "${PR_REVIEW_TIMEOUT:-1200}" claude \
    -p "Write the review guide for round \`$round_rel/\` of PR #$pr (mode: $mode).
Bundle: \`$round_rel/bundle/\` (start with manifest.md, then signals.md).
Optional inputs present:
$(printf '%s\n' "${inputs[@]}")" \
    --agent review-guide \
    --output-format json \
    --json-schema "$(cat "$SCRIPTS_DIR/guide.schema.json")" \
    --permission-mode dontAsk \
    --strict-mcp-config \
    --disable-slash-commands \
    --no-session-persistence \
    --settings "$CLAUDE_REVIEW_SETTINGS") >"$round_dir/logs/guide.json" 2>"$round_dir/logs/guide.err" \
    || die "review-guide failed, see $round_rel/logs/guide.err"
fi
jq -e '.is_error == false' "$round_dir/logs/guide.json" >/dev/null \
  || die "review-guide reported an error, see $round_rel/logs/guide.json"

tmp="$round_dir/guide.json.tmp"
jq -e '(.structured_output | type) == "object"' "$round_dir/logs/guide.json" >/dev/null \
  || log "WARNING: no structured output, the schema was not applied; parsing the text result"
jq 'if (.structured_output | type) == "object" then .structured_output
    else .result | sub("^[^{]*"; "") | sub("[^}]*$"; "") | fromjson end' \
  "$round_dir/logs/guide.json" >"$tmp" 2>/dev/null \
  || die "review-guide output is not valid JSON, see $round_rel/logs/guide.json"
jq -e 'has("summary") and has("attention") and has("must_review") and has("out_of_scope") and has("skim")
       and has("cleared") and has("defects_seen") and has("not_assessed") and has("previous")
       and all(.attention[]; has("title") and has("path") and has("line") and has("question") and has("decide_by"))' \
  "$tmp" >/dev/null || die "review-guide JSON misses required fields, see $round_rel/guide.json.tmp"
mv "$tmp" "$round_dir/guide.json"

agg=/dev/null quorum=/dev/null
[[ -f "$round_dir/aggregate.json" ]] && agg="$round_dir/aggregate.json"
[[ -f "$round_dir/quorum.json" ]] && quorum="$round_dir/quorum.json"
jq -r --arg round "$round" --arg mode "$mode" --slurpfile agg "$agg" --slurpfile q "$quorum" \
  -f "$SCRIPTS_DIR/render-guide.jq" "$round_dir/guide.json" >"$round_dir/guide.md"

log "guide: $(jq '.attention | length' "$round_dir/guide.json") attention item(s)," \
    "$(jq '.must_review | length' "$round_dir/guide.json") place(s) to read → $round_rel/guide.md"
if [[ "$ru" == true ]]; then
  "$SCRIPTS_DIR/guide-ru.sh" "$round_dir" || log "WARNING: Russian documents failed; guide.md is ready"
fi
echo "$round_dir"
