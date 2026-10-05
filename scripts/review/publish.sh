#!/usr/bin/env bash
# Publish a round to the PR:
#   - one review (event COMMENT) with an inline comment per confirmed finding; findings whose line is not part of
#     the PR diff go into the review body;
#   - one PR comment with guide.md.
# Inline comments open review threads; the ruleset requires all threads to be resolved before merge.
#
# Usage: scripts/review/publish.sh <round-dir> [--dry-run]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require gh jq awk

round_dir="${1:?usage: publish.sh <round-dir> [--dry-run]}"
dry_run=false
[[ "${2:-}" == "--dry-run" ]] && dry_run=true
round_dir="$(cd "$round_dir" && pwd)"
agg="$round_dir/aggregate.json"
[[ -f "$agg" ]] || die "no aggregate.json in $round_dir; run aggregate.sh first"
pr="$(jq -r .pr "$round_dir/meta.json")"
round="$(jq -r .round "$round_dir/meta.json")"
head_sha="$(jq -r .head_sha "$round_dir/meta.json")"

current_head="$(gh pr view "$pr" --json headRefOid -q .headRefOid)"
[[ "$current_head" == "$head_sha" ]] \
  || log "warning: PR head moved to ${current_head:0:7} after review of ${head_sha:0:7}; comments target the reviewed commit"

# Right-side lines (added or context) of the PR diff, as "path<TAB>line".
awk '
  /^diff --git / { path = ""; next }
  /^\+\+\+ /     { path = ($0 == "+++ /dev/null") ? "" : substr($0, 7); next }
  /^@@ /         { split($3, a, ","); line = substr(a[1], 2) + 0; next }
  path == ""     { next }
  /^\+/          { print path "\t" line; line++; next }
  /^ /           { print path "\t" line; line++; next }
' "$round_dir/pr.patch" | sort -u >"$round_dir/commentable.tsv"

payload="$round_dir/review-payload.json"
jq --rawfile ok "$round_dir/commentable.tsv" --arg sha "$head_sha" --arg round "$round" '
  ($ok | split("\n") | map(select(. != "")) | map({key: ., value: true}) | from_entries) as $valid
  | def head: "**[\(.id) · \(.severity)\(if .rule != "" then " · " + .rule else "" end)] \(.title)**";
    def foot: "\n\n<sub>/pr-review round \($round) · reported by: \(.sources | join(", "))</sub>";
    [.findings[] | . + {commentable: ($valid["\(.path)\t\(.line)"] // false)}] as $all
  | {
      commit_id: $sha,
      event: "COMMENT",
      body: ("/pr-review round \($round): \($all | length) confirmed finding(s); see the guide comment."
             + (if any($all[]; .commentable | not) then
                  "\n\nFindings outside the diff:\n" +
                  ([$all[] | select(.commentable | not) | "- \(head) `\(.path):\(.line)`\n  \(.body)"] | join("\n"))
                else "" end)),
      comments: [$all[] | select(.commentable) | {path, line, side: "RIGHT", body: (head + "\n\n" + .body + foot)}]
    }
' "$agg" >"$payload"

inline="$(jq '.comments | length' "$payload")"
total="$(jq '.findings | length' "$agg")"
if [[ "$dry_run" == true ]]; then
  log "dry run: would post a review with $inline inline comment(s) of $total finding(s) and the guide; payload: $payload"
  exit 0
fi

repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
if (( total > 0 )); then
  url="$(gh api -X POST "repos/$repo/pulls/$pr/reviews" --input "$payload" -q .html_url)"
  log "review posted: $url ($inline inline, $(( total - inline )) in body)"
fi
url="$(gh pr comment "$pr" --body-file "$round_dir/guide.md")"
log "guide posted: $url"
jq -n --arg at "$(date -u +%FT%TZ)" '{published_at: $at}' >"$round_dir/published.json"
