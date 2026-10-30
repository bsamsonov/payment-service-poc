#!/usr/bin/env bash
# Publish a round to the PR:
#   - one review (event COMMENT) with an inline comment per confirmed finding; findings whose line is not part of
#     the PR diff go into the review body;
#   - one PR comment with guide.md (written by write-review-guide.sh), when the round has one.
# Inline comments open review threads; the ruleset requires all threads to be resolved before merge.
# After an auto-fix (autofix-findings.sh, fixes.json) every comment says whether the finding was fixed and in which commit; the
# thread is still left open for the owner to check the fix and resolve it.
#
# Idempotent: each step is recorded in published.json right after it succeeds and is not repeated on a re-run
# (e.g. after the guide comment failed); --force posts again.
#
# Usage: scripts/review/publish-to-pr.sh <round-dir> [--guide-only] [--dry-run | --force]
#   --guide-only  post only the guide (a round without AI review, or when the review was posted already)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require gh jq awk

round_dir="${1:?usage: publish-to-pr.sh <round-dir> [--guide-only] [--dry-run | --force]}"
shift
dry_run=false force=false guide_only=false
for arg in "$@"; do
  case "$arg" in
    --dry-run)    dry_run=true ;;
    --force)      force=true ;;
    --guide-only) guide_only=true ;;
    *)            die "unknown option: $arg" ;;
  esac
done
round_dir="$(cd "$round_dir" && pwd)"
agg="$round_dir/aggregate.json"
guide="$round_dir/guide.md"
if [[ "$guide_only" == true ]]; then
  [[ -f "$guide" ]] || die "no guide.md in $round_dir; run write-review-guide.sh first"
else
  [[ -f "$agg" ]] || die "no aggregate.json in $round_dir; run aggregate-findings.sh first (or use --guide-only)"
fi
pr="$(jq -r .pr "$round_dir/meta.json")"
round="$(jq -r .round "$round_dir/meta.json")"
head_sha="$(jq -r .head_sha "$round_dir/meta.json")"

current_head="$(gh pr view "$pr" --json headRefOid -q .headRefOid)"
[[ "$current_head" == "$head_sha" ]] \
  || log "warning: PR head moved to ${current_head:0:7} after review of ${head_sha:0:7}; comments target the reviewed commit"

inline=0 total=0
if [[ "$guide_only" == false ]]; then
  # Right-side lines (added or context) of the PR diff, as "path<TAB>line".
  # File headers are recognized only between "diff --git" and the first hunk, so content lines starting with "++ "
  # are not mistaken for headers.
  awk '
    /^diff --git /             { path = ""; header = 1; next }
    header && /^\+\+\+ /       { path = ($0 == "+++ /dev/null") ? "" : substr($0, 7); next }
    /^@@ /                     { header = 0; split($3, a, ","); line = substr(a[1], 2) + 0; next }
    header || path == ""       { next }
    /^\+/          { print path "\t" line; line++; next }
    /^ /           { print path "\t" line; line++; next }
  ' "$round_dir/pr.patch" | sort -u >"$round_dir/commentable.tsv"

  payload="$round_dir/review-payload.json"
  fixes='{}'
  [[ -f "$round_dir/fixes.json" ]] && fixes="$(cat "$round_dir/fixes.json")"
  jq --rawfile ok "$round_dir/commentable.tsv" --arg sha "$head_sha" --arg round "$round" --argjson fx "$fixes" '
    ($ok | split("\n") | map(select(. != "")) | map({key: ., value: true}) | from_entries) as $valid
    | (($fx.items // []) | map({key: .id, value: .}) | from_entries) as $fixed
    | def head: "**[\(.id) · \(.severity)\(if .rule != "" then " · " + .rule else "" end)] \(.title)**";
      def fix: $fixed["R\($round)-\(.id)"] as $f
        | if $f == null then ""
          elif $f.status == "fixed" then
            "\n\n**Auto-fixed in `\($f.sha[:7])`\(if ($f.test_sha // "") != "" then ", tests in `\($f.test_sha[:7])`" else "" end)**\(if $fx.pushed then "" else " (not pushed: \($fx.push_error))" end)" +
            " — \($f.reason). Please check the fix commit(s) and resolve this thread."
          elif $f.status == "owner" then "\n\n**Not auto-fixed — needs the owner:** \($f.reason)"
          else "\n\n**Not auto-fixed:** \($f.reason)" end;
      def foot: fix + "\n\n<sub>/pr-review round \($round) · reported by: \(.sources | join(", "))</sub>";
      [.findings[] | . + {commentable: ($valid["\(.path)\t\(.line)"] // false)}] as $all
    | {
        commit_id: $sha,
        event: "COMMENT",
        body: ("/pr-review round \($round): \($all | length) confirmed finding(s); see the review guide comment."
               + (if $fx.status == "done" then
                    "\n\nAuto-fix: \([$fx.items[] | select(.status == "fixed")] | length) fixed" +
                    (if $fx.pushed then " and pushed (`\($fx.head_before[:7])..\($fx.head_after[:7])`)"
                     else " — not pushed: \($fx.push_error)" end) +
                    ", \([$fx.items[] | select(.status != "fixed")] | length) left to the owner."
                  else "" end)
               + (if any($all[]; .commentable | not) then
                    "\n\nFindings outside the diff:\n" +
                    ([$all[] | select(.commentable | not) | "- \(head) `\(.path):\(.line)`\n  \(.body)\(fix | gsub("\n\n"; "\n  "))"] | join("\n"))
                  else "" end)),
        comments: [$all[] | select(.commentable) | {path, line, side: "RIGHT", body: (head + "\n\n" + .body + foot)}]
      }
  ' "$agg" >"$payload"

  inline="$(jq '.comments | length' "$payload")"
  total="$(jq '.findings | length' "$agg")"

fi
if [[ "$dry_run" == true ]]; then
  if [[ "$guide_only" == true ]]; then
    log "dry run: would post the guide only"
  else
    log "dry run: would post a review with $inline inline comment(s) of $total finding(s)" \
        "$([[ -f "$guide" ]] && echo "and the guide" || echo "and no guide (guide.md missing)")"
  fi
  exit 0
fi

repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
state="$round_dir/published.json"
[[ -f "$state" && "$force" == false ]] || echo '{}' >"$state"
record() { jq --arg k "$1" --arg v "$2" --arg at "$(date -u +%FT%TZ)" '.[$k] = {url: $v, at: $at}' "$state" >"$state.tmp" \
  && mv "$state.tmp" "$state"; }

if [[ "$guide_only" == true ]]; then
  :
elif (( total == 0 )); then
  log "no findings: no review posted"
elif url="$(jq -r '.review.url // empty' "$state")" && [[ -n "$url" ]]; then
  log "review already posted: $url (use --force to post again)"
else
  url="$(gh api -X POST "repos/$repo/pulls/$pr/reviews" --input "$payload" -q .html_url)"
  record review "$url"
  log "review posted: $url ($inline inline, $(( total - inline )) in body)"
fi

if [[ ! -f "$guide" ]]; then
  log "no guide.md in this round: guide not posted (scripts/review/write-review-guide.sh writes it)"
elif url="$(jq -r '.guide.url // empty' "$state")" && [[ -n "$url" ]]; then
  log "guide already posted: $url (use --force to post again)"
else
  url="$(gh pr comment "$pr" --body-file "$guide")"
  record guide "$url"
  log "guide posted: $url"
fi
