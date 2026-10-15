#!/usr/bin/env bash
# /pr-review pipeline: bundle → reviewers (parallel, quorum) → aggregation → review guide → publication.
#
# Usage: scripts/review/pr-review.sh <pr> [--delta] [--allow-degraded] [--no-guide] [--no-publish]
#   --delta           review only the commits pushed since the previous round
#   --allow-degraded  continue when the quorum is not met (recorded in the report)
#   --no-guide        skip the review guide (guide.sh can be run later on the same round)
#   --no-publish      stop before publication (report.md / guide.md stay local)
# Env: PR_REVIEW_REVIEWERS, PR_REVIEW_TIMEOUT (see run-reviewers.sh)
#
# Exit codes: 0 ok, 1 error, 3 quorum not met.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pr="${1:?usage: pr-review.sh <pr> [--delta] [--allow-degraded] [--no-guide] [--no-publish]}"
shift
delta=() degraded=() publish=true guide=true
for arg in "$@"; do
  case "$arg" in
    --delta)          delta=(--delta) ;;
    --allow-degraded) degraded=(--allow-degraded) ;;
    --no-guide)       guide=false ;;
    --no-publish)     publish=false ;;
    *)                die "unknown option: $arg" ;;
  esac
done

warn_if_tooling_differs_from_main
round_dir="$("$SCRIPTS_DIR/bundle.sh" "$pr" "${delta[@]}")"
"$SCRIPTS_DIR/run-reviewers.sh" "$round_dir" "${degraded[@]}"
"$SCRIPTS_DIR/aggregate.sh" "$round_dir"
# A failed guide does not hold back the findings: they are published anyway, the guide can be re-run alone.
if [[ "$guide" == true ]]; then
  "$SCRIPTS_DIR/guide.sh" "$round_dir" >/dev/null || log "WARNING: review guide failed; findings are published without it"
fi
if [[ "$publish" == true ]]; then
  "$SCRIPTS_DIR/publish.sh" "$round_dir"
fi

rel="${round_dir#"$REPO_ROOT"/}"
echo "round:   $rel"
echo "report:  $rel/report.md"
echo "guide:   $rel/guide.md"
echo "stats:   $rel/stats.tsv"
echo "summary: $(jq -r '[.findings[] | .severity] | group_by(.) | map("\(.[0]): \(length)") | join(", ") | if . == "" then "no findings" else . end' "$round_dir/aggregate.json")"
